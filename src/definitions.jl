# The parser records what was declared and resolves references before source is printed.
# This keeps YAML traversal and memory-layout decisions out of the language-specific
# printer. Only completed enum and message definitions enter the shared type table.

# Lengths are either positive integer literals or names scoped to a message. Layouts may
# additionally contain small arithmetic trees built by this parser, never parsed Julia
# code. Keeping symbolic sizes lets one definition describe every template instantiation.
const Length = Union{Int, Symbol}
const LayoutSize = Union{Int, Symbol, Expr}

# Every field type needs a name, size, and alignment. Arguments identify an instantiated
# message; alignment is independent of positive lengths, even through nested messages.
struct TypeDefinition
    name::String
    kind::Symbol
    size::LayoutSize
    alignment::Int
    arguments::Vector{Length}
end

TypeDefinition(name, kind, size, alignment) =
    TypeDefinition(name, kind, size, alignment, Length[])

# Retain the declared integer type and values so the printer can reproduce the enum
# without inspecting a generated Julia type. BigInt accommodates every supported width.
struct EnumDefinition
    type::TypeDefinition
    base::String
    values::Vector{Pair{String, BigInt}}
end

# Dimensions describe an optional array around a resolved element type. The field size
# includes all elements, while its alignment is inherited from that element type.
struct FieldDefinition
    name::String
    type::TypeDefinition
    dimensions::Vector{Length}
    size::LayoutSize
    description::String
end

# Fields stay in declaration order for constructors. A separate permutation describes
# physical storage, allowing nested messages to use the calculated size and alignment.
struct MessageDefinition
    type::TypeDefinition
    fields::Vector{FieldDefinition}
    storage_order::Vector{Int}
    parameters::Vector{String}
    description::String
end

# The namespace tree also determines the output directory tree. Each section preserves
# declaration order, including child namespaces whose types may depend on earlier siblings.
struct NamespaceDefinition
    name::String
    enums::Vector{EnumDefinition}
    messages::Vector{MessageDefinition}
    namespaces::Vector{NamespaceDefinition}
end

# This is the complete primitive vocabulary. Julia supplies native layout information;
# char deliberately uses a byte because Julia's Char occupies four bytes.
const PRIMITIVES = Dict(
    "int8"    => Int8,
    "int16"   => Int16,
    "int32"   => Int32,
    "int64"   => Int64,
    "uint8"   => UInt8,
    "uint16"  => UInt16,
    "uint32"  => UInt32,
    "uint64"  => UInt64,
    "float32" => Float32,
    "float64" => Float64,
    "char"    => UInt8,
)

# Reserve language keywords and bindings used by the generated modules and constructors.
const RESERVED_NAMES = Set(split("""
    alignas alignof and and_eq asm atomic_cancel atomic_commit atomic_noexcept auto
    bitand bitor bool break case catch char char8_t char16_t char32_t class compl concept
    const consteval constexpr constinit const_cast continue co_await co_return co_yield
    decltype default delete do double dynamic_cast else enum explicit export extern false
    float for friend goto if inline int long mutable namespace new noexcept not not_eq
    nullptr operator or or_eq private protected public reflexpr register reinterpret_cast
    requires return short signed sizeof static static_assert static_cast struct switch
    synchronized template this thread_local throw true try typedef typeid typename union
    unsigned using virtual void volatile wchar_t while xor xor_eq
    baremodule begin end function global import let local macro module outer primitive
    quote where abstract type in isa
    Base Core EnumX StaticArrays include eval
    """))

# All validation errors carry the field, declaration, or file that caused them. Keeping
# this in one helper gives the individual checks a consistent, readable error format.
function invalid(context, message)
    throw(ArgumentError("$context: $message"))
end

# Names become source identifiers and directory names. Validate them before printing
# rather than escaping arbitrary input differently for the Julia and C++ generators.
function identifier(value, context)

    valid = value isa AbstractString && occursin(r"^[A-Za-z][A-Za-z0-9_]*$", value) &&
        !occursin("__", value) && Base.isidentifier(value)
    valid && !(value in RESERVED_NAMES) || invalid(context, "invalid name $(repr(value))")
    return String(value)

end

