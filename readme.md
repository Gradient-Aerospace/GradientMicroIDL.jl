# GradientMicroIDL

This Julia package generates immutable Julia types and corresponding C++ structs for simple messages. Both generators use the same field ordering and layout calculations, with the goal of sharing messages through `ccall` without translating their contents. Tests compile the generated C++ and check its layout and pointer-based interoperability with the generated Julia types on Linux and macOS.

## Specifications

Valid types for fields of a message:

* Signed and unsigned 8-, 16-, 32-, and 64-bit integers
* 32- and 64-bit floating point numbers
* 8-bit chars
* Enums of any underlying integer type
* Fixed-size vectors and matrices of any valid type
* Prior message types

Matrices are always interpreted as column-major.

Generated types use native Julia layout. The intended shared-memory interface targets little-endian systems; this is not a portable serialization format.

Messages can use already defined messages as types for their fields.

Messages and enums can be placed inside of namespaces.

Namespaces can only reference prior namespaces, so that namespaces form a directed, acyclic graph.

Note that unions and non-fixed-length arrays are not allowed.

Names use ASCII letters and digits with underscores, beginning with a letter. Language keywords and bindings used by generated code (`Base`, `Core`, `StaticArrays`, `EnumX`, `include`, `eval`, and `new`) are reserved. Names containing double underscores are reserved for C++ compatibility. A declaration cannot reuse a primitive type name, the root module name, or its containing module name; a field cannot reuse its message name, and enum values cannot reuse `T` or their enum name.

### Definition

Enums, messages, and namespaces are defined in YAML file with `enums`, `messages`, and `namespaces` fields. This set defines a "namespace".

Each named enum entry should be a dictionary containing `type` (an integer type) and `values` (a dictionary of names and their values).

Each named message entry should be a dictionary of field names and their types.

Each named namespace entry should be either (1) a namespace, with `enums`, `messages`, and `namespaces` fields, or (2) a YAML file name that the namespace can be loaded from.

Here is a simple example with an enum and two messages at the global namespace:

```
enums:
  GNSSFixType:
    type: uint8
    values:
      none: 0
      fix_3d: 3
      float_fix: 5
      int_fix: 6
messages:
  GNSSTimeStamp:
    weeks: uint16
    microseconds: uint64
  GNSSMeasurement:
    timestamp: GNSSTimeStamp
    fix_type: GNSSFixType
    position_ecef: float64[3]
    velocity_ecef: float64[3]
    position_covariance_ecef: float64[3,3]
    velocity_covariance_ecef: float64[3,3]
```

Here is an example with deeper structure:

```
namespaces:
  Common:
    messages:
      LocalTimeStamp:
        microseconds: uint64
  Sensors:
    namespaces:
      Barometer:
        messages:
          BarometerMeasurement:
            timestamp: Common.LocalTimeStamp
            pressure: float32
            temperature: float32
      GNSS: gnss.yaml # A file containing the above structure
  GNC:
    namespaces:
      Navigation:
        messages:
          NavInputs:
            barometer_measurement: Sensors.Barometer.BarometerMeasurement
            gnss_measurement: Sensors.GNSS.GNSSMeasurement
```

In a namespace definition, any unnecessary section can be omitted. An empty namespace is valid; empty messages and enums are not supported. Included filenames are resolved relative to the YAML file containing them, and recursive file includes are rejected.

Vectors and matrices are specified as the type with the size of each dimension, as in `int32[3]` for a 3-element vector of 32-bit integers or `float64[3, 4]` for a 3-by-4 matrix of `float64`.

### Constraints

Messages must form a directed-acyclic graph. That is, message X cannot have any fields whose types contain message X anywhere.

Within each namespace, enums are processed first, then messages, then child namespaces. Declaration order within each section is preserved. References must name previously defined types; the generator does not reorder declarations to satisfy dependencies. A bare type name refers to the current namespace. A dotted name, such as `Sensors.GNSS.GNSSMeasurement`, starts at the root namespace without spelling the root module name.

