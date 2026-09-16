# An example of generating Julia and C++ messages, then loading the Julia module.
#
# From this repo's root, run:
#
#   julia --project=. examples/messages.jl
#

import GradientMicroIDL

# Generate the Julia module beside the package's other build outputs.
root_file = GradientMicroIDL.generate_julia(
    joinpath(@__DIR__, "messages.yaml"),
    joinpath(@__DIR__, "..", "build", "messages", "julia"),
    "MyMessages",
)

# Emit the corresponding header. Generation does not build or load any C++ code.
cpp_file = GradientMicroIDL.generate_cpp(
    joinpath(@__DIR__, "messages.yaml"),
    joinpath(@__DIR__, "..", "build", "messages", "cpp"),
    "MyMessages",
)

# Load the generated module.
include(root_file)
