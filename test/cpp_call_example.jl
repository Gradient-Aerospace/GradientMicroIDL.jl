module CppCallExampleTests

using Test
using Libdl
using StaticArrays: SVector, SMatrix
import GradientMicroIDL

include("cpp_test_setup.jl")
using .CppTestSetup: cpp_compiler, eigen_include_dir

# Keep the actual call separate from compilation so the example's essential steps are
# easy to follow. The type parameter supplies the concrete type required by ccall.
function test_translation(gnss, ::Type{GNSSMeasurement}, library) where GNSSMeasurement

    # Construct an ordinary generated Julia value using the included GNSS example.
    covariance = SMatrix{3, 3}(1.0:9.0)
    measurement = GNSSMeasurement(;
        timestamp                = gnss.GNSSTimeStamp(2, 30),
        fix_type                 = gnss.GNSSFixType.fix_3d,
        position_ecef            = SVector(1.0, 2.0, 3.0),
        velocity_ecef            = SVector(4.0, 5.0, 6.0),
        position_covariance_ecef = covariance,
        velocity_covariance_ecef = covariance,
    )

    # Ref creates addressable storage for the immutable message. Passing the Ref directly
    # keeps it alive during ccall; C++ receives a GNSSMeasurement* pointing to its contents.
    # Cvoid corresponds to C++ void, and the one-element tuple describes the pointer arg.
    storage = Ref(measurement)
    translate_position = dlsym(library, :translate_position)
    ccall(translate_position, Cvoid, (Ref{GNSSMeasurement},), storage)

    # Read the updated value from the Ref after the call. The original Julia value is
    # unchanged; the storage in the Ref contains the result of the C++ mutation.
    updated = storage[]
    @test updated.position_ecef == SVector(11.0, 22.0, 33.0)
    @test measurement.position_ecef == SVector(1.0, 2.0, 3.0)
    @test updated.timestamp === measurement.timestamp
    @test updated.fix_type === measurement.fix_type
    @test updated.velocity_ecef === measurement.velocity_ecef
    @test updated.position_covariance_ecef === measurement.position_covariance_ecef
    @test updated.velocity_covariance_ecef === measurement.velocity_covariance_ecef

end

@testset "Example: calling C++ from Julia" begin

    # Generate both languages from the supplied example and its included YAML files.
    # All generated files and the compiled library belong to this temporary directory.
    compiler = cpp_compiler()
    eigen = eigen_include_dir()
    example = joinpath(@__DIR__, "..", "examples", "my_messages.yaml")
    mktempdir() do directory

        julia_file = GradientMicroIDL.generate_julia(example, directory, "MyMessages")
        GradientMicroIDL.generate_cpp(example, directory, "MyMessages")
        messages = Base.include(Module(gensym(:CallExample)), julia_file)

        # Build the short, handwritten extern "C" function as a shared library. These
        # flags select the native shared-library format on macOS or Linux, respectively.
        source = joinpath(@__DIR__, "cpp", "mutate_measurement.cpp")
        binary = joinpath(directory, "measurement.$dlext")
        flags = Sys.isapple() ? ["-dynamiclib", "-fPIC"] : ["-shared", "-fPIC"]
        command = `$compiler -std=c++17 -O2 -Wall -Wextra -pedantic-errors`
        run(`$command $flags -I $directory -isystem $eigen $source -o $binary`)

        # Resolve and call the function while the library is loaded. Newly included Julia
        # constructors require the latest world; this is only needed for dynamic generation.
        library = dlopen(binary)
        try

            Base.invokelatest(messages, library) do root, handle

                gnss = root.Sensors.GNSS
                test_translation(gnss, gnss.GNSSMeasurement, handle)

            end

        finally
            dlclose(library)
        end

    end

end

end # module CppCallExampleTests
