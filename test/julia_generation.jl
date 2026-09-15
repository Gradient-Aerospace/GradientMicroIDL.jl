module JuliaGenerationTests

using Test
using OrderedCollections: OrderedDict
using StaticArrays: SVector, SMatrix
import GradientMicroIDL

const EXAMPLE = joinpath(@__DIR__, "..", "examples", "my_messages.yaml")

# Each generated module gets a fresh parent module so tests can reuse names without
# replacing earlier definitions. The callback keeps world-age handling in this one helper.
function load_generated(check, filename)

    # Both bindings and methods from include must be accessed in the latest world.
    root = Base.include(Module(gensym(:Generated)), filename)
    return Base.invokelatest(check, root)

end

@testset "Example generation" begin

    # The real example exercises file includes and references across nested namespaces.
    # Temporary output keeps the test from replacing the example's generated files.
    mktempdir() do directory

        filename = GradientMicroIDL.generate_julia(EXAMPLE, directory, "MyMessages")
        @test filename == joinpath(directory, "MyMessages", "MyMessages.jl")
        load_generated(filename) do root

            # The public modules and enum values must survive generation. The isbits
            # checks also cover messages that contain other messages several levels deep.
            gnss = root.Sensors.GNSS
            @test all(name -> name in names(root), (:Common, :Sensors, :GNC))
            @test sizeof(gnss.GNSSFixType.T) == 1
            @test UInt8(gnss.GNSSFixType.fix_3d) == 3
            @test isbitstype(gnss.GNSSMeasurement)
            @test isbitstype(root.GNC.Navigation.NavInputs)

            # YAML lists weeks first, but storage puts microseconds first for alignment.
            # Both constructors must keep that distinction and convert ordinary integers.
            timestamp = gnss.GNSSTimeStamp(2, 30)
            keyword_timestamp = gnss.GNSSTimeStamp(; weeks = 2, microseconds = 30)
            @test timestamp === keyword_timestamp
            @test timestamp.weeks === UInt16(2)
            @test timestamp.microseconds === UInt64(30)
            @test fieldnames(gnss.GNSSTimeStamp) == (:microseconds, :weeks)

            # Build a complete measurement to check that enum, message, vector, and
            # matrix fields can be supplied together through the keyword constructor.
            position = SVector(1.0, 2.0, 3.0)
            covariance = SMatrix{3, 3}(1.0:9.0)
            measurement = gnss.GNSSMeasurement(;
                timestamp,
                fix_type                 = gnss.GNSSFixType.fix_3d,
                position_ecef            = position,
                velocity_ecef            = -position,
                position_covariance_ecef = covariance,
                velocity_covariance_ecef = covariance,
            )
            @test measurement.position_ecef === position
            @test measurement.position_covariance_ecef === covariance

            # Navigation combines messages from sibling namespaces. This also checks
            # positional construction when the larger GNSS field moves ahead of barometer.
            local_time = root.Common.LocalTimeStamp(123)
            barometer = root.Sensors.Barometer.BarometerMeasurement(
                local_time,
                1000,
                20,
            )
            inputs = root.GNC.Navigation.NavInputs(barometer, measurement)
            @test inputs.barometer_measurement === barometer
            @test inputs.gnss_measurement === measurement

        end

    end

end

