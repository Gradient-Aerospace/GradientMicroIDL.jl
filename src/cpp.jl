# C++ uses the same resolved types and storage permutation as the Julia printer. One
# header holds the complete tree, so prior definitions are available without circular
# includes between parent and child namespaces.

# Fixed-width integer names make the storage contract explicit. char is an unsigned byte,
# matching Julia generation, rather than C++'s implementation-dependent plain char.
const CPP_PRIMITIVES = Dict(
    "int8"    => "::std::int8_t",
    "int16"   => "::std::int16_t",
    "int32"   => "::std::int32_t",
    "int64"   => "::std::int64_t",
    "uint8"   => "::std::uint8_t",
    "uint16"  => "::std::uint16_t",
    "uint32"  => "::std::uint32_t",
    "uint64"  => "::std::uint64_t",
    "float32" => "float",
    "float64" => "double",
    "char"    => "::std::uint8_t",
)

# Fully qualified references work from any depth, even if an inner namespace has a name
# that would otherwise hide part of a previously defined type's path.
function cpp_type(type::TypeDefinition)
    type.kind == :primitive && return CPP_PRIMITIVES[type.name]
    suffix = isempty(type.arguments) ? "" : "<" * join(type.arguments, ", ") * ">"
    return "::" * replace(type.name, "." => "::") * suffix
end

# Layout expressions come exclusively from the shared parser. C++ uses integer division
# for rounding up; no user-supplied expression is copied into the generated source.
function cpp_size(value)

    value isa Expr || return string(value)
    operation = value.args[1]
    terms = cpp_size.(value.args[2:end])
    if operation == :round
        value, alignment = terms
        return "((($value + $alignment - 1) / $alignment) * $alignment)"
    end
    return "(" * join(terms, operation == :+ ? " + " : " * ") * ")"

end

# Escape the block-comment terminator in prose so documentation cannot become C++ code.
# Documentation comments keep message and member descriptions beside their declarations.
function print_cpp_description(io, text, indent)

    isempty(text) && return
    println(io, indent, "/**")
    for line in split(replace(text, "*/" => "* /"), '\n')
        println(io, indent, " * ", line)
    end
    println(io, indent, " */")

end

# Decimal literals need suffixes to cover UInt64. The minimum Int64 needs special spelling:
# its positive magnitude is too large for a signed long long literal before unary minus.
function cpp_integer(value, base)
    startswith(base, "uint") && return "$(value)ULL"
    value == typemin(Int64) && return "(-9223372036854775807LL - 1LL)"
    return "$(value)LL"
end

# Eigen views are useful for numeric arrays. Message, enum, and byte-valued character
# arrays retain plain storage access without requiring custom Eigen scalar behavior.
function has_eigen_view(field::FieldDefinition)
    return !isempty(field.dimensions) && field.type.kind == :primitive &&
        field.type.name != "char"
end

# C++ adds method names that do not exist in the input. Check these before rendering so
# a collision cannot leave a header that only reports the problem when compiled later.
# The return value also tells the header writer whether Eigen is needed anywhere.
function validate_cpp(namespace)

    needs_eigen = false
    for message in namespace.messages

        names = Set(field.name for field in message.fields)
        union!(names, message.parameters)
        "Matrix" in message.parameters &&
            invalid(message.type.name, "parameter Matrix conflicts with an Eigen alias")
        name = last(split(message.type.name, '.'))
        for field in message.fields

            has_eigen_view(field) || continue
            accessor = field.name * "_eigen"
            if accessor in names || accessor == name
                invalid(
                    message.type.name,
                    "generated accessor $accessor conflicts with a name",
                )
            end

            # Eigen's fixed dimensions and compile-time element counts use int, even on
            # hosts whose Julia Int is wider. Plain nonnumeric arrays have no such limit.
            count = layout_expression(:*, field.dimensions...)
            count isa Int && count > typemax(Int32) &&
                invalid(message.type.name, "Eigen array dimensions exceed its int range")
            needs_eigen = true

        end

    end
    for child in namespace.namespaces
        needs_eigen = validate_cpp(child) || needs_eigen
    end
    return needs_eigen

end

