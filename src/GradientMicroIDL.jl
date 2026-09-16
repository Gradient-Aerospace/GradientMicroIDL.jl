module GradientMicroIDL

export FieldSpec, ParameterSpec, EnumSpec, MessageSpec, NamespaceSpec, IncludeSpec
export load_specification, generate_julia, generate_cpp

# Specification objects are the public model. Dictionaries and optional file readers
# feed that model; resolution and layout records remain private to code generation.
include("specifications.jl")
include("loading.jl")
include("definitions.jl")
include("julia.jl")
include("cpp.jl")

"""
    generate_julia(specification::NamespaceSpec, out_dir, module_name; base_dir = pwd())
    generate_julia(definitions::AbstractDict, out_dir, module_name; base_dir = pwd())
    generate_julia(input_file::AbstractString, out_dir, module_name)

Generates Julia messages and returns the absolute root module path,
`out_dir/module_name/module_name.jl`. Message descriptions become docstrings. Constructors
use declaration order, while storage uses decreasing alignment with declaration-order ties.
Generated code requires EnumX and StaticArrays.

Dictionary input is converted to a `NamespaceSpec`. File input uses `load_specification`;
load YAML or JSON to enable its reader. `base_dir` resolves includes in directly supplied
specifications or dictionaries. File includes are relative to their containing file.

All inputs share semantic validation. Invalid definitions raise `ArgumentError` before
output files are written. Length parameters require explicit constructor arguments.
"""
function generate_julia(
    specification::NamespaceSpec,
    out_dir::AbstractString,
    module_name::AbstractString;
    base_dir::AbstractString = pwd(),
)
    return write_julia(resolve(specification, module_name, base_dir), out_dir)
end

function generate_julia(
    definitions::AbstractDict,
    out_dir::AbstractString,
    module_name::AbstractString;
    base_dir::AbstractString = pwd(),
)
    return generate_julia(NamespaceSpec(definitions), out_dir, module_name; base_dir)
end

function generate_julia(
    input_file::AbstractString,
    out_dir::AbstractString,
    module_name::AbstractString,
)
    return generate_julia(load_specification(input_file), out_dir, module_name)
end

"""
    generate_cpp(specification::NamespaceSpec, out_dir, namespace_name; base_dir = pwd())
    generate_cpp(definitions::AbstractDict, out_dir, namespace_name; base_dir = pwd())
    generate_cpp(input_file::AbstractString, out_dir, namespace_name)

Generates a C++17 header and returns its absolute path,
`out_dir/namespace_name/namespace_name.hpp`. Fields use the same layout as Julia generation.
Arrays have built-in storage and numeric arrays expose Eigen views. Descriptions become
comments; length parameters become templates. Eigen headers are needed for numeric arrays.

Specifications, dictionaries, and files follow the same conversion and validation path as
`generate_julia`. File input needs the corresponding YAML or JSON reader package loaded.
Invalid definitions raise `ArgumentError` before output is written.
"""
function generate_cpp(
    specification::NamespaceSpec,
    out_dir::AbstractString,
    namespace_name::AbstractString;
    base_dir::AbstractString = pwd(),
)
    return write_cpp(resolve(specification, namespace_name, base_dir), out_dir)
end

function generate_cpp(
    definitions::AbstractDict,
    out_dir::AbstractString,
    namespace_name::AbstractString;
    base_dir::AbstractString = pwd(),
)
    return generate_cpp(NamespaceSpec(definitions), out_dir, namespace_name; base_dir)
end

function generate_cpp(
    input_file::AbstractString,
    out_dir::AbstractString,
    namespace_name::AbstractString,
)
    return generate_cpp(load_specification(input_file), out_dir, namespace_name)
end

end # module GradientMicroIDL
