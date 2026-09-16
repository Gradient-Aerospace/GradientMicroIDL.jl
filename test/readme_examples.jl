module ReadmeExampleTests

using Test
using OrderedCollections: OrderedDict
import GradientMicroIDL
import YAML

include("cpp_test_setup.jl")
using .CppTestSetup: cpp_compiler, eigen_include_dir

const EXAMPLES = joinpath(@__DIR__, "..", "examples")
const README = joinpath(@__DIR__, "..", "readme.md")
const EXAMPLE_MODULES = (
    "gnss.yaml" => "GNSS",
    "control.yaml" => "Control",
    "messages.yaml" => "MyMessages",
)

# Dictionary equality ignores order, but field and parameter order affect our generated
# interface. Compare ordered entries recursively while ignoring YAML comments/formatting.
function ordered_entries(value)
    return value isa AbstractDict ?
        [(key, ordered_entries(child)) for (key, child) in value] : value
end

@testset "README YAML examples" begin

    # The control example is explained in two excerpts, with the second adding messages
    # to the first. Join those declarations exactly as they appear in control.yaml.
    blocks = [YAML.load(match.captures[1]; dicttype = OrderedDict{Any, Any}) for
        match in eachmatch(r"```yaml\n(.*?)```"s, read(README, String))]
    @test length(blocks) == 4
    control = blocks[2]
    merge!(control["messages"], blocks[3]["messages"])
    excerpts = (blocks[1], control, blocks[4])
    for (definitions, (filename, _)) in zip(excerpts, EXAMPLE_MODULES)

        stored = YAML.load_file(
            joinpath(EXAMPLES, filename);
            dicttype = OrderedDict{Any, Any},
        )
        @test ordered_entries(definitions) == ordered_entries(stored)

    end

    # Enumerating the directory makes a newly added YAML example require a test entry.
    examples = filter(name -> endswith(name, ".yaml"), readdir(EXAMPLES))
    @test Set(examples) == Set(first.(EXAMPLE_MODULES))

end

@testset "Generate every documented example" begin

    compiler = cpp_compiler()
    eigen = eigen_include_dir()
    mktempdir() do directory

        for (filename, name) in EXAMPLE_MODULES

            input = joinpath(EXAMPLES, filename)
            julia_file = GradientMicroIDL.generate_julia(input, directory, name)
            cpp_file = GradientMicroIDL.generate_cpp(input, directory, name)
            @test isfile(cpp_file)
            root = Base.include(Module(gensym(:ReadmeExample)), julia_file)
            @test nameof(root) == Symbol(name)

            # These constructors are the README's public API. Explicit instantiations
            # test both a concrete field reference and forwarding through nested arrays.
            if name == "Control"

                Base.invokelatest(root) do controls

                    motor = controls.MotorParameters(;
                        position = (0.0, 0.0, 0.0),
                        torque_constant = 1.0,
                    )
                    parameters = controls.ControlParameters{2}(;
                        num_motors = 2,
                        motors = (motor, motor),
                    )
                    @test isbitstype(typeof(parameters))
                    @test parameters.motors[2].torque_constant == 1.0
                    @test fieldtype(controls.VehicleParameters, :control) ==
                        controls.ControlParameters{4}
                    fleet = controls.FleetParameters{2, 3}(
                        (parameters, parameters, parameters),
                    )
                    @test fleet.control[3] === parameters

                end

            end

        end

        # Compile all example headers together. Constructing the parameterized examples
        # also instantiates their constructor-body layout assertions, without linking.
        source = joinpath(directory, "examples.cpp")
        write(source, """
            #include "GNSS/GNSS.hpp"
            #include "Control/Control.hpp"
            #include "MyMessages/MyMessages.hpp"

            void check_examples() {
                Control::ControlParameters<2> control{};
                Control::VehicleParameters vehicle{};
                Control::FleetParameters<2, 3> fleet{};
                (void)control;
                (void)vehicle;
                (void)fleet;
            }
            """)
        command = `$compiler -std=c++17 -pedantic-errors -fsyntax-only`
        process = run(`$command -I $directory -isystem $eigen $source`)
        @test success(process)

    end

end

@testset "Empty sections and nonempty declarations" begin

    # Empty sections and omitted sections describe the same valid empty namespace.
    # This is distinct from declaring a particular message or enum with no members.
    mktempdir() do directory

        for definitions in (Dict(), Dict("enums" => Dict(), "messages" => Dict()))

            julia_file = GradientMicroIDL.generate_julia(definitions, directory, "Empty")
            cpp_file = GradientMicroIDL.generate_cpp(definitions, directory, "Empty")
            root = Base.include(Module(gensym(:EmptyExample)), julia_file)
            @test names(root) == [:Empty]
            @test occursin("namespace Empty", read(cpp_file, String))

        end

        invalid_definitions = (
            Dict("messages" => Dict("EmptyMessage" => Dict("fields" => Dict()))),
            Dict("enums" => Dict("EmptyEnum" => Dict(
                "type" => "uint8",
                "values" => Dict(),
            ))),
        )
        for definitions in invalid_definitions
            @test_throws ArgumentError GradientMicroIDL.generate_julia(
                definitions,
                directory,
                "Invalid",
            )
        end

    end

end

end # module ReadmeExampleTests
