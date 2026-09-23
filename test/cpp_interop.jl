module CppInteropTests

using Test
using Libdl
using OrderedCollections: OrderedDict
using StaticArrays: SVector, SMatrix
import GradientMicroIDL
import YAML

include("cpp_test_setup.jl")
using .CppTestSetup: cpp_compiler, eigen_include_dir

const CPP_DIR = joinpath(@__DIR__, "cpp")
const EXAMPLE = joinpath(@__DIR__, "..", "examples", "messages.yaml")

# Layout probes use C++ sizeof/alignof/offsetof, not constants from the IDL parser. Julia
# supplies field names from the actual loaded types, so mismatched fields fail compilation
# and mismatched offsets fail the subsequent numeric comparisons.
function write_layout_probe(filename, types)

    open(filename, "w") do io

        println(io, "#include \"Interop/Interop.hpp\"")
        println(io, "#include \"MyMessages/MyMessages.hpp\"\n")
        println(io, "extern \"C\" std::size_t layout_value(")
        println(io, "    std::size_t type, std::size_t property")
        println(io, ") {")
        println(io, "    switch (type) {")
        for (index, (cpp_name, type)) in enumerate(types)

            println(io, "        case $(index - 1): {")
            println(io, "            static const std::size_t values[] = {")
            println(io, "                sizeof($cpp_name),")
            println(io, "                alignof($cpp_name),")
            for field in fieldnames(type)
                println(io, "                offsetof($cpp_name, $field),")
            end
            println(io, "            };")
            println(io, "            return values[property];")
            println(io, "        }")

        end
        println(io, "        default: return 0;")
        println(io, "    }")
        println(io, "}")

    end

end

# A successful control compile distinguishes intentionally rejected view operations from
# missing headers or a broken toolchain. Capture expected compiler errors to keep the
# normal test output quiet; unexpected control failures keep the compiler's diagnostics.
function test_view_access(command)

    source = joinpath(CPP_DIR, "view_access.cpp")
    run(`$command -fsyntax-only $source`)
    for mode in ("TEST_CONST_WRITE", "TEST_TEMPORARY", "TEST_CONST_TEMPORARY")

        @testset "$mode" begin

            diagnostics = IOBuffer()
            process = run(pipeline(
                ignorestatus(`$command -fsyntax-only -D$mode $source`);
                stdout = diagnostics,
                stderr = diagnostics,
            ))
            @test !success(process)

        end

    end

end

# ccall requires a concrete return type at definition time, unlike Ref{T} arguments.
# The fixture types are generated at runtime, so specialize this tiny call helper after
# loading them. User code can simply name its normally included message type in ccall.
@generated function return_message(function_pointer, ::Type{Message}) where Message
    return :(ccall(function_pointer, $Message, ()))
end

# Julia handles registers or a hidden return pointer according to the native C ABI;
# callers do not supply a Ref here. Compare fields rather than unspecified padding bytes.
function test_returned_message(library, symbol, expected::Message) where Message

    function_pointer = dlsym(library, symbol)
    actual = return_message(function_pointer, Message)
    for name in fieldnames(Message)
        @test getfield(actual, name) === getfield(expected, name)
    end

end

# Parameterizing Packet lets ccall use a concrete Ref type in its signature. The caller
# enters the latest world after loading generated modules, so their new constructors and
# enum bindings are available throughout these tests.
function test_roundtrip(root, ::Type{Packet}, library) where Packet

    # Distinct values in every width expose signedness, field-order, and element-order
    # errors. The C++ fixture independently constructs the same message for the reverse
    # trip.
    scalars = root.Scalars(
        -8,
        -1600,
        -320000,
        typemin(Int64),
        200,
        60000,
        4000000000,
        typemax(UInt64),
        1.25f0,
        -2.5,
        65,
        root.Signed.minimum,
        root.Unsigned.maximum,
    )
    expected = Packet(;
        sequence = 123,
        samples  = SMatrix{2, 3, Float64}(1:6),
        row      = SMatrix{1, 3, Float32}(7:9),
        column   = SMatrix{3, 1, Int16}(-1:-1:-3),
        children = SVector(root.Child(7, 1000), root.Child(9, 2000)),
        states   = SVector(root.Signed.minimum, root.Signed.maximum),
        bytes    = SVector{3, UInt8}(65, 0, 255),
        scalars,
    )

    # First exercise pure C++ construction, then read Julia-owned storage from C++.
    # Nonzero results identify a failing line in cpp/interop.cpp rather than aborting Julia.
    constructors = dlsym(library, :check_constructors)
    check_packet = dlsym(library, :check_packet)
    @test ccall(constructors, Cint, ()) == 0
    packet = Ref(expected)
    @test ccall(check_packet, Cint, (Ref{Packet},), packet) == 0

    # C++ fills fresh Julia-owned storage. Compare field values, not padding bytes, since
    # neither language promises meaningful contents for the padding in a message.
    write_packet = dlsym(library, :write_packet)
    output = Ref{Packet}()
    ccall(write_packet, Cvoid, (Ref{Packet},), output)
    for name in fieldnames(Packet)
        @test getfield(output[], name) === getfield(expected, name)
    end

    # The same large fixture also crosses the boundary as a by-value return, including
    # nested messages, enums, and StaticArrays. This checks more than a scalar-only struct.
    @testset "Large message returned by value" begin
        test_returned_message(library, :return_packet, expected)
    end

    # Mutations through Eigen views must be visible in the original Julia Ref. Also check
    # neighboring coefficients and nested values so an incorrect offset cannot go unnoticed.
    update_packet = dlsym(library, :update_packet)
    ccall(update_packet, Cvoid, (Ref{Packet},), packet)
    actual = packet[]
    @test actual.samples == SMatrix{2, 3}(1.0, 2.0, 3.0, 4.0, 5.0, 42.5)
    @test actual.row == SMatrix{1, 3}(7.0f0, 80.0f0, 9.0f0)
    @test actual.column == SMatrix{3, 1, Int16}(-1, -2, -30)
    @test actual.children[1] === expected.children[1]
    @test actual.children[2].tag == 9
    @test actual.children[2].count == 3000
    @test actual.states == SVector(root.Signed.maximum, root.Signed.maximum)
    @test actual.bytes == SVector{3, UInt8}(65, 255, 255)
    @test actual.sequence == expected.sequence
    @test actual.scalars === expected.scalars