Message names and enums must be valid Julia and C++ struct names.

#### Enum values loaded from YAML

YAML.jl parses integer values as Julia `Int`, which is `Int64` on 64-bit systems. Consequently, a `uint64` enum defined in YAML can only specify values from zero through `typemax(Int64)` (9,223,372,036,854,775,807). Values in the upper half of the `UInt64` range cause a parsing overflow; they are not converted or truncated. Enum values must also fit their declared underlying integer type.

The dictionary overload bypasses YAML parsing for values supplied directly in the dictionary, so those values can use the full `UInt64` range, including `typemax(UInt64)`. Any YAML files included by that dictionary still have the YAML parsing limitation. This restriction does not affect `uint64` message fields, which support the full `UInt64` range.

### Implementation

Message fields can be declared in any order. Their physical storage order is decreasing alignment, then decreasing size, with declaration order breaking ties. Ordinary native padding is retained. Constructors preserve the order listed in YAML, independently of the physical field order. For example, `GNSSTimeStamp(weeks, microseconds)` stores `microseconds` first but accepts `weeks` first.

### Julia Implementation

Julia types are generated with positional and keyword constructors. All fields are required, and values are converted to the declared field types during construction.

Enums use EnumX with their declared integer width. Primitive names are `int8`, `int16`, `int32`, `int64`, their `uint` counterparts, `float32`, and `float64`. The eight-bit `char` type maps to `UInt8`, representing a byte rather than Julia’s four-byte `Char`.

Vectors and matrices use `StaticArrays.SVector` and `StaticArrays.SMatrix`, including arrays of enums and messages. Dimensions must be positive integers, with one dimension for a vector or two for a matrix. Elements are stored inline, and matrices are column-major.

Declared enums, messages, and child namespaces are exported. Generated modules require EnumX and StaticArrays in the environment where they are loaded; GradientMicroIDL is only needed for generation.

### C++ Implementation

C++ generation produces one self-contained C++17 header, `out_dir/Namespace/Namespace.hpp`, containing the entire namespace tree in definition order. Integers use the fixed-width types from `<cstdint>`, floating-point fields use `float` and `double`, and `char` uses `std::uint8_t`. Enums are scoped (`enum class`) with the declared integer base type.

Fields use ordinary unpacked storage. An array such as `float64[3]` becomes `double field[3]`, and `float64[2,3]` becomes `double field[6]`. Matrices are flattened column-major: element `(row, column)` is at `field[row + rows * column]` with zero-based C++ indices. Arrays of messages, enums, and character bytes use the same built-in array storage.

Each message has a default constructor and an explicit value constructor whose arguments follow YAML field order. Default construction initializes field values to zero, recursively, including enum values whose zero may not have a named enumerator. Padding bytes are unspecified. Value constructors take primitive and enum arguments by value, message arguments by const reference, and array arguments by const reference to a built-in array of the exact length. Array elements are copied into the message's own storage. Constructors do not accept Eigen expressions directly.

Numeric array fields also have `<field>_eigen()` methods returning mutable or const `Eigen::Map` views. These views do not copy data or add fields to the struct. They use unaligned maps so Eigen does not impose SIMD alignment on the shared storage. Vectors map to column vectors; matrices retain their declared rows and columns. Eigen requires a single-row matrix to use its `RowMajor` option, which has the same element order as column-major for that shape. Character, enum, and message arrays have no Eigen accessor.

A view borrows the message's storage and must not outlive it. Accessors reject temporary messages; the const overload returns a view of const elements. The header includes `<Eigen/Core>` only when numeric array fields are present. Their fixed element counts must fit Eigen's compile-time `int` range. An accessor name must not collide with a field or its containing message's name, and the root namespace cannot be `std` or `Eigen`.

#### Layout checks and current limits

