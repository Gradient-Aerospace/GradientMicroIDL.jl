module GradientMicroIDL

import YAML

"""
Given a file name, this will load the file as YAML and call the corresponding dict-oriented
`generate_julia` method.
"""
function generate_julia(
    input_file::AbstractString,
    out_dir::AbstractString,
    module_name::AbstractString,
)
    definitions = YAML.load_file(input_file)
    return generate_julia(definitions, out_dir, module_name)
end

"""
Given a dictionary of namespace, enum, and message definitions, this will produce the
appropriate Julia code.
"""
function generate_julia(
    definitions::AbstractDict,
    out_dir::AbstractString,
    module_name::AbstractString,
)

    # TODO

end

end # module GradientMicroIDL
