module GradientMicroIDLJSONExt

import GradientMicroIDL
import JSON
using OrderedCollections: OrderedDict

# The JSON reader fills this dictionary through setindex!, letting us reject duplicate
# members instead of silently losing a declaration. It is local to this input adapter.
struct StrictObject <: AbstractDict{String, Any}
    entries::OrderedDict{String, Any}
end

StrictObject() = StrictObject(OrderedDict{String, Any}())
Base.length(object::StrictObject) = length(object.entries)
Base.iterate(object::StrictObject, state...) = iterate(object.entries, state...)
Base.getindex(object::StrictObject, key) = object.entries[key]
Base.haskey(object::StrictObject, key) = haskey(object.entries, key)
Base.get(object::StrictObject, key, default) = get(object.entries, key, default)

function Base.setindex!(object::StrictObject, value, key)

    haskey(object, key) && throw(ArgumentError("duplicate JSON key $(repr(key))"))
    object.entries[key] = value
    return object

end

# JSON 1 preserves large integer literals as BigInt. Semantic enum range checks remain
# in the shared resolver, so the adapter does not impose YAML's signed-Int limitation.
function GradientMicroIDL.read_definitions(::Val{:json}, filename)
    return JSON.parsefile(filename; dicttype = StrictObject)
end

end # module GradientMicroIDLJSONExt
