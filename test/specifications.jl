module SpecificationTests

using Test
using GradientMicroIDL
using OrderedCollections: OrderedDict
import YAML
import JSON

# The same declaration travels through every public input path. Comparing complete
# output files checks that adapters preserve ordering, documentation, and parameters.
@testset "Specification input paths" begin

    specification = NamespaceSpec(;
        enums = [EnumSpec("Mode", "uint8", ["idle" => 0, "active" => 1])],
        messages = [MessageSpec(
            "Samples";
            description = "A batch of measurements.",
            parameters = [ParameterSpec("N")],
            fields = [
                FieldSpec("mode", "Mode"),
                FieldSpec("values", "float64[N]"; description = "In acquisition order."),
            ],
        )],
    )
    definitions = OrderedDict(
        "enums" => OrderedDict(
            "Mode" => OrderedDict(
                "type" => "uint8",
                "values" => OrderedDict("idle" => 0, "active" => 1),
            ),
        ),
        "messages" => OrderedDict(
            "Samples" => OrderedDict(
                "description" => "A batch of measurements.",
                "parameters" => OrderedDict("N" => "int64"),
                "fields" => OrderedDict(
                    "mode" => "Mode",
                    "values" => OrderedDict(
                        "type" => "float64[N]",
                        "description" => "In acquisition order.",
                    ),
                ),
            ),
        ),
    )

    mktempdir() do directory

        yaml_file = joinpath(directory, "samples.yaml")
        json_file = joinpath(directory, "samples.json")
        YAML.write_file(yaml_file, definitions)
        write(json_file, JSON.json(definitions))
        loaded = load_specification(json_file)
        @test loaded isa NamespaceSpec
        @test only(loaded.messages).fields[2].description == "In acquisition order."

        for generate in (generate_julia, generate_cpp)

            expected = read(generate(specification, directory, "SamplesAPI"), String)
            for input in (definitions, NamespaceSpec(definitions), yaml_file, json_file)
                @test read(generate(input, directory, "SamplesAPI"), String) == expected
            end

            # A loaded specification is a reusable snapshot, independent of source files.
            @test read(generate(loaded, directory, "SamplesAPI"), String) == expected

        end
        rm(json_file)
        @test isfile(generate_julia(loaded, directory, "Detached"))

    end

end

# Direct construction must not bypass semantic checks previously owned by the YAML
# parser. In particular, vectors can contain duplicates that dictionaries cannot retain.
@testset "Native specification validation" begin

    invalid_messages = [
        MessageSpec("Empty"; fields = FieldSpec[]),
        MessageSpec("Unknown"; fields = [FieldSpec("value", "Missing")]),
        MessageSpec("Zero"; fields = [FieldSpec("value", "float64[0]")]),
        MessageSpec("Repeated"; fields = [FieldSpec("a", "int8"), FieldSpec("a", "int8")]),
        MessageSpec(
            "Parameters";
            parameters = [ParameterSpec("N"), ParameterSpec("N")],
            fields = [FieldSpec("a", "int8[N]")],
        ),
        MessageSpec(
            "Parameters";
            parameters = [ParameterSpec("N"; type = "float64")],
            fields = [FieldSpec("a", "int8[N]")],
        ),
    ]
    mktempdir() do directory

        output = joinpath(directory, "output")
        for generate in (generate_julia, generate_cpp)

            for message in invalid_messages

                specification = NamespaceSpec(; messages = [message])
                @test_throws ArgumentError generate(specification, output, "Invalid")

            end
            for values in (["a" => 256], ["a" => true], ["a" => 0, "a" => 1])

                specification = NamespaceSpec(; enums = [EnumSpec("Mode", "uint8", values)])
                @test_throws ArgumentError generate(specification, output, "Invalid")

            end
            repeated = NamespaceSpec(;
                namespaces = ["Child" => NamespaceSpec(), "Child" => NamespaceSpec()],
            )
            @test_throws ArgumentError generate(repeated, output, "Invalid")

        end
        @test !ispath(output)

    end

end

