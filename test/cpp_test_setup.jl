module CppTestSetup

using Pkg.Artifacts: artifact_hash, artifact_path, ensure_artifact_installed

# The build helper deliberately supports the two toolchains exercised in CI. A missing
# compiler is a setup failure, not a reason to report successful but incomplete tests.
# CXX is one executable name or path; Julia's command interpolation handles spaces safely.
function cpp_compiler()

    Sys.islinux() || Sys.isapple() ||
        error("Compiled C++ tests currently support Linux and macOS.")
    compiler = get(ENV, "CXX", "c++")
    executable = Sys.which(compiler)
    isnothing(executable) && error(
        "C++17 compiler '$compiler' was not found. Install Xcode Command Line Tools " *
        "on macOS or g++/clang++ on Linux, or set CXX to the compiler executable.",
    )
    return executable

end

# Only compiled tests ask Pkg to obtain Eigen. The pinned archive and hashes work identically
# locally and in CI, and the depot cache avoids repeated downloads after the first run.
function eigen_include_dir()

    artifacts = joinpath(@__DIR__, "Artifacts.toml")
    ensure_artifact_installed("eigen", artifacts)
    root = artifact_path(artifact_hash("eigen", artifacts))
    include_dir = joinpath(root, "eigen-5.0.0")
    isfile(joinpath(include_dir, "Eigen", "Core")) ||
        error("The pinned Eigen artifact is missing Eigen/Core: $include_dir")
    return include_dir

end

end # module CppTestSetup
