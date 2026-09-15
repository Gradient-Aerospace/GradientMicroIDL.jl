# GradientMicroIDL

This Julia package generates immutable Julia types for simple messages. The long-term goal is to generate corresponding C++ structs with identical memory layouts so messages can be shared through `ccall`. This first implementation generates Julia code only; C++ generation and cross-language layout verification will follow separately.

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

C++ generation is planned but not implemented. The intended layout uses ordinary unpacked storage, with Eigen views for numeric arrays. The future implementation must verify matching sizes, alignments, and field offsets against Julia on supported targets.

## Generating Code

When generating the code, the required arguments are (1) the top-level file, (2) the directory in which files should be generated, and (3) the namespace/module name to use for the top level.

```julia
using GradientMicroIDL

root_file = generate_julia("my_messages.yaml", "my_julia_definitions", "MyMessages")
include(root_file)
```

Generation produces one root module containing the other namespaces, with one file per module. The return value is the absolute path to the root file. Definitions are validated before writing output; generated paths are overwritten, while unrelated files are left alone.

The dictionary overload accepts the same namespace structure: `generate_julia(definitions, out_dir, module_name; base_dir = pwd())`. Dictionary iteration order determines declaration order, so `OrderedCollections.OrderedDict` is useful when constructing definitions directly. The `base_dir` keyword supplies the directory for file includes in that dictionary.

The complete example can be run from the package directory with `julia --project=. examples/my_messages.jl`. Its paths are anchored to the script directory, so it also works from another working directory when the package environment is selected.

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

TODO

## Outstanding Questions

Are *all* types that the embedded software uses expected to come from this system? We only truly care about defining the interface between the embedded software and the simulation, but will the practical implementation of these types end up requiring that _everything_ is defined this way? For instance, if this system were used to describe a set of parameters for the embedded system, that implies that every parameter must be one of these types. That may prove restrictive when parameters might be better typed as C++-specific types (pointers, look-up-tables, etc.). We might allow the parameters to be defined using this IDL, but then have a "constants" structure inside the C++ that never touches the interface, and the parameters could be used to specify the structure.

Should we generate a top-level Project.toml file to provide compat bounds on StaticArrays and EnumX? We don't expect this to literally be a registered package, so the top-level module will simply be included, so that Project.toml wouldn't get used anyway. But one _could_ make the built system a package. In that case, it's up to the user to set that up how they like. So the answer here is _no_.