end

# Build one library containing handwritten behavior checks and generated layout probes.
# The temporary directory owns all generated source and binaries; dlclose runs before
# cleanup so no loaded library is left referring to a deleted file.
function test_compiled(root, example, directory, compiler, eigen)

    # Include every message from the real example, as well as supplementary shapes and
    # integer widths. Enum types have no fields, but their size/alignment are still checked.
    gnss = example.Sensors.GNSS
    types = [
        "::MyMessages::Common::LocalTimeStamp" => example.Common.LocalTimeStamp,
        "::MyMessages::Sensors::Barometer::BarometerMeasurement" =>
            example.Sensors.Barometer.BarometerMeasurement,
        "::MyMessages::Sensors::GNSS::GNSSFixType" => gnss.GNSSFixType.T,
        "::MyMessages::Sensors::GNSS::GNSSTimestamp" => gnss.GNSSTimestamp,
        "::MyMessages::Sensors::GNSS::GNSSPositionMeasurement" =>
            gnss.GNSSPositionMeasurement,
        "::MyMessages::Sensors::GNSS::LatitudeLongitudeAltitudeWGS84" =>
            gnss.LatitudeLongitudeAltitudeWGS84,
        "::MyMessages::GNC::Navigation::NavInputs" => example.GNC.Navigation.NavInputs,
        "::Interop::Signed" => root.Signed.T,
        "::Interop::Unsigned" => root.Unsigned.T,
        "::Interop::Scalars" => root.Scalars,
        "::Interop::Child" => root.Child,
        "::Interop::Packet" => root.Packet,
    ]
    probe = joinpath(directory, "layout.cpp")
    write_layout_probe(probe, types)

    # A direct compiler invocation is sufficient for these two translation units. Treat
    # Eigen as a system include so its internal warnings do not obscure our own diagnostics.
    command = `$compiler -std=c++17 -O2 -Wall -Wextra -pedantic-errors`
    command = `$command -I $directory -isystem $eigen`
    flags = Sys.isapple() ? ["-dynamiclib", "-fPIC"] : ["-shared", "-fPIC"]
    binary = joinpath(directory, "interop.$dlext")
    source = joinpath(CPP_DIR, "interop.cpp")
    run(`$command $flags $source $probe -o $binary`)

    library = dlopen(binary)
    try

        @testset "C++ layouts" begin

            layout_value = dlsym(library, :layout_value)
            for (index, (cpp_name, type)) in enumerate(types)

                @testset "$cpp_name" begin

                    expected = [sizeof(type), Base.datatype_alignment(type)]
                    append!(expected, [fieldoffset(type, i) for i in 1:fieldcount(type)])
                    for (property, value) in enumerate(expected)

                        actual = ccall(
                            layout_value,
                            Csize_t,
                            (Csize_t, Csize_t),
                            index - 1,
                            property - 1,
                        )
                        @test actual == value

                    end

                end

            end

        end

        @testset "C++ constructors and shared messages" begin
            test_roundtrip(root, root.Packet, library)
        end

        # Small integer and homogeneous floating-point structs can use different return
        # conventions from the large Packet, depending on the CI platform's architecture.
        @testset "Small messages returned by value" begin

            test_returned_message(library, :return_timestamp, gnss.GNSSTimestamp(7, 123456))
            test_returned_message(
                library,
                :return_coordinates,
                gnss.LatitudeLongitudeAltitudeWGS84(0.25, -0.5, 1200.0),
            )

        end

    finally
        dlclose(library)
    end

    @testset "C++ view access restrictions" begin
        test_view_access(command)
    end

end

@testset "Compiled C++ interoperability" begin

    # Resolve dependencies once, then generate both languages from the exact same inputs.
    # UInt64's maximum comes through the dictionary API because YAML parses signed Ints.
    compiler = cpp_compiler()
    eigen = eigen_include_dir()
    definitions = YAML.load_file(
        joinpath(CPP_DIR, "messages.yaml");
        dicttype = OrderedDict{Any, Any},
    )
    definitions["enums"]["Unsigned"]["values"]["maximum"] = typemax(UInt64)
    mktempdir() do directory

        julia_file = GradientMicroIDL.generate_julia(definitions, directory, "Interop")
        GradientMicroIDL.generate_cpp(definitions, directory, "Interop")
        example_file = GradientMicroIDL.generate_julia(EXAMPLE, directory, "MyMessages")
        GradientMicroIDL.generate_cpp(EXAMPLE, directory, "MyMessages")

        # Fresh parent modules isolate the generated definitions from other test modules.
        # The latest-world call covers both new bindings and newly generated constructors.
        parent = Module(gensym(:GeneratedInterop))
        root = Base.include(parent, julia_file)
        example = Base.include(parent, example_file)
        Base.invokelatest(test_compiled, root, example, directory, compiler, eigen)

    end

end

end # module CppInteropTests
