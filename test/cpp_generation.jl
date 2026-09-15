module CppGenerationTests

using Test
using OrderedCollections: OrderedDict
import GradientMicroIDL

const EXAMPLE = joinpath(@__DIR__, "..", "examples", "my_messages.yaml")

@testset "C++ example generation" begin

    # The same input used by Julia generation includes files and references sibling
    # namespaces. Check the resulting public interface without invoking a C++ compiler.
    mktempdir() do directory

        filename = GradientMicroIDL.generate_cpp(EXAMPLE, directory, "MyMessages")
        @test filename == joinpath(directory, "MyMessages", "MyMessages.hpp")
        source = read(filename, String)
        @test occursin("#pragma once", source)
        @test occursin("#include <Eigen/Core>", source)
        @test occursin("enum class GNSSFixType : ::std::uint8_t", source)
        @test occursin("fix_3d = 3ULL,", source)
        @test occursin("namespace Navigation {", source)
        @test occursin(
            "::MyMessages::Sensors::Barometer::BarometerMeasurement " *
                "barometer_measurement{};",
            source,
        )
        @test occursin(
            "::MyMessages::Sensors::GNSS::GNSSMeasurement gnss_measurement{};",
            source,
        )

        # Earlier namespaces must appear before the types that consume them. The timestamp
        # constructor takes weeks first even though microseconds occupies the first bytes.
        common = first(findfirst("namespace Common {", source))
        sensors = first(findfirst("namespace Sensors {", source))
        navigation = first(findfirst("namespace Navigation {", source))
        @test common < sensors < navigation
        @test occursin("::std::uint16_t weeks,", source)
        @test occursin("::std::uint64_t microseconds\n", source)
        @test occursin(": microseconds{microseconds},", source)
        @test occursin("weeks{weeks}", source)
        @test occursin("static_assert(sizeof(GNSSTimeStamp) == 16);", source)
        @test occursin("static_assert(offsetof(GNSSTimeStamp, weeks) == 8);", source)

        # Arrays remain plain storage; views are methods, not additional data members.
        @test occursin("double position_ecef[3]{};", source)
        @test occursin("double position_covariance_ecef[9]{};", source)
        @test occursin("const double (&position_ecef)[3],", source)
        @test occursin("::std::copy_n(position_ecef, 3, this->position_ecef);", source)
        @test occursin("auto position_ecef_eigen() &", source)
        @test occursin("auto position_ecef_eigen() const &", source)
        @test occursin("::Eigen::Map<const Matrix, ::Eigen::Unaligned>", source)
        @test occursin("void position_ecef_eigen() && = delete;", source)
        @test occursin("void position_ecef_eigen() const && = delete;", source)

        # Regeneration should be deterministic and should leave unrelated files alone.
        marker = joinpath(dirname(filename), "notes.txt")
        write(marker, "keep")
        @test GradientMicroIDL.generate_cpp(EXAMPLE, directory, "MyMessages") == filename
        @test read(filename, String) == source
        @test read(marker, String) == "keep"

    end

end