# YAML can produce scalars and lists where the IDL expects a dictionary. Check at each
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

# Dimensions and layout calculations use BigInt until checked here. This prevents integer
# overflow from turning a large requested array into an apparently valid smaller layout.
function checked_size(value, context)
    0 < value <= typemax(Int) || invalid(context, "size must fit a positive Int")
    return Int(value)
end

# Keep the dependency on Julia's native alignment query in one place. The rest of the
# parser handles primitives, enums, and messages through the same layout record.
function primitive_type(name)
    type = PRIMITIVES[name]
    return TypeDefinition(name, :primitive, sizeof(type), Base.datatype_alignment(type))
end

# File loading is separate from namespace parsing so includes and dictionary inputs share
# the same validation. path is the namespace path; stack contains only active file includes.
function parse_file(filename, path, types, stack)

    # Canonical paths also catch recursive includes spelled with .. or symbolic links.
    # A stack, rather than a permanent visited set, allows reuse under separate namespaces.
    context = join(path, ".")
    isfile(filename) || invalid(context, "YAML file not found: $filename")
    filename = realpath(filename)
    filename in stack && invalid(
        context,
        "recursive include: $(join([stack; filename], " -> "))",
    )
    push!(stack, filename)

    # YAML's default duplicate-key behavior only logs an error and overwrites the value.
    # Its mapping constructor lets us reject duplicates while preserving source order.
    constructors = Dict(
        "tag:yaml.org,2002:map" => (constructor, node) -> YAML.construct_mapping(
            OrderedDict{Any, Any},
            constructor,
            node;
            strict_unique_keys = true,
        ),
    )

    # Attach the filename to parser errors, and remove this include from the active stack
    # even when a child fails. Interrupts should still stop generation immediately.
    try
        definitions = YAML.load_file(filename, constructors)
        return parse_namespace(definitions, path, dirname(filename), types, stack)
    catch error
        error isa InterruptException && rethrow()
        invalid(filename, sprint(showerror, error))
    finally
        pop!(stack)
    end

end

# Resolve an enum to its integer representation without creating a Julia module. This
# makes its layout available to later messages and catches bad values before file writing.
function parse_enum(name, definitions, context)

    # The base type must be an explicit integer type; floats and byte-valued char are not
    # enum base types in the IDL. Each enum must also supply at least one named value.
    definitions = mapping(definitions, context)
    check_keys(definitions, ("type", "values"), context)
    base = get(definitions, "type", nothing)
    valid = base isa AbstractString && base != "char" && haskey(PRIMITIVES, base)
    valid && PRIMITIVES[base] <: Integer ||
        invalid(context, "expected an integer enum type")
    entries = mapping(get(definitions, "values", nothing), context)
    isempty(entries) && invalid(context, "empty enums are not supported")

    # Check values before converting them so signedness or width cannot silently change
    # their meaning. EnumX reserves T, and the enum module also owns its own name.
    values = Pair{String, BigInt}[]
    for (key, value) in entries

        key = identifier(key, context)
        key in ("T", name) && invalid(context, "enum value name $key is reserved")
        valid = value isa Integer && !(value isa Bool)
        valid && typemin(PRIMITIVES[base]) <= value <= typemax(PRIMITIVES[base]) ||
            invalid(context, "value for $key must be an integer in the range of $base")
        push!(values, key => BigInt(value))

    end

    # An enum has the same size and alignment as its declared underlying integer.
    primitive = primitive_type(base)
    type = TypeDefinition(context, :enum, primitive.size, primitive.alignment)
    return EnumDefinition(type, base, values)

end

# Symbolic layout arithmetic has only addition, multiplication, and alignment rounding.
# Fold concrete expressions with BigInt first so generation cannot silently overflow Int.
function layout_expression(operation, arguments...)

    if all(value -> value isa Int, arguments)

        values = BigInt.(arguments)
        result = operation == :+ ? sum(values) : operation == :* ? prod(values) :
            cld(values[1], values[2]) * values[2]
        0 <= result <= typemax(Int) || invalid("layout", "size exceeds Int range")
        return Int(result)

    end

    # These identities keep nested layouts readable in the generated assertions.
    operation == :round && arguments[2] == 1 && return arguments[1]
    identity = operation == :+ ? 0 : 1
    if operation in (:+, :*)

        terms = filter(value -> value != identity, collect(arguments))
        isempty(terms) && return identity
        length(terms) == 1 && return only(terms)
        return Expr(:call, operation, terms...)

    end
    return Expr(:call, operation, arguments...)