# Scoped enums keep value names inside their enum, just as EnumX does on the Julia side.
# Explicit base types and literal suffixes preserve signedness and width.
function print_cpp_enum(io, definition, indent)

    name = last(split(definition.type.name, '.'))
    base = CPP_PRIMITIVES[definition.base]
    println(io, indent, "enum class $name : $base {")
    for (key, value) in definition.values
        println(io, indent, "    $key = $(cpp_integer(value, definition.base)),")
    end
    println(io, indent, "};\n")

end

# The value constructor accepts scalar values, references to messages, and references to
# fixed arrays. Array references retain the length in the signature and avoid heap storage.
# Argument names match the fields so the interface remains readable. Member access in
# the body uses this-> to distinguish array destinations from the incoming arguments.
function print_cpp_constructor(io, message, indent)

    name = last(split(message.type.name, '.'))
    fields = message.fields
    println(io, indent, "// Value-initialize fields when no arguments are supplied.")
    if isempty(message.parameters)

        println(io, indent, "$name() = default;\n")

    else

        # A class is complete inside its constructor body. Template layout checks cannot
        # use sizeof/offsetof directly in the still-incomplete class declaration.
        println(io, indent, "$name() {")
        print_cpp_layout(io, message, indent * "    ")
        println(io, indent, "}\n")

    end
    println(io, indent, "// Arguments use input order; initializers use storage order.")
    println(io, indent, "explicit $name(")
    for (index, field) in enumerate(fields)

        type = cpp_type(field.type)
        argument = field.name
        if !isempty(field.dimensions)
            count = cpp_size(layout_expression(:*, field.dimensions...))
            parameter = "const $type (&$argument)[$count]"
        elseif field.type.kind == :message
            parameter = "const $type& $argument"
        else
            parameter = "$type $argument"
        end
        comma = index == length(fields) ? "" : ","
        println(io, indent, "    $parameter$comma")

    end
    println(io, indent, ")")

    # Built-in arrays cannot be copied in a member initializer. Initialize their storage
    # first, then copy elements in the body. Nested messages have a default constructor.
    for (position, index) in enumerate(message.storage_order)

        field = fields[index]
        argument = isempty(field.dimensions) ? field.name : ""
        prefix = position == 1 ? ": " : "  "
        comma = position == length(fields) ? "" : ","
        println(io, indent, "    $prefix$(field.name){$argument}$comma")

    end
    println(io, indent, "{")
    isempty(message.parameters) || print_cpp_layout(io, message, indent * "    ")
    for field in fields

        isempty(field.dimensions) && continue
        count = cpp_size(layout_expression(:*, field.dimensions...))
        println(
            io,
            indent,
            "    ::std::copy_n($(field.name), $count, this->$(field.name));",
        )

    end
    println(io, indent, "}\n")

end

# Maps borrow the array storage and add no data members. Ref-qualified accessors accept
# only lvalues, so a view cannot be obtained directly from a temporary message. The const
# overload maps const scalars instead of a const wrapper around writable data.
function print_cpp_view(io, field, indent)

    type = cpp_type(field.type)
    rows = field.dimensions[1]
    columns = length(field.dimensions) == 1 ? 1 : field.dimensions[2]

    # Eigen requires row vectors to use RowMajor. With just one row, the sequence of
    # elements is identical to column-major storage, so this does not change the interface.
    order = rows == 1 && columns != 1 ? "RowMajor" : "ColMajor"
    matrix = "::Eigen::Matrix<$type, $rows, $columns, ::Eigen::$order>"
    name = field.name * "_eigen"
    println(io, indent, "// The returned view borrows this field's storage.")
    for qualifier in ("", "const ")

        println(io, indent, "auto $name() $qualifier& {")
        println(io, indent, "    using Matrix = $matrix;")
        println(
            io,
            indent,
            "    return ::Eigen::Map<$(qualifier)Matrix, ::Eigen::Unaligned>(",
        )
        println(io, indent, "        this->$(field.name)")
        println(io, indent, "    );")
        println(io, indent, "}\n")

    end
    println(io, indent, "void $name() && = delete;")
    println(io, indent, "void $name() const && = delete;\n")

end