@testset "Field layout" begin

    # The nine-byte array is larger than a UInt64 but needs less alignment. This fixture
    # distinguishes alignment-first ordering from size-first ordering. The two UInt64
    # fields tie in both measures, so their original order must be preserved.
    definitions = OrderedDict(
        "enums" => OrderedDict(
            "Status" => OrderedDict(
                "type" => "int8",
                "values" => OrderedDict(
                    "bad"  => -1,
                    "good" => 1,
                ),
            ),
        ),
        "messages" => OrderedDict(
            "Packet" => OrderedDict(
                "bytes"  => "char[9]",
                "first"  => "uint64",
                "second" => "uint64",
                "matrix" => "float32[2,3]",
            ),
            "Container" => OrderedDict(
                "packets" => "Packet[2]",
                "status"  => "Status[2]",
            ),
        ),
        "namespaces" => OrderedDict(
            "Empty" => OrderedDict(),
        ),
    )
    mktempdir() do directory

        filename = GradientMicroIDL.generate_julia(definitions, directory, "Layout")
        load_generated(filename) do root

            # Storage occupies 8 + 8 + 24 + 9 = 49 bytes before trailing padding rounds
            # the size up to 56. These offsets check the actual layout of the Julia type.
            packet_type = root.Packet
            @test fieldnames(packet_type) == (:first, :second, :matrix, :bytes)
            @test [fieldoffset(packet_type, index) for index in 1:4] == [0, 8, 16, 40]
            @test sizeof(packet_type) == 56
            @test Base.datatype_alignment(packet_type) == 8
            @test isbitstype(packet_type)
            @test isdefined(root, :Empty)

            # Different values for the tied fields expose any constructor argument swap.
            # The rectangular matrix makes its column-major element order easy to inspect.
            bytes = SVector{9, UInt8}(1:9)
            matrix = SMatrix{2, 3, Float32}(1:6)
            packet = packet_type(bytes, 11, 22, matrix)
            keyword_packet = packet_type(;
                bytes,
                first  = 11,
                second = 22,
                matrix,
            )
            @test packet === keyword_packet
            @test (packet.first, packet.second) === (UInt64(11), UInt64(22))
            @test packet.bytes === bytes
            @test packet.matrix[2, 3] == 6
            @test Tuple(packet.matrix) == Tuple(Float32.(1:6))

            # Arrays of messages must include each element's trailing padding. Two
            # 56-byte packets plus two enum bytes round up to a 120-byte container.
            @test fieldtype(root.Container, :packets) == SVector{2, packet_type}
            @test fieldtype(root.Container, :status) == SVector{2, root.Status.T}
            @test isbitstype(root.Container)
            @test sizeof(root.Container) == 120

        end

    end

end

@testset "Invalid inputs" begin

    # Rejected inputs should leave no output directory, so a failed generation cannot
    # look like a usable result. Each case below fails at a different validation step.
    mktempdir() do directory

        # A missing type and a forward reference are both unavailable at the point of
        # use. The other cases exercise the positive-size and vector/matrix restrictions.
        output = joinpath(directory, "output")
        for specification in ("Missing", "Later", "float64[0]", "int8[2,3,4]")

            definitions = OrderedDict(
                "messages" => OrderedDict(
                    "Packet" => OrderedDict(
                        "value" => specification,
                    ),
                    "Later" => OrderedDict(
                        "value" => "int8",
                    ),
                ),
            )
            @test_throws ArgumentError GradientMicroIDL.generate_julia(
                definitions,
                output,
                "Invalid",
            )

        end

        # An out-of-range enum value must fail during generation, rather than producing
        # a source file that fails only when the user loads it.
        definitions = OrderedDict(
            "enums" => OrderedDict(
                "Status" => OrderedDict(
                    "type" => "uint8",
                    "values" => OrderedDict(
                        "large" => 256,
                    ),
                ),
            ),
        )
        @test_throws ArgumentError GradientMicroIDL.generate_julia(
            definitions,
            output,
            "Invalid",
        )
        @test !ispath(output)

        # A type cannot replace the binding of its containing module. Spell out the
        # nested dictionaries to show that this is Child.Child, not two sibling names.
        definitions = OrderedDict(
            "namespaces" => OrderedDict(
                "Child" => OrderedDict(
                    "messages" => OrderedDict(
                        "Child" => OrderedDict(
                            "value" => "int8",
                        ),
                    ),
                ),
            ),
        )
        @test_throws ArgumentError GradientMicroIDL.generate_julia(
            definitions,
            output,
            "Invalid",
        )

        # The dictionary include uses base_dir, while the file's own include is relative
        # to its nested directory. Resolving both correctly reveals the recursive include.
        mkpath(joinpath(directory, "nested"))
        write(
            joinpath(directory, "nested", "loop.yaml"),
            "namespaces:\n  Again: loop.yaml\n",
        )
        definitions = OrderedDict(
            "namespaces" => OrderedDict(
                "Loop" => "nested/loop.yaml",
            ),
        )
        error = try
            GradientMicroIDL.generate_julia(
                definitions,
                output,
                "Invalid";
                base_dir = directory,
            )
        catch exception
            exception
        end
        @test error isa ArgumentError
        @test occursin("recursive include", sprint(showerror, error))
        @test !ispath(output)

    end

end

end # module JuliaGenerationTests