The header emits `static_assert` checks for each message's size, alignment, field offsets, standard layout, and trivial copyability. The expected sizes and offsets come from the Julia host used for generation. These assertions will run when a consumer compiles the header; a target with a different native layout may reject it. The intended interface assumes little-endian storage and matching floating-point representations. There is no byte swapping or serialization.

Tests check both emitted source and compiled behavior. A small shared library reports C++ sizes, alignments, and field offsets for comparison with the actual loaded Julia types. Additional tests exercise constructors, fixed-array copies, Eigen views, and read/write calls through Julia `Ref` arguments. These checks cover the tested host and compiler combinations; by-value calls and other target ABIs remain outside the tested contract.

## Generating Code

When generating the code, the required arguments are (1) the top-level file, (2) the directory in which files should be generated, and (3) the namespace/module name to use for the top level.

```julia
using GradientMicroIDL

root_file = generate_julia("my_messages.yaml", "my_julia_definitions", "MyMessages")
cpp_header = generate_cpp("my_messages.yaml", "my_cpp_definitions", "MyMessages")
include(root_file)
```

Julia generation produces one root module containing the other namespaces, with one file per module. C++ generation puts all namespaces in one header. Each generator returns the absolute path to its root file. Definitions are validated before writing output; generated paths are overwritten, while unrelated files are left alone.

Both dictionary overloads accept the same namespace structure: `generate_julia(definitions, out_dir, module_name; base_dir = pwd())` and `generate_cpp(definitions, out_dir, namespace_name; base_dir = pwd())`. Dictionary iteration order determines declaration order, so `OrderedCollections.OrderedDict` is useful when constructing definitions directly. The `base_dir` keyword supplies the directory for file includes in that dictionary.

The complete example generates both languages and loads the Julia module. It can be run from the package directory with `julia --project=. examples/my_messages.jl`; it does not compile C++. Its paths are anchored to the script directory, so it also works from another working directory when the package environment is selected.

### Example Julia

The generated timestamp illustrates the distinction between physical layout and constructor order:

```julia
struct GNSSTimeStamp

    microseconds::Base.UInt64
    weeks::Base.UInt16

    function GNSSTimeStamp(weeks, microseconds)
        return new(microseconds, weeks)
    end

end

function GNSSTimeStamp(; weeks, microseconds)
    return GNSSTimeStamp(weeks, microseconds)
end
```

The enum declaration preserves its one-byte representation:

```julia
EnumX.@enumx GNSSFixType::Base.UInt8 begin
    none = 0
    fix_3d = 3
    float_fix = 5
    int_fix = 6
end
```

After running the example, both constructor forms create the same value:

```julia
using .MyMessages.Sensors.GNSS

a = GNSSTimeStamp(2, 30)
b = GNSSTimeStamp(; weeks = 2, microseconds = 30)
@assert a === b
@assert isbitstype(GNSSMeasurement)
@assert sizeof(GNSSFixType.T) == 1
```

The full generated module tree is in `build/julia/MyMessages/`.

### Example C++

After running the example, the header is in `build/cpp/MyMessages/MyMessages.hpp`. A consumer can include it and construct messages in the same field order as the YAML:

```cpp
#include "MyMessages/MyMessages.hpp"

using namespace MyMessages::Sensors::GNSS;

GNSSTimeStamp timestamp{2, 30}; // weeks, microseconds
const double position[3] = {1.0, 2.0, 3.0};
const double velocity[3] = {0.0, 0.0, 0.0};
const double covariance[9] = {
    1.0, 0.0, 0.0, // First column.
    0.0, 1.0, 0.0, // Second column.
    0.0, 0.0, 1.0, // Third column.
};

GNSSMeasurement measurement{
    timestamp,
    GNSSFixType::fix_3d,
    position,
    velocity,
    covariance,
    covariance,
};

// The view updates the array already stored in measurement.
auto position_view = measurement.position_ecef_eigen();
position_view(0) = 10.0;

// Const messages expose read-only element access through their views.
const auto& reading = measurement;
auto covariance_view = reading.position_covariance_ecef_eigen();
double variance = covariance_view(0, 0);
```