end

# Substitute arguments into a previously declared message's size. The same operation
# handles concrete use (Child{4}) and parameter forwarding (Child{N}) without evaluation.
function substitute_size(value, arguments)

    value isa Int && return value
    value isa Symbol && return arguments[value]
    terms = [substitute_size(term, arguments) for term in value.args[2:end]]
    return layout_expression(value.args[1], terms...)

end

# Descriptions are data, not source code. Printers escape them for their own language.
function description(definitions, context)

    value = get(definitions, "description", "")
    value isa AbstractString || invalid(context, "description must be a string")
    return String(value)

end

# Parameters currently represent lengths only. An explicit int64 declaration keeps the
# C++ template signature predictable; every use must also fit the host's positive Int.
function parse_parameters(definitions, path)

    context = join(path, ".")
    entries = mapping(get(definitions, "parameters", OrderedDict()), context)
    parameters = String[]
    for (name, type) in entries

        name = identifier(name, context)
        (name in path || haskey(PRIMITIVES, name)) &&
            invalid(context, "parameter name $name conflicts with a type or namespace")
        type == "int64" || invalid(context, "length parameters must declare int64")
        push!(parameters, name)

    end
    return parameters

end

# A dimension or template argument is one literal or one declared length parameter.
# Deliberately omit expressions and defaults, so names cannot introduce executable code.
function parse_length(text, parameters, context)

    text = strip(text)
    occursin(r"^[0-9]+$", text) && return checked_size(parse(BigInt, text), context)
    text in parameters && return Symbol(text)
    invalid(context, "expected a positive length or declared parameter, got $(repr(text))")

end

# Fields accept a type string or a dictionary with a type and optional documentation.
# Resolve the element separately from its surrounding array shape, retaining arguments
# so both printers can reproduce concrete and parameter-forwarding message references.
function parse_field(name, specification, path, types, parameters)

    context = join([path; name], ".")
    documentation = ""
    if specification isa AbstractDict

        check_keys(specification, ("type", "description"), context)
        documentation = description(specification, context)
        specification = get(specification, "type", nothing)

    end
    specification isa AbstractString || invalid(context, "expected a type string")
    parsed = match(
        r"^([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*)(?:\{([^{}]*)\})?(?:\[([^\]]*)\])?$",
        strip(specification),
    )
    isnothing(parsed) && invalid(context, "invalid type $(repr(specification))")
    reference, arguments_text, dimensions_text = parsed.captures
    arguments = Length[]
    if !isnothing(arguments_text)
        append!(arguments, [parse_length(part, parameters, context) for
            part in split(arguments_text, ',')])
    end

    # The shared table contains completed declarations only. A bare name is local, while
    # a dotted name starts at the root; a reference cannot silently hide a parameter.
    reference in parameters && invalid(context, "a length parameter is not a field type")
    if haskey(PRIMITIVES, reference)

        type = primitive_type(reference)
        isempty(arguments) || invalid(context, "primitive types do not take parameters")

    else

        qualified = occursin('.', reference) ? path[1] * "." * reference :
            join([path[1:end-1]; reference], ".")
        haskey(types, qualified) ||
            invalid(context, "type $reference is not previously defined")
        definition = types[qualified]
        if definition isa MessageDefinition

            expected = length(definition.parameters)
            length(arguments) == expected ||
                invalid(context, "$reference expects $expected parameters")
            substitutions = Dict(Symbol(key) => value for
                (key, value) in zip(definition.parameters, arguments))
            resolved_size = substitute_size(definition.type.size, substitutions)
            type = TypeDefinition(
                qualified,
                :message,
                resolved_size,
                definition.type.alignment,
                arguments,
            )

        else

            isempty(arguments) || invalid(context, "enums do not take parameters")
            type = definition

        end

    end

    # Positive dimensions preserve element alignment. Matrix dimensions are currently
    # literal: SMatrix requires its total length in the Julia field type as well.
    dimensions = Length[]
    if !isnothing(dimensions_text)

        parts = split(dimensions_text, ',')
        length(parts) in (1, 2) ||
            invalid(context, "only vectors and matrices are supported")
        append!(dimensions, [parse_length(part, parameters, context) for part in parts])
        length(dimensions) == 2 && any(value -> value isa Symbol, dimensions) &&
            invalid(context, "matrix dimensions must be literal integers for now")

    end
    size = layout_expression(:*, type.size, dimensions...)
    return FieldDefinition(name, type, dimensions, size, documentation)

