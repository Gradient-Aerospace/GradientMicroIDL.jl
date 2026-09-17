# Public specifications describe declarations, not resolved layouts. Ordered vectors are
# intentional: constructor arguments and equal-alignment fields follow declaration order.

"""
    FieldSpec(name, type; description = "")

Describes one message field. `type` is an IDL expression such as `"float64[3]"` or
`"MotorParameters{N}[M]"`. References are resolved when code is generated.
"""
struct FieldSpec
    name::String
    type::String
    description::String
end

FieldSpec(name::AbstractString, type::AbstractString; description::AbstractString = "") =
    FieldSpec(String(name), String(type), String(description))

"""
    ParameterSpec(name; type = "int64")

Declares a message length parameter. Currently only `int64` is supported; concrete
lengths must be positive. Parameters are supplied in their declaration order.
"""
struct ParameterSpec
    name::String
    type::String
end

ParameterSpec(name::AbstractString; type::AbstractString = "int64") =
    ParameterSpec(String(name), String(type))

"""
    MessageSpec(name; fields, parameters = ParameterSpec[], description = "")

Describes a message with ordered `FieldSpec` and `ParameterSpec` vectors. Constructors
follow field order even when storage is rearranged. Generation validates names, type
references, and parameter usage for specifications created directly in Julia as well.
"""
struct MessageSpec
    name::String
    fields::Vector{FieldSpec}
    parameters::Vector{ParameterSpec}
    description::String
end

function MessageSpec(
    name::AbstractString;
    fields,
    parameters = ParameterSpec[],
    description::AbstractString = "",
)
    return MessageSpec(String(name), fields, parameters, String(description))
end

"""
    EnumSpec(name, type, values)

Describes an enum with an integer base type and ordered `name => value` pairs.
Integer values can use the full range of their base type, including `UInt64`.
Generation checks names, duplicates, and integer ranges.
"""
struct EnumSpec
    name::String
    type::String
    values::Vector{Pair{String, Integer}}
end

"""
    IncludeSpec(filename)

Includes a namespace from a YAML or JSON file. Relative paths use the containing file's
folder, or the `base_dir` supplied when generating from a Julia specification/dictionary.
The corresponding reader package must be loaded.
"""
struct IncludeSpec
    filename::String
end

"""
    NamespaceSpec(; enums = EnumSpec[], messages = MessageSpec[], namespaces = [])
    NamespaceSpec(definitions::AbstractDict)

Describes a namespace using ordered enum and message vectors. `namespaces` is an ordered
vector of `name => NamespaceSpec(...)` or `name => IncludeSpec(...)` pairs. The root name
is supplied to `generate_julia` or `generate_cpp`.

The dictionary constructor converts the same schema used by YAML/JSON into specification
objects. It checks dictionary structure; semantic validation happens during generation.
Includes are retained until loading/generation supplies their directory context.
"""
struct NamespaceSpec
    enums::Vector{EnumSpec}
    messages::Vector{MessageSpec}
    namespaces::Vector{Pair{String, Union{NamespaceSpec, IncludeSpec}}}
    source::Union{Nothing, String}
end

# source is provenance attached by the loader, not part of the user's declaration schema.
function NamespaceSpec(;
    enums = EnumSpec[],
    messages = MessageSpec[],
    namespaces = Pair{String, Union{NamespaceSpec, IncludeSpec}}[],
)
    return NamespaceSpec(enums, messages, namespaces, nothing)
end

# Inputs can contain scalars and lists where the IDL expects a dictionary. Check each
# structural boundary so later iteration failures do not obscure the malformed entry.
function mapping(value, context)
    value isa AbstractDict || invalid(context, "expected a dictionary")
    return value
end

# Namespace and enum dictionaries have fixed section names. Rejecting other keys catches
# misspellings that would otherwise silently omit part of the requested interface.
function check_keys(definitions, allowed, context)
    for key in keys(definitions)
        key isa AbstractString && key in allowed ||
            invalid(context, "unknown entry $(repr(key))")
    end
end

# Dictionary conversion owns schema checks only. It never calculates layout or resolves
# references, so this path and direct specification construction share the same resolver.
function specification_string(value, context)
    value isa AbstractString || invalid(context, "expected a string")
    return String(value)
end

function field_specification(name, entry, context)

    entry isa AbstractString && return FieldSpec(name, entry)
    entry = mapping(entry, context)
    check_keys(entry, ("type", "description"), context)
    return FieldSpec(
        name,
        specification_string(get(entry, "type", nothing), context);
        description = specification_string(get(entry, "description", ""), context),
    )

end

function message_specification(name, entry, context)

    entry = mapping(entry, context)
    check_keys(entry, ("fields", "parameters", "description"), context)
    fields = FieldSpec[]
    for (key, field) in mapping(get(entry, "fields", nothing), "$context.fields")

        key = specification_string(key, context)
        push!(fields, field_specification(key, field, "$context.$key"))

    end
    parameters = ParameterSpec[]
    for (key, type) in mapping(get(entry, "parameters", Dict()), "$context.parameters")

        push!(parameters, ParameterSpec(
            specification_string(key, context);
            type = specification_string(type, context),
        ))

    end
    return MessageSpec(
        name;
        fields,
        parameters,
        description = specification_string(get(entry, "description", ""), context),
    )

end

function enum_specification(name, entry, context)

    entry = mapping(entry, context)
    check_keys(entry, ("type", "values"), context)
    values = Pair{String, Integer}[]
    for (key, value) in mapping(get(entry, "values", nothing), "$context.values")

        value isa Integer || invalid(context, "enum values must be integers")
        push!(values, specification_string(key, context) => value)

    end
    return EnumSpec(
        name,
        specification_string(get(entry, "type", nothing), context),
        values,
    )

end

# Inline child dictionaries become NamespaceSpecs; filenames become explicit IncludeSpecs.
# This retains the distinction without allowing arbitrary strings throughout the tree.
function namespace_specification(definitions, context)

    definitions = mapping(definitions, context)
    check_keys(definitions, ("enums", "messages", "namespaces"), context)
    enums = EnumSpec[]
    messages = MessageSpec[]
    namespaces = Pair{String, Union{NamespaceSpec, IncludeSpec}}[]
    for (key, entry) in mapping(get(definitions, "enums", Dict()), "$context.enums")

        key = specification_string(key, context)
        push!(enums, enum_specification(key, entry, "$context.$key"))

    end
    for (key, entry) in mapping(get(definitions, "messages", Dict()), "$context.messages")

        key = specification_string(key, context)
        push!(messages, message_specification(key, entry, "$context.$key"))

    end
    children = mapping(get(definitions, "namespaces", Dict()), "$context.namespaces")
    for (key, entry) in children

        key = specification_string(key, context)
        child = entry isa AbstractString ? IncludeSpec(String(entry)) :
            namespace_specification(entry, "$context.$key")
        push!(namespaces, key => child)

    end
    return NamespaceSpec(; enums, messages, namespaces)

end

NamespaceSpec(definitions::AbstractDict) = namespace_specification(definitions, "namespace")
