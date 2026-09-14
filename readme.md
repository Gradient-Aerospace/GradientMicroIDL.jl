# GradientMicroIDL

This Julia package generates Julia and C++ struct definitions for simple messages so that they will have the same memory layout and can be passed back and forth from Julia via a `ccall`.

## Specifications

Valid types for fields of a message:

* Signed and unsigned 8-, 16-, 32-, and 64-bit integers
* 32- and 64-bit floating point numbers
* 8-bit chars
* Enums of any underlying integer type
* Fixed-size vectors and matrices of any valid type
* Prior message types

Matrices are always interpreted as column-major.

The memory layout is always little-endian.

Messages can use already defined messages as types for their fields.

Messages and enums can be placed inside of namespaces.

Namespaces can only reference prior namespaces, so that namespaces form a directed, acyclic graph.

Note that unions and non-fixed-length arrays are not allowed.

All characters used for field/enum/namespace names must be 8-bit chars.

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
            barometer_measurement::Sensors.BarometerMeasurement
            gnss_measurement::Sensors.GNSS.GNSSMeasurement
```

In a namespace definition, any unnecessary field can be omitted.

Vectors and matrices are specified as the type with the size of each dimension, as in `int32[3]` for a 3-element vector of 32-bit integers or `float64[3, 4]` for a 3-by-4 matrix of `float64`.

### Constraints

Messages must form a directed-acyclic graph. That is, message X cannot have any fields whose types contain message X anywhere.

Module Y cannot reference an as-yet undefined Module Z. Modules must be ordered with the fewest dependencies first.

Message names and enums must be valid Julia and C++ struct names.

### Implementation

All messages can have fields in any order. In their implementations, they are rearranged in order of decreasing memory footprint with padding at the end. This is required for Eigen, makes translation between languages instant, and otherwise minimizes padding. Note that constructors are generated to preserve the order listed in the YAML file, not the order that the fields appear in the struct definition.

### Julia Implementation

Julia types are generated with keyword constructors.

Enums use EnumX.

Vectors and matrices will use StaticArrays. Note: Modern versions on StaticArrays no longer "choke" on large sizes due to their tuple-backed behavior. Even 100-by-100 matrix multiplication with SMatrix is reasonable.

All symbols in a module are exported.

### C++ Implementation

C++ types are generated without struct-packing.

Vectors and matrices are rendered as Eigen on the C++ side.

## Generating Code

When generating the code, the required arguments are (1) the top-level file, (2) the directory in which files should be generated, and (3) the namespace/module name to use for the top level.

```julia
generate_julia("my_messages.yaml", "my_julia_definitions", "MyMessages")
generate_cpp("my_messages.yaml", "my_cpp_definitions", "MyMessages")
```

Note that generation always uses one top-level file, generating one namespace/module that contains all of the others.

### Example Julia

The above example generates Julia code that approximately looks like the following (assuming "MyMessages" is the top-level module name given to `generate_julia`):

```julia
# MyMessages.jl
module MyMessages
export Common, Sensors, GNC
import StaticArrays, EnumX
include("Common/Common.jl")
include("Sensors/Sensors.jl")
include("GNC/GNC.jl")
end

# Common/Common.jl
module Common
export LocalTimeStamp
import StaticArrays, EnumX
import ..MyMessages
@kwdef struct LocalTimeStamp
    microseconds::UInt64
end
end

# Sensors/Sensors.jl
module Sensors
export Barometer, GNSS
import StaticArrays, EnumX
import ..MyMessages
include("Barometer/Barometer.jl")
include("GNSS/GNSS.jl")
end

# Sensors/Barometer/Barometer.jl
module Barometer
export BarometerMeasurement
import StaticArrays, EnumX
import ..MyMessages
@kwdef struct BarometerMeasurement
    timestamp::MyMessages.Common.LocalTimeStamp
    pressure::Float32
    temperature::Float32
end
end

# Sensors/GNSS/GNSS.jl
module GNSS
export GNSSFixType, GNSSTimeStamp, GNSSMeasurement
import StaticArrays, EnumX
import ..MyMessages
EnumX.@enumx GNSSFixType{UInt8} none = 0, fix_3d = 3, float_fix = 5, int_fix = 6
@kwdef struct GNSSTimeStamp
    weeks::UInt16
    microseconds::UInt64
end
@kwdef struct GNSSMeasurement
    timestamp::GNSSTimeStamp
    fix_type::GNSSFixType.T
    position_ecef::StaticArrays.SVector{3, Float64}
    velocity_ecef::StaticArrays.SVector{3, Float64}
    position_covariance_ecef::StaticArrays.SMatrix{3, 3, Float64, 9}
    velocity_covariance_ecef::StaticArrays.SMatrix{3, 3, Float64, 9}
end
end

# GNC/GNC.jl
module GNC
export Navigation
import StaticArrays, EnumX
import ..MyMessages
include("Navigation/Navigation.jl")
end

# GNC/Navigation/Navigation.jl
module Navigation
export NavInputs
import StaticArrays, EnumX
import ..MyMessages
@kwdef struct NavInputs
    barometer_measurement::MyMessages.Sensors.Barometer.BarometerMeasurement
    gnss_measurement::MyMessages.Sensors.GNSS.GNSSMeasurement
end
end
```

### Example C++

TODO

## Outstanding Questions

Are *all* types that the embedded software uses expected to come from this system? We only truly care about defining the interface between the embedded software and the simulation, but will the practical implementation of these types end up requiring that _everything_ is defined this way? For instance, if this system were used to describe a set of parameters for the embedded system, that implies that every parameter must be one of these types. That may prove restrictive when parameters might be better typed as C++-specific types (pointers, look-up-tables, etc.). We might allow the parameters to be defined using this IDL, but then have a "constants" structure inside the C++ that never touches the interface, and the parameters could be used to specify the structure.

Should we generate a top-level Project.toml file to provide compat bounds on StaticArrays and EnumX? We don't expect this to literally be a registered package, so the top-level module will simply be included, so that Project.toml wouldn't get used anyway. But one _could_ make the built system a package. In that case, it's up to the user to set that up how they like. So the answer here is _no_.
