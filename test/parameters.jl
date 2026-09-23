module ParameterTests

using Test
using Libdl
using StaticArrays: SVector, SMatrix
using OrderedCollections: OrderedDict
import GradientMicroIDL
import YAML

include("cpp_test_setup.jl")
using .CppTestSetup: cpp_compiler, eigen_include_dir

const FIXTURE = joinpath(@__DIR__, "cpp", "parameters.yaml")

# A concrete type parameter is necessary in the ccall signature. Keeping this tiny helper
# separate lets the rest of the tests iterate over types created by the generated module.
function read_controller(::Type{Controller}, library) where Controller

    storage = Ref{Controller}()
    update = dlsym(library, :update_controller)
    ccall(update, Cvoid, (Ref{Controller},), storage)
    return storage[]

end

# Exercise several instantiations, including nesting through a child namespace. Changing
# sizes must not change field order or alignment, and every resolved field must be isbits.
function check_parameters(root, library)

    Motor = root.Components.Motor
    Controller = root.Components.Controller

    @testset "Constructors and documentation" begin

        motor = Motor{2}(7, 3, SVector(5.0, 6.0))
        @test motor === Motor{2}(;
            tag = 7,
            scale = 3,
            values = SVector(5.0, 6.0),
        )
        @test motor.tag === UInt8(7)
        @test motor.scale === 3.0
        @test fieldnames(Motor{1}) == fieldnames(Motor{4}) == (:scale, :values, :tag)
        @test fieldtype(Controller{4, 3}, :motors) == SVector{3, Motor{4}}
        @test fieldtype(Controller{4, 3}, :matrix) == SMatrix{1, 2, Motor{4}, 2}
        @test fieldtype(Controller{4, 3}, :backup) == Motor{2}
        binding = Base.Docs.Binding(root.Components, :Motor)
        documentation = Base.Docs.meta(root.Components)[binding].docs[Union{}]
        @test occursin("Stores one motor's coefficients.", documentation.text[1])
        @test occursin(raw"$quotes", documentation.text[1])
        field_documentation = strip(documentation.data[:fields][:values])
        @test field_documentation == "Coefficients in command order."

        # Field documentation also works without a message description. Metadata names
        # remain valid field names because fields live in their own dictionary.
        documented = root.Components.DocumentedFields(1, 2, 3)
        @test documented.fields === UInt8(3)
        @test fieldnames(typeof(documented)) == (:description, :parameters, :fields)
        binding = Base.Docs.Binding(root.Components, :DocumentedFields)
        documentation = Base.Docs.meta(root.Components)[binding].docs[Union{}]
        @test occursin("not message metadata", documentation.data[:fields][:description])

        # Zero is deliberately unsupported, even though StaticArrays itself permits it.
        # An explicit non-Int64 length must not silently acquire a different Julia type.
        @test_throws ArgumentError Motor{0}(0, 0, SVector{0, Float64}())
        @test_throws ArgumentError Motor{Int32(1)}(0, 0, SVector(0.0))

    end

    @testset "Nested template layouts and calls" begin

        layout = dlsym(library, :parameter_layout)
        types = [
            (Motor{1}, :values, :tag),
            (Motor{4}, :values, :tag),
            (Controller{1, 1}, :motors, :count),
            (Controller{4, 3}, :motors, :count),
            (root.Components.Vehicle, :controllers, nothing),
            (root.Nested.Fleet{2}, :vehicles, nothing),
        ]
        for (index, (type, first_field, last_field)) in enumerate(types)

            @test isbitstype(type)
            offset(name) = fieldoffset(type, findfirst(==(name), fieldnames(type)))
            expected = [
                sizeof(type),
                Base.datatype_alignment(type),
                offset(first_field),
                isnothing(last_field) ? 0 : offset(last_field),
            ]
            for (property, value) in enumerate(expected)

                actual = ccall(
                    layout,
                    Csize_t,
                    (Csize_t, Csize_t),
                    index - 1,
                    property - 1,
                )
                @test actual == value

            end

        end

        # C++ creates a nested concrete instance, then changes the last coefficient via
        # an Eigen view. Both array stride and parameter forwarding affect these reads.
        controller = read_controller(Controller{4, 3}, library)
        @test controller.count == 3
        @test controller.gain == 8.0
        @test controller.motors[1].values == SVector(1.0, 2.0, 3.0, 4.0)
        @test controller.motors[3].values == SVector(1.0, 2.0, 3.0, 42.0)
        @test controller.backup.values == SVector(5.0, 6.0)
        @test controller.matrix[1, 2].tag == 7

    end

