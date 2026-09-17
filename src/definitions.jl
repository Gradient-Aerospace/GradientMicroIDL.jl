# Resolution validates specification objects and calculates layouts before source is printed.
# This keeps declaration validation and memory-layout decisions out of the language-specific
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
# ccall and cglobal pass isidentifier but Julia lowering rejects them as argument names.
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
    quote where abstract type in isa ccall cglobal
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

# Dimensions and layout calculations use BigInt until checked here. This prevents integer
# overflow from turning a large requested array into an apparently valid smaller layout.
function checked_size(value, context)
    0 < value <= typemax(Int) || invalid(context, "size must fit a positive Int")
    return Int(value)
end

# Keep the dependency on Julia's native alignment query in one place. The rest of the
# resolver handles primitives, enums, and messages through the same layout record.
function primitive_type(name)
    type = PRIMITIVES[name]
    return TypeDefinition(name, :primitive, sizeof(type), Base.datatype_alignment(type))
end

# Resolve an enum to its integer representation without creating a Julia module. This
# makes its layout available to later messages and catches bad values before file writing.
function resolve_enum(specification::EnumSpec, context)

    # The base type must be an explicit integer type; floats and byte-valued char are not
    # enum base types in the IDL. Each enum must also supply at least one named value.
    name = specification.name
    name == "T" && invalid(context, "enum name T is reserved for EnumX's internal type")
    base = specification.type
    valid = base != "char" && haskey(PRIMITIVES, base)
    valid && PRIMITIVES[base] <: Integer ||
        invalid(context, "expected an integer enum type")
    entries = specification.values
    isempty(entries) && invalid(context, "empty enums are not supported")

    # Check values before converting them so signedness or width cannot silently change
    # their meaning. EnumX reserves T, and the enum module also owns its own name.
    values = Pair{String, BigInt}[]
    names = Set{String}()
    for (key, value) in entries

        key = unique_name!(names, key, context)
        key in ("T", name) && invalid(context, "enum value name $key is reserved")
        valid = !(value isa Bool)
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

# Native specifications retain parameter declarations, including unsupported types, so
# every entry path gets the same semantic checks during resolution.
function resolve_parameters(specification::MessageSpec, path)

    context = join(path, ".")
    parameters = String[]
    names = Set{String}()
    for parameter in specification.parameters

        name = unique_name!(names, parameter.name, context)
        (name in path || haskey(PRIMITIVES, name)) &&
            invalid(context, "parameter name $name conflicts with a type or namespace")
        parameter.type == "int64" || invalid(context, "length parameters must declare int64")
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

# Field specifications retain a type expression and optional documentation.
# Resolve the element separately from its surrounding array shape, retaining arguments
# so both printers can reproduce concrete and parameter-forwarding message references.
function resolve_field(field::FieldSpec, path, types, parameters)

    name = field.name
    context = join([path; name], ".")
    specification = field.type
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
    return FieldDefinition(name, type, dimensions, size, field.description)

end

# Resolve fields in declaration order and sort only by alignment. Positive length parameters do
# not change alignment, so Julia and C++ can share one field order for all instantiations.
function resolve_message(specification::MessageSpec, path, types)

    name = specification.name
    context = join(path, ".")
    parameters = resolve_parameters(specification, path)
    isempty(specification.fields) && invalid(context, "empty messages are not supported")
    fields = FieldDefinition[]
    names = Set{String}()
    for field in specification.fields

        key = unique_name!(names, field.name, context)
        key == name && invalid(context, "field name $key conflicts with its constructor")
        key in parameters && invalid(context, "field name $key conflicts with a parameter")
        push!(fields, resolve_field(field, path, types, parameters))

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
    return MessageDefinition(type, fields, order, parameters, specification.description)

end

# Native vectors can contain duplicates even though dictionaries cannot. Validate them
# at the shared resolution boundary so direct construction gets the same safeguards.
function unique_name!(names, value, context)

    name = identifier(value, context)
    name in names && invalid(context, "duplicate declaration $name")
    push!(names, name)
    return name

end

# Resolve one expanded namespace in declaration order. Only completed definitions enter
# the shared type table, enforcing prior references without a dependency-sorting framework.
function resolve_namespace(specification::NamespaceSpec, path, types)

    context = join(path, ".")
    namespace = NamespaceDefinition(
        last(path),
        EnumDefinition[],
        MessageDefinition[],
        NamespaceDefinition[],
    )
    names = Set{String}()
    try

        # All declarations share the namespace's binding table. Each group retains its
        # own order, with enums before messages and child namespaces last.
        groups = (
            [item.name => item for item in specification.enums],
            [item.name => item for item in specification.messages],
            specification.namespaces,
        )
        for entries in groups, (key, entry) in entries

            name = unique_name!(names, key, context)
            name in (first(path), last(path)) &&
                invalid(context, "name $name conflicts with an enclosing module binding")
            haskey(PRIMITIVES, name) && invalid(context, "name $name is a primitive type")
            child_path = [path; name]
            qualified = join(child_path, ".")
            if entry isa EnumSpec

                definition = resolve_enum(entry, qualified)
                push!(namespace.enums, definition)
                types[qualified] = definition.type

            elseif entry isa MessageSpec

                definition = resolve_message(entry, child_path, types)
                push!(namespace.messages, definition)
                types[qualified] = definition

            else

                child = resolve_namespace(entry, child_path, types)
                push!(namespace.namespaces, child)

            end

        end
        return namespace

    catch error

        error isa InterruptException && rethrow()
        isnothing(specification.source) && rethrow()
        invalid(specification.source, sprint(showerror, error))

    end

end

# Both emitters enter through this boundary. Loading/conversion produces declarations;
# this pass validates every declaration and computes private layout records afresh.
function resolve(specification::NamespaceSpec, name, base_dir)

    name = identifier(name, "root namespace")
    expanded = expand_includes(specification, abspath(base_dir), String[])
    types = Dict{String, Union{TypeDefinition, MessageDefinition}}()
    return resolve_namespace(expanded, [name], types)

end
