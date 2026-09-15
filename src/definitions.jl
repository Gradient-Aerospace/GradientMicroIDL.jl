# The parser records what was declared and resolves references before source is printed.
# This keeps YAML traversal and memory-layout decisions out of the language-specific
# printer. Only completed enum and message definitions enter the shared type table.

# Every field type needs a name, size, and alignment. Primitive names use IDL spelling;
# enum and message names include the root namespace so references are unambiguous.
struct TypeDefinition
    name::String
    kind::Symbol
    size::Int
    alignment::Int
end

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
    dimensions::Vector{Int}
    size::Int
end

# Fields stay in declaration order for constructors. A separate permutation describes
# physical storage, allowing nested messages to use the calculated size and alignment.
struct MessageDefinition
    type::TypeDefinition
    fields::Vector{FieldDefinition}
    storage_order::Vector{Int}
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
# rather than escaping arbitrary input differently for Julia and a future C++ generator.
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

# A field string combines a type reference with optional dimensions. Splitting these here
# gives the printer an already-resolved element type and a checked total storage size.
function parse_field(name, specification, path, types)

    # Accept only the IDL grammar: a dotted name followed by optional brackets. Type
    # strings are never evaluated as Julia expressions.
    context = join([path; name], ".")
    specification isa AbstractString || invalid(context, "expected a type string")
    parsed = match(
        r"^([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)*)(?:\[([^\]]*)\])?$",
        strip(specification),
    )
    isnothing(parsed) && invalid(context, "invalid type $(repr(specification))")
    reference, dimensions_text = parsed.captures

    # Bare references are local; dotted references start at the root namespace. path
    # includes the message name, which is removed when constructing a local type name.
    if haskey(PRIMITIVES, reference)
        type = primitive_type(reference)
    else
        qualified = occursin('.', reference) ? path[1] * "." * reference :
            join([path[1:end-1]; reference], ".")
        haskey(types, qualified) ||
            invalid(context, "type $reference is not previously defined")
        type = types[qualified]
    end

    # No brackets means a scalar field. Otherwise, retain one or two positive dimensions
    # so the printer can distinguish vectors from matrices without reparsing the string.
    dimensions = Int[]
    if !isnothing(dimensions_text)

        parts = split(dimensions_text, ',')
        length(parts) in (1, 2) ||
            invalid(context, "only vectors and matrices are supported")
        for part in parts

            occursin(r"^[0-9]+$", strip(part)) ||
                invalid(context, "invalid array dimension")
            push!(dimensions, checked_size(parse(BigInt, strip(part)), context))

        end

    end

    # Multiplying by the complete element size includes padding within nested messages.
    size = checked_size(prod(BigInt.(dimensions); init = BigInt(type.size)), context)
    return FieldDefinition(name, type, dimensions, size)

end

# Resolve fields in declaration order, then calculate a separate physical layout. The
# resulting message type can be registered for use in subsequent messages and arrays.
function parse_message(name, definitions, path, types)

    # Constructor arguments keep this order even when their corresponding fields move.
    context = join(path, ".")
    definitions = mapping(definitions, context)
    isempty(definitions) && invalid(context, "empty messages are not supported")
    fields = FieldDefinition[]
    for (key, specification) in definitions

        key = identifier(key, context)
        key == name && invalid(context, "field name $key conflicts with its constructor")
        push!(fields, parse_field(key, specification, path, types))

    end

    # Larger alignment requirements come first; size breaks alignment ties. The original
    # index then keeps equally sized and aligned fields in a predictable order.
    order = sortperm(
        eachindex(fields);
        by = index -> (-fields[index].type.alignment, -fields[index].size, index),
    )

    # Round up to each field's alignment before placing it. The final rounding includes
    # trailing padding, which matters when this message becomes an array element.
    alignment = maximum(field.type.alignment for field in fields)
    size = BigInt(0)
    for index in order
        field = fields[index]
        size = cld(size, field.type.alignment) * field.type.alignment + field.size
    end
    size = checked_size(cld(size, alignment) * alignment, context)
    type = TypeDefinition(context, :message, size, alignment)
    return MessageDefinition(type, fields, order)

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
                types[qualified] = definition.type

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
