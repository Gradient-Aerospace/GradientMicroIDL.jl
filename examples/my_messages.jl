# An example of building and loading Julia messages.
#
# From this repo's root, run:
#
#   julia --project=. examples/my_messages.jl
#

import GradientMicroIDL

# Generate the Julia module beside the package's other build outputs.
root_file = GradientMicroIDL.generate_julia(
    joinpath(@__DIR__, "my_messages.yaml"),
    joinpath(@__DIR__, "..", "build", "julia"),
    "MyMessages",
)

# Load the generated module.
include(root_file)