@testset "Optional readers and includes" begin

    mktempdir() do directory

        # Each include is relative to the file that contains it, including when the
        # formats alternate. A later sibling can reference a type from an earlier one.
        nested = mkpath(joinpath(directory, "nested"))
        write(joinpath(directory, "root.yaml"), "namespaces:\n  Child: nested/child.json\n")
        write(joinpath(nested, "child.json"), """
            {"namespaces": {"Types": "types.yaml", "Uses": {
                "messages": {"Wrapper": {"fields": {"value": "Child.Types.Value"}}}
            }}}
            """)
        write(joinpath(nested, "types.yaml"), """
            messages:
              Value:
                fields:
                  count: uint32
            """)
        specification = NamespaceSpec(;
            namespaces = ["Child" => IncludeSpec("nested/child.json")],
        )
        expected = load_specification(joinpath(directory, "root.yaml"))
        for generate in (generate_julia, generate_cpp)

            actual_file = generate(
                specification,
                directory,
                "Included";
                base_dir = directory,
            )
            actual = read(actual_file, String)
            @test actual == read(generate(expected, directory, "Included"), String)

        end
        root = generate_julia(expected, directory, "Included")
        loaded = Base.include(Module(), root)
        Base.invokelatest() do
            @test fieldtype(loaded.Child.Uses.Wrapper, :value) === loaded.Child.Types.Value
        end

        # Duplicate JSON members must fail before overwriting an earlier declaration.
        json_file = joinpath(directory, "invalid.json")
        write(json_file, """{"messages": {}, "messages": {}}""")
        @test_throws r"duplicate JSON key" load_specification(json_file)
        write(json_file, "{")
        @test_throws ArgumentError load_specification(json_file)
        write(json_file, """{"namespaces": {"Again": "root.yaml"}}""")
        write(joinpath(nested, "types.yaml"), "namespaces:\n  Again: ../invalid.json\n")
        @test_throws r"recursive include" load_specification(json_file)

        # JSON's reader preserves integers beyond signed Int64, unlike YAML's reader.
        write(json_file, """
            {"enums": {"Wide": {"type": "uint64", "values": {
                "largest": 18446744073709551615
            }}}}
            """)
        wide = load_specification(json_file)
        @test only(only(wide.enums).values).second == typemax(UInt64)
        @test isfile(generate_julia(wide, directory, "WideAPI"))
        @test isfile(generate_cpp(wide, directory, "WideAPI"))

        # A fresh Julia process verifies that optional readers are not loaded by core.
        # It also checks the actionable error before a reader is explicitly imported.
        script = """
            using GradientMicroIDL
            for name in (:GradientMicroIDLYAMLExt, :GradientMicroIDLJSONExt)
                @assert Base.get_extension(GradientMicroIDL, name) === nothing
            end
            generate_julia(NamespaceSpec(), $(repr(directory)), "Empty")
            try
                load_specification($(repr(json_file)))
                error("expected a missing reader error")
            catch exception
                @assert exception isa ArgumentError
                @assert occursin("import JSON", sprint(showerror, exception))
            end
            import JSON
            @assert load_specification($(repr(json_file))) isa NamespaceSpec
            """
        project = dirname(Base.active_project())
        command = `$(Base.julia_cmd()) --project=$project -e $script`
        @test success(command)

    end

end

# These inputs used to generate successfully but either overwrite a namespace file or
# fail when Julia loaded the result. Reject them before creating or changing output.
@testset "Output paths and special names" begin

    mktempdir() do directory

        children = NamespaceSpec(;
            namespaces = ["Sensors" => NamespaceSpec(), "sensors" => NamespaceSpec()],
        )
        nested = NamespaceSpec(; namespaces = ["Equipment" => children])
        output = joinpath(directory, "output")
        for specification in (children, nested)
            @test_throws r"output path collides" generate_julia(specification, output, "Root")
            @test !ispath(output)
        end

        # A failed regeneration must also preserve an existing valid output tree.
        root_file = generate_julia(NamespaceSpec(), output, "Root")
        previous = read(root_file, String)
        @test_throws r"output path collides" generate_julia(children, output, "Root")
        @test read(root_file, String) == previous
        @test readdir(dirname(root_file)) == ["Root.jl"]

        # EnumX reserves T for the enum's underlying type. The other names are lexical
        # identifiers that Julia disallows as constructor arguments during lowering.
        invalid_specs = [NamespaceSpec(; enums = [EnumSpec("T", "uint8", ["ready" => 0])])]
        for name in ("ccall", "cglobal")
            push!(invalid_specs, NamespaceSpec(;
                messages = [MessageSpec("Packet"; fields = [FieldSpec(name, "uint8")])],
            ))
        end
        for generate in (generate_julia, generate_cpp), specification in invalid_specs

            destination = joinpath(directory, "invalid")
            @test_throws ArgumentError generate(specification, destination, "Root")
            @test !ispath(destination)

        end

        # Case folding applies to full paths, not globally to namespace names. Distinct
        # parents can both contain Sensors, and their generated modules must load normally.
        valid = NamespaceSpec(; namespaces = [
            "Left" => NamespaceSpec(; namespaces = ["Sensors" => NamespaceSpec()]),
            "Right" => NamespaceSpec(; namespaces = ["sensors" => NamespaceSpec()]),
        ])
        loaded = Base.include(Module(), generate_julia(valid, output, "Valid"))
        Base.invokelatest() do
            @test loaded.Left.Sensors isa Module
            @test loaded.Right.sensors isa Module
        end

    end

end

end # module SpecificationTests