The scalar timestamp struct is emitted with `microseconds` before `weeks` in storage, while its value constructor still accepts `weeks` first. The generated header also contains the static layout checks and the const/mutable Eigen accessor definitions.

## Running the tests

The full test suite uses Julia 1.12 or later and a native C++17 compiler. The compiled test harness currently supports Linux and macOS; CI runs GCC on Linux and Apple Clang on macOS. The compiler and Julia must target the same architecture.

On macOS, a compiler is provided by Xcode Command Line Tools (`xcode-select --install`). On Debian/Ubuntu, `sudo apt-get install g++` provides the compiler and development files. Other Linux distributions can supply GCC or Clang through their package manager. No CMake or C++ test framework is needed.

From the package directory:

```sh
julia --project=test -e 'using Pkg; Pkg.instantiate()'
julia --project=test test/runtests.jl
```

If an existing local manifest predates changes to the test dependencies, `julia --project=test -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'` refreshes it. Fresh checkouts do not need this extra step.

The harness uses `c++` by default. `CXX` can specify another executable name or an absolute path, without additional flags:

```sh
CXX=clang++ julia --project=test test/runtests.jl
```

A missing compiler fails the test run with setup instructions; compiled tests are not silently skipped. Compiler errors from the shared-library build are shown normally. Three additional syntax-only compiles are expected to fail: writing through a const view, obtaining a view from a temporary message, and obtaining a view from a const temporary message. A successful control compile runs first so missing headers cannot masquerade as the expected failures.

### Eigen for testing

The test harness obtains Eigen 5.0.0 through `test/Artifacts.toml`, which pins the official release archive by its download checksum and unpacked tree hash. Julia downloads and verifies it on the first compiled test run, then reuses the copy in its artifact cache. Local tests and CI use the same declaration. No Eigen compilation or system installation is needed: the test compiler is simply given the artifact's include directory.

The first run needs network access to obtain the artifact; subsequent runs can use the cached files offline. Code generation itself does not request the artifact or require a compiler. A manually unpacked Eigen directory under `test/` is not used. Updating Eigen means updating the versioned URL and both hashes in `test/Artifacts.toml`, together with the release-directory name in `eigen_include_dir` in `test/cpp_interop.jl`.

### What the compiled tests do

The harness generates both languages in a temporary directory, builds one shared library, and calls it from Julia. Layout probes use the C++ compiler's `sizeof`, `alignof`, and `offsetof`; their expected values come from Julia's loaded types rather than the generator's layout records. The real example is supplemented with all scalar widths, both 64-bit enum extremes, rectangular matrices, row/column shapes, and arrays of padded messages.

The library reads Julia-constructed values, fills fresh Julia-owned storage with C++-constructed values, and modifies fields through Eigen views and ordinary C++ member access. Tests compare field values rather than padding bytes. C++ checks return a failing source line number instead of aborting the Julia process. The shared library is unloaded before the temporary directory is removed.

The CI workflow in `.github/workflows/test.yml` instantiates the same test workspace and runs the same command. Its Julia depot cache also retains downloaded artifacts between runs.

## Outstanding Questions

Are *all* types that the embedded software uses expected to come from this system? We only truly care about defining the interface between the embedded software and the simulation, but will the practical implementation of these types end up requiring that _everything_ is defined this way? For instance, if this system were used to describe a set of parameters for the embedded system, that implies that every parameter must be one of these types. That may prove restrictive when parameters might be better typed as C++-specific types (pointers, look-up-tables, etc.). We might allow the parameters to be defined using this IDL, but then have a "constants" structure inside the C++ that never touches the interface, and the parameters could be used to specify the structure.

Should we generate a top-level Project.toml file to provide compat bounds on StaticArrays and EnumX? We don't expect this to literally be a registered package, so the top-level module will simply be included, so that Project.toml wouldn't get used anyway. But one _could_ make the built system a package. In that case, it's up to the user to set that up how they like. So the answer here is _no_.