end

@testset "Parameterized messages" begin

    # Generate into one temporary tree and compile the small independent C++ probe.
    # Documentation containing source delimiters must survive generation and compilation.
    compiler = cpp_compiler()
    eigen = eigen_include_dir()
    mktempdir() do directory

        julia_file = GradientMicroIDL.generate_julia(FIXTURE, directory, "Parameters")
        header = GradientMicroIDL.generate_cpp(FIXTURE, directory, "Parameters")
        @test occursin("Motors in command order.", read(header, String))
        root = Base.include(Module(gensym(:GeneratedParameters)), julia_file)
        source = joinpath(@__DIR__, "cpp", "parameters.cpp")
        binary = joinpath(directory, "parameters.$dlext")
        flags = Sys.isapple() ? ["-dynamiclib", "-fPIC"] : ["-shared", "-fPIC"]
        command = `$compiler -std=c++17 -O2 -Wall -Wextra -pedantic-errors`
        run(`$command $flags -I $directory -isystem $eigen $source -o $binary`)
        library = dlopen(binary)
        try
            Base.invokelatest(check_parameters, root, library)
        finally
            dlclose(library)
        end

        # User code may instantiate templates beyond the concrete references in YAML.
        # Prove the header rejects zero/negative lengths and Eigen's unsupported sizes.
        limits = joinpath(@__DIR__, "cpp", "parameter_limits.cpp")
        syntax = `$command -I $directory -isystem $eigen -fsyntax-only $limits`
        run(syntax)
        for length in (0, -1, Int64(typemax(Int32)) + 1)

            diagnostics = IOBuffer()
            process = run(pipeline(
                ignorestatus(`$syntax -DTEST_LENGTH=$length`);
                stdout = diagnostics,
                stderr = diagnostics,
            ))
            @test !success(process)

        end

    end

end

@testset "Invalid message metadata and parameters" begin

    # Start from a valid declaration and change one feature at a time. Both generators
    # share the parser, and neither should write partial output for an invalid definition.
    mktempdir() do directory

        for specification in (
            "Motor",
            "Motor{0}",
            "Motor{-1}",
            "Motor{2,3}",
            "Motor{N}",
            "Motor{1+1}",
            "float64{2}",
            "float64[999999999999999999999999]",
        )

            definitions = YAML.load_file(FIXTURE; dicttype = OrderedDict{Any, Any})
            messages = definitions["namespaces"]["Components"]["messages"]
            messages["Vehicle"]["fields"]["controllers"] = specification
            for generate in (GradientMicroIDL.generate_julia, GradientMicroIDL.generate_cpp)

                output = joinpath(directory, "invalid")
                @test_throws ArgumentError generate(definitions, output, "Parameters")
                @test !ispath(output)

            end

        end

        # Unknown metadata, malformed documentation, and conflicting parameter names
        # should report the declaration error rather than fail in generated source.
        changes = [
            ("values", "float64[N]"),
            ("description", 12),
            ("parameters", Dict("N" => "float64")),
            ("parameters", Dict("Motor" => "int64")),
            ("fields", Dict("N" => "uint8")),
            (
                "fields",
                Dict("values" => Dict("description" => "Missing type")),
            ),
            (
                "fields",
                Dict("values" => Dict(
                    "type" => "uint8",
                    "description" => 1,
                )),
            ),
            ("fields", Dict("values" => "float64[N,2]")),
            ("fields", Dict()),
            ("misspelled", "unexpected metadata"),
        ]
        for (key, value) in changes

            definitions = YAML.load_file(FIXTURE; dicttype = OrderedDict{Any, Any})
            definitions["namespaces"]["Components"]["messages"]["Motor"][key] = value
            @test_throws ArgumentError GradientMicroIDL.generate_julia(
                definitions,
                joinpath(directory, "invalid"),
                "Parameters",
            )

        end

    end

end

end # module ParameterTests
