module GradientMicroIDL

export generate_julia

import YAML
using OrderedCollections: OrderedDict

# Parsing produces a namespace tree with resolved types and layouts. Source printing
# consumes that tree without needing to interpret YAML or resolve dependencies again.
include("definitions.jl")
include("julia.jl")

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

end # module GradientMicroIDL