# These assertions are emitted now and evaluated only when a consumer compiles the header.
# They compare the C++ compiler's layout against the native layout planned during Julia
# generation. The compiled tests also compare C++ layout with actual loaded Julia types.
function print_cpp_layout(io, message, indent)

    name = last(split(message.type.name, '.'))
    println(io, indent, "static_assert(::std::is_standard_layout_v<$name>);")
    println(io, indent, "static_assert(::std::is_trivially_copyable_v<$name>);")
    println(io, indent, "static_assert(sizeof($name) == $(cpp_size(message.type.size)));")
    println(io, indent, "static_assert(alignof($name) == $(message.type.alignment));")

    # Decreasing alignment removes inter-field padding. Each field size already includes
    # any tail padding inside a nested message, so offsets are simply cumulative sizes.
    offset = 0
    for index in message.storage_order

        field = message.fields[index]
        assertion = "static_assert(offsetof($name, $(field.name)) == $(cpp_size(offset)));"
        println(io, indent, assertion)
        offset = layout_expression(:+, offset, field.size)

    end
    println(io)

end

# Store all members inline, using the parser's layout order. Methods and constructors do
# not add storage, and default member initializers make default construction deterministic
# for field values (padding bytes remain unspecified).
function print_cpp_message(io, message, indent)

    name = last(split(message.type.name, '.'))
    member_indent = indent * "    "
    print_cpp_description(io, message.description, indent)
    if !isempty(message.parameters)

        parameters = join(["::std::int64_t $name" for name in message.parameters], ", ")
        println(io, indent, "template <$parameters>")

    end
    println(io, indent, "struct $name {\n")
    for parameter in message.parameters

        condition = "$parameter > 0 && $parameter <= $(typemax(Int))"
        println(io, member_indent, "static_assert(")
        println(io, member_indent, "    $condition, \"length must fit a positive Int\"")
        println(io, member_indent, ");")

    end
    for field in message.fields

        has_eigen_view(field) || continue
        count = layout_expression(:*, field.dimensions...)
        count isa Int && continue
        condition = "$(cpp_size(count)) <= $(typemax(Int32))"
        println(io, member_indent, "static_assert(")
        println(io, member_indent, "    $condition, \"Eigen length exceeds int range\"")
        println(io, member_indent, ");")

    end
    println(io, member_indent, "// Decreasing alignment; declaration order breaks ties.")
    for index in message.storage_order

        field = message.fields[index]
        type = cpp_type(field.type)
        count = cpp_size(layout_expression(:*, field.dimensions...))
        shape = isempty(field.dimensions) ? "" : "[$count]"
        print_cpp_description(io, field.description, member_indent)
        println(io, member_indent, "$type $(field.name)$shape{};")

    end
    println(io)
    print_cpp_constructor(io, message, member_indent)
    for field in message.fields
        has_eigen_view(field) && print_cpp_view(io, field, member_indent)
    end
    println(io, indent, "};\n")
    isempty(message.parameters) && print_cpp_layout(io, message, indent)

end

# Preserve the parser's enum/message/child ordering so every named field type has already
# been defined. Ordinary nested namespace blocks also retain empty namespaces.
function print_cpp_namespace(io, namespace, indent)

    println(io, indent, "namespace $(namespace.name) {\n")
    inner = indent * "    "
    for definition in namespace.enums
        print_cpp_enum(io, definition, inner)
    end
    for message in namespace.messages
        print_cpp_message(io, message, inner)
    end
    for child in namespace.namespaces
        print_cpp_namespace(io, child, inner)
    end
    println(io, indent, "} // namespace $(namespace.name)\n")

end

# The complete header is validated and rendered before creating directories or files.
# Eigen is included only when a numeric array accessor requires it; no compiler is invoked.
function write_cpp(namespace, out_dir)

    namespace.name in ("std", "Eigen") &&
        invalid(namespace.name, "root namespace conflicts with a C++ dependency")
    needs_eigen = validate_cpp(namespace)
    io = IOBuffer()
    println(io, "// Generated by GradientMicroIDL. Requires C++17.")
    println(io, "// Layout assertions describe the Julia host used for generation.")
    println(io, "#pragma once\n")
    println(io, "#include <algorithm>")
    println(io, "#include <cstddef>")
    println(io, "#include <cstdint>")
    println(io, "#include <type_traits>")
    needs_eigen && println(io, "#include <Eigen/Core>")
    println(io)
    print_cpp_namespace(io, namespace, "")
    source = String(take!(io))

    # Match the Julia output's root-directory convention, while keeping C++ in one header.
    filename = abspath(out_dir, namespace.name, namespace.name * ".hpp")
    mkpath(dirname(filename))
    write(filename, source)
    return filename

end
