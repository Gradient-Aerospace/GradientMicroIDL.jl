# An example of building Julia and C++ messages.
#
# From this repo's root, run:
#
#   julia --project=. examples/my_messages.jl
#

import GradientMicroIDL

# Generate both sets of messages.
GradientMicroIDL.generate_julia("my_messages.yaml", "build/julia/", "MyMessages")
GradientMicroIDL.generate_cpp("my_messages.yaml", "build/cpp/", "MyMessages")

# Load the Julia.
include(joinpath(@__FILE__, "../build/julia/MyMessages/MyMessages.jl"))