end

# Resolve fields in YAML order and sort only by alignment. Positive length parameters do
# not change alignment, so Julia and C++ can share one field order for all instantiations.
function parse_message(name, definitions, path, types)

    context = join(path, ".")
    definitions = mapping(definitions, context)
    check_keys(definitions, ("description", "parameters", "fields"), context)
    documentation = description(definitions, context)
    parameters = parse_parameters(definitions, path)
    entries = mapping(get(definitions, "fields", nothing), "$context.fields")
    isempty(entries) && invalid(context, "empty messages are not supported")
    fields = FieldDefinition[]
    for (key, specification) in entries

        key = identifier(key, context)
        key == name && invalid(context, "field name $key conflicts with its constructor")
        key in parameters && invalid(context, "field name $key conflicts with a parameter")
        push!(fields, parse_field(key, specification, path, types, parameters))

    end
    order = sortperm(
        eachindex(fields);
        by = index -> (-fields[index].type.alignment, index),
    )

    # A field's size includes its own tail padding. With decreasing power-of-two
    # alignments, the sum of prior field sizes is already aligned for the next field.
    # Only the final message size needs rounding, including for arrays of this message.
    alignment = maximum(field.type.alignment for field in fields)
    size = layout_expression(:+, (field.size for field in fields)...)
    size = layout_expression(:round, size, alignment)
    type = TypeDefinition(context, :message, size, alignment)
    return MessageDefinition(type, fields, order, parameters, documentation)

end

# Walk one namespace in the language's definition order. types is shared across the tree
# and contains completed declarations only, which enforces the prior-definition rule
# without a separate dependency-sorting pass. names checks collisions within this module.
function parse_namespace(definitions, path, base_dir, types, stack)

    # Missing sections behave like empty dictionaries. The output still retains empty
    # namespaces because they are valid modules and may be part of the public interface.
    context = join(path, ".")
    definitions = mapping(definitions, context)
    check_keys(definitions, ("enums", "messages", "namespaces"), context)
    namespace = NamespaceDefinition(
        last(path),
        EnumDefinition[],
        MessageDefinition[],
        NamespaceDefinition[],
    )
    names = Set{String}()

    # Complete each declaration before making its type available to later declarations.
    for section in ("enums", "messages", "namespaces")

        entries = mapping(get(definitions, section, OrderedDict()), "$context.$section")
        for (name, entry) in entries

            # Enums, messages, and child modules all occupy the same Julia namespace.
            # Check collisions across sections as well as with required module bindings.
            name = identifier(name, context)
            name in (first(path), last(path)) &&
                invalid(context, "name $name conflicts with an enclosing module binding")
            haskey(PRIMITIVES, name) && invalid(context, "name $name is a primitive type")
            name in names && invalid(context, "duplicate declaration $name")
            push!(names, name)
            child_path = [path; name]
            qualified = join(child_path, ".")

            if section == "enums"

                definition = parse_enum(name, entry, qualified)
                push!(namespace.enums, definition)
                types[qualified] = definition.type

            elseif section == "messages"

                definition = parse_message(name, entry, child_path, types)
                push!(namespace.messages, definition)
                types[qualified] = definition

            else

                # Only file includes change the directory used for further includes.
                # Inline child namespaces inherit the directory of the containing file.
                child = entry isa AbstractString ?
                    parse_file(joinpath(base_dir, entry), child_path, types, stack) :
                    parse_namespace(entry, child_path, base_dir, types, stack)
                push!(namespace.namespaces, child)

            end

        end

    end

    return namespace

end
