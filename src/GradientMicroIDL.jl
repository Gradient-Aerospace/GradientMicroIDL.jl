module GradientMicroIDL

export generate_julia, generate_cpp

import YAML
using OrderedCollections: OrderedDict

# Parsing produces a namespace tree with resolved types and layouts. Source printing
# consumes that tree without needing to interpret YAML or resolve dependencies again.
include("definitions.jl")
include("julia.jl")
include("cpp.jl")

"""
    generate_julia(input_file, out_dir, module_name)

Generates Julia message definitions from a YAML file and returns the absolute path to the
root module file, `out_dir/module_name/module_name.jl`. Included YAML files are resolved
relative to the file containing the include. Generated code requires EnumX and StaticArrays.

Definitions must refer only to previously defined types. Invalid definitions raise an
`ArgumentError` before any output files are written.
"""
function generate_julia(
    input_file::AbstractString,
    out_dir::AbstractString,
    module_name::AbstractString,
)

    # The type table and include stack belong to this generation only. parse_file keeps
    # the root file on the stack while resolving children, so includes back to it fail.
    name = identifier(module_name, "root module")
    namespace = parse_file(input_file, [name], Dict{String, TypeDefinition}(), String[])

    # No files are written until the complete namespace tree has been validated.
    return write_julia(namespace, out_dir)

end

"""
    generate_julia(definitions::AbstractDict, out_dir, module_name; base_dir = pwd())

Generates Julia message definitions from a namespace dictionary and returns the absolute
path to the root module file. `base_dir` is the directory for included YAML files.

Dictionary iteration order determines declaration and positional constructor order.
An `OrderedDict` can be used to specify that order explicitly. Fields are stored in
decreasing alignment and size order, while both positional and keyword constructors use
the declared field names and order.
"""
function generate_julia(
    definitions::AbstractDict,
    out_dir::AbstractString,
    module_name::AbstractString;
    base_dir::AbstractString = pwd(),
)

    # Dictionary inputs enter the same parser as files. They supply an initial include
    # directory because there is no containing YAML filename from which to derive it.
    name = identifier(module_name, "root module")
    namespace = parse_namespace(
        definitions,
        [name],
        abspath(base_dir),
        Dict{String, TypeDefinition}(),
        String[],
    )

    # Keep source generation independent of how the definitions were supplied.
    return write_julia(namespace, out_dir)

end

"""
    generate_cpp(input_file, out_dir, namespace_name)

Generates a C++17 header from a YAML file and returns its absolute path,
`out_dir/namespace_name/namespace_name.hpp`. Included YAML files are resolved relative to
the file containing the include. The header contains all nested namespaces and requires
Eigen headers when numeric array fields are present.

Fields use the same storage order as Julia generation. Arrays use built-in fixed storage,
with Eigen views for numeric arrays. Constructors accept arguments in declaration order.
Invalid definitions raise an `ArgumentError` before the header is written.
"""
function generate_cpp(
    input_file::AbstractString,
    out_dir::AbstractString,
    namespace_name::AbstractString,
)

    # Both printers consume the same resolved definitions, including physical field order.
    name = identifier(namespace_name, "root namespace")
    namespace = parse_file(input_file, [name], Dict{String, TypeDefinition}(), String[])
    return write_cpp(namespace, out_dir)

end

"""
    generate_cpp(definitions::AbstractDict, out_dir, namespace_name; base_dir = pwd())

Generates a C++17 header from a namespace dictionary and returns its absolute path.
`base_dir` is the directory for included YAML files. Dictionary iteration order determines
declaration and positional constructor order; an `OrderedDict` can specify that order.

Integer enum values supplied directly in the dictionary may use the full range of their
declared type, including `UInt64`. Values loaded from YAML remain limited by YAML parsing.
"""
function generate_cpp(
    definitions::AbstractDict,
    out_dir::AbstractString,
    namespace_name::AbstractString;
    base_dir::AbstractString = pwd(),
)

    # Dictionary inputs bypass YAML loading but share all type and layout validation.
    name = identifier(namespace_name, "root namespace")
    namespace = parse_namespace(
        definitions,
        [name],
        abspath(base_dir),
        Dict{String, TypeDefinition}(),
        String[],
    )
    return write_cpp(namespace, out_dir)

end

end # module GradientMicroIDL
