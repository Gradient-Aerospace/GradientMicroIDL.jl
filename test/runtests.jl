# Each included module tests one area of functionality without sharing generated types.
include("julia_generation.jl")
include("cpp_generation.jl")
include("cpp_interop.jl")
include("cpp_call_example.jl")
include("parameters.jl")