@testset "C++ field and enum emission" begin

    # Direct dictionary values bypass YAML's Int64 limit. Exercise both 64-bit extremes,
    # which require different C++ literal spellings to avoid overflowing a signed literal.
    definitions = OrderedDict(
        "enums" => OrderedDict(
            "Signed" => OrderedDict(
                "type" => "int64",
                "values" => OrderedDict(
                    "minimum" => typemin(Int64),
                    "maximum" => typemax(Int64),
                ),
            ),
            "Unsigned" => OrderedDict(
                "type" => "uint64",
                "values" => OrderedDict(
                    "maximum" => typemax(UInt64),
                ),
            ),
        ),
        "messages" => OrderedDict(
            "Item" => OrderedDict(
                "code" => "uint8",
            ),
            "Packet" => OrderedDict(
                "bytes"    => "char[9]",
                "counter"  => "uint64",
                "matrix"   => "float32[2,3]",
                "row"      => "float64[1,3]",
                "column"   => "int16[3,1]",
                "items"    => "Item[2]",
                "statuses" => "Signed[2]",
            ),
        ),
        "namespaces" => OrderedDict(
            "Empty" => OrderedDict(),
        ),
    )
    mktempdir() do directory

        filename = GradientMicroIDL.generate_cpp(definitions, directory, "Shapes")
        source = read(filename, String)
        @test occursin("minimum = (-9223372036854775807LL - 1LL),", source)
        @test occursin("maximum = 9223372036854775807LL,", source)
        @test occursin("maximum = 18446744073709551615ULL,", source)

        # Rectangular matrices flatten column-major. Eigen requires a special storage
        # option for a single row, where row-major and column-major sequences coincide.
        @test occursin("float matrix[6]{};", source)
        @test occursin("::Eigen::Matrix<float, 2, 3, ::Eigen::ColMajor>", source)
        @test occursin("::Eigen::Matrix<double, 1, 3, ::Eigen::RowMajor>", source)
        @test occursin("::Eigen::Matrix<::std::int16_t, 3, 1, ::Eigen::ColMajor>", source)
        @test occursin("const float (&matrix)[6],", source)
        @test occursin("::std::copy_n(matrix, 6, this->matrix);", source)

        # Nonnumeric arrays are still supported, but do not acquire Eigen methods.
        @test occursin("::std::uint8_t bytes[9]{};", source)
        @test occursin("::Shapes::Item items[2]{};", source)
        @test occursin("::Shapes::Signed statuses[2]{};", source)
        @test !occursin("bytes_eigen", source)
        @test !occursin("items_eigen", source)
        @test !occursin("statuses_eigen", source)
        @test occursin("namespace Empty {", source)

        # Layout follows alignment first, size second, and original order for ties. Check
        # the entire field sequence so a change cannot silently reorder the plain storage.
        members = filter(split(source, '\n')) do line
            occursin(r"^\s+(?:::Shapes::|::std::|float |double ).*\{\};$", line)
        end
        @test strip.(members) == [
            "::std::uint8_t code{};",
            "double row[3]{};",
            "::Shapes::Signed statuses[2]{};",
            "::std::uint64_t counter{};",
            "float matrix[6]{};",
            "::std::int16_t column[3]{};",
            "::std::uint8_t bytes[9]{};",
            "::Shapes::Item items[2]{};",
        ]
        @test occursin("static_assert(sizeof(Packet) == 96);", source)
        @test occursin("static_assert(alignof(Packet) == 8);", source)
        @test occursin("static_assert(offsetof(Packet, bytes) == 78);", source)
        @test occursin("static_assert(::std::is_standard_layout_v<Packet>);", source)
        @test occursin("static_assert(::std::is_trivially_copyable_v<Packet>);", source)

    end

end

@testset "C++ validation and includes" begin

    # Accessors must not hide existing fields or be mistaken for constructors. These
    # C++-specific errors should be detected before an output directory is created.
    mktempdir() do directory

        output = joinpath(directory, "output")
        definitions = OrderedDict(
            "messages" => OrderedDict(
                "Packet" => OrderedDict(
                    "position"       => "float64[3]",
                    "position_eigen" => "uint8",
                ),
            ),
        )
        @test_throws ArgumentError GradientMicroIDL.generate_cpp(
            definitions,
            output,
            "Conflict",
        )
        @test !ispath(output)

        # A method with the class's name would be parsed as an invalid constructor.
        # Check this separately from a collision with an ordinary field name.
        definitions = OrderedDict(
            "messages" => OrderedDict(
                "position_eigen" => OrderedDict(
                    "position" => "float64[3]",
                ),
            ),
        )
        @test_throws ArgumentError GradientMicroIDL.generate_cpp(
            definitions,
            output,
            "Conflict",
        )
        @test !ispath(output)

        # A dictionary include uses base_dir. A file with only scalar fields does not
        # require Eigen, so consumers of scalar interfaces need no Eigen installation.
        write(
            joinpath(directory, "item.yaml"),
            "messages:\n  Item:\n    value: int32\n",
        )
        definitions = OrderedDict(
            "namespaces" => OrderedDict(
                "Common" => "item.yaml",
            ),
        )
        filename = GradientMicroIDL.generate_cpp(
            definitions,
            output,
            "Included";
            base_dir = directory,
        )
        source = read(filename, String)
        @test occursin("namespace Common {", source)
        @test occursin("::std::int32_t value{};", source)
        @test !occursin("#include <Eigen/Core>", source)

    end

end

end # module CppGenerationTests
