# Format-specific packages extend this small reading boundary. The rest of loading owns
# include resolution and provenance and works identically for YAML and JSON, even mixed.
function read_definitions(::Val{format}, filename) where format
    package = format == :yaml ? "YAML" : "JSON"
    invalid(filename, "enable the $package reader with `import $package` before loading")
end

"""
    load_specification(filename)

Loads a YAML (`.yaml`/`.yml`) or JSON (`.json`) file into a `NamespaceSpec`, expanding
namespace includes relative to each containing file. Load YAML or JSON first to enable
its optional reader extension. The returned tree can generate either language without
reading its source files again.

Malformed input, missing files, and recursive includes raise `ArgumentError`. Type
references and layouts are validated when the specification is passed to a generator.
"""
function load_specification(filename::AbstractString)
    return load_specification(filename, String[])
end

# Canonical filenames catch recursion through aliases or symlinks. The stack holds only
# active includes, so a file can still be used at several different namespace locations.
function load_specification(filename, stack)

    isfile(filename) || invalid(filename, "definition file not found")
    filename = realpath(filename)
    filename in stack &&
        invalid(filename, "recursive include: $(join([stack; filename], " -> "))")
    extension = lowercase(splitext(filename)[2])
    format = extension in (".yaml", ".yml") ? :yaml : extension == ".json" ? :json : nothing
    isnothing(format) && invalid(filename, "expected a .yaml, .yml, or .json file")
    push!(stack, filename)
    try

        specification = NamespaceSpec(read_definitions(Val(format), filename))
        expanded = expand_includes(specification, dirname(filename), stack)
        return NamespaceSpec(
            expanded.enums,
            expanded.messages,
            expanded.namespaces,
            filename,
        )

    catch error

        error isa InterruptException && rethrow()
        invalid(filename, sprint(showerror, error))

    finally
        pop!(stack)
    end

end

# Expansion makes a new namespace tree; neither direct specifications nor their vectors
# are rewritten. Loaded trees remember their source folder if a caller adds an include.
function expand_includes(specification::NamespaceSpec, base_dir, stack, active = IdSet())

    specification in active && invalid("namespace", "recursive namespace specification")
    push!(active, specification)
    directory = isnothing(specification.source) ? base_dir : dirname(specification.source)
    try

        children = Pair{String, Union{NamespaceSpec, IncludeSpec}}[]
        for (name, child) in specification.namespaces

            expanded = child isa IncludeSpec ?
                load_specification(joinpath(directory, child.filename), stack) :
                expand_includes(child, directory, stack, active)
            push!(children, name => expanded)

        end
        return NamespaceSpec(
            specification.enums,
            specification.messages,
            children,
            specification.source,
        )

    finally
        delete!(active, specification)
    end

end
