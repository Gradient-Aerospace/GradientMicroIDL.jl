module GradientMicroIDLYAMLExt

import GradientMicroIDL
import YAML
using OrderedCollections: OrderedDict

# YAML's default mapping reader overwrites duplicate keys after logging an error. A
# strict ordered mapping preserves constructor order and makes duplicates actual failures.
function GradientMicroIDL.read_definitions(::Val{:yaml}, filename)

    constructors = Dict(
        "tag:yaml.org,2002:map" => (constructor, node) -> YAML.construct_mapping(
            OrderedDict{Any, Any},
            constructor,
            node;
            strict_unique_keys = true,
        ),
    )
    return YAML.load_file(filename, constructors)

end

end # module GradientMicroIDLYAMLExt
