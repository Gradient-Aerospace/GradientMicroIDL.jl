// These small C-linkage interfaces exercise both explicit message pointers and by-value
// returns. No C++ exceptions cross the boundary.
#include "Interop/Interop.hpp"
#include "MyMessages/MyMessages.hpp"

#include <limits>

using namespace Interop;

// Return a fixture through C++'s value constructor. Its argument order differs from storage
// order, and the local arrays cease to exist on return, so the result must own its
// elements.
static Packet make_packet() {

    const Scalars scalars{
        -8,
        -1600,
        -320000,
        std::numeric_limits<std::int64_t>::min(),
        200,
        60000,
        4000000000U,
        std::numeric_limits<std::uint64_t>::max(),
        1.25f,
        -2.5,
        65,
        Signed::minimum,
        Unsigned::maximum,
    };
    const double samples[6] = {1, 2, 3, 4, 5, 6};
    const float row[3] = {7, 8, 9};
    const std::int16_t column[3] = {-1, -2, -3};
    const Child children[2] = {Child{7, 1000}, Child{9, 2000}};
    const Signed states[2] = {Signed::minimum, Signed::maximum};
    const std::uint8_t bytes[3] = {65, 0, 255};
    return Packet{123, samples, row, column, children, states, bytes, scalars};

}

// Return the failing line number instead of using assert(), which would abort the Julia
// process. The same checker reads both C++-constructed and Julia-constructed messages.
extern "C" int check_packet(const Packet* packet) {

    const auto& s = packet->scalars;
    if (s.i8 != -8 || s.i16 != -1600 || s.i32 != -320000 ||
        s.i64 != std::numeric_limits<std::int64_t>::min()) {
        return __LINE__;
    }
    if (s.u8 != 200 || s.u16 != 60000 || s.u32 != 4000000000U ||
        s.u64 != std::numeric_limits<std::uint64_t>::max()) {
        return __LINE__;
    }
    if (s.f32 != 1.25f || s.f64 != -2.5 || s.byte != 65 ||
        s.signed_value != Signed::minimum || s.unsigned_value != Unsigned::maximum) {
        return __LINE__;
    }
    if (static_cast<std::uint64_t>(s.unsigned_value) !=
        std::numeric_limits<std::uint64_t>::max()) {
        return __LINE__;
    }

    // Const Eigen maps must preserve the rectangular matrix's column-major indexing.
    // Check all coefficients and the borrowed address, not just a symmetric diagonal.
    const auto samples = packet->samples_eigen();
    if (samples.data() != packet->samples) {
        return __LINE__;
    }
    for (int column = 0; column < 3; ++column) {
        for (int row = 0; row < 2; ++row) {
            if (samples(row, column) != 1 + row + 2 * column) {
                return __LINE__;
            }
        }
    }
    for (int index = 0; index < 3; ++index) {
        if (packet->row_eigen()(0, index) != 7 + index ||
            packet->column_eigen()(index, 0) != -1 - index) {
            return __LINE__;
        }
    }

    // The second child follows a padded first child. Reading both catches incorrect
    // message-array stride even when the first element happens to look correct.
    if (packet->sequence != 123 || packet->children[0].tag != 7 ||
        packet->children[0].count != 1000 || packet->children[1].tag != 9 ||
        packet->children[1].count != 2000) {
        return __LINE__;
    }
    if (packet->states[0] != Signed::minimum || packet->states[1] != Signed::maximum ||
        packet->bytes[0] != 65 || packet->bytes[1] != 0 || packet->bytes[2] != 255) {
        return __LINE__;
    }
    return 0;

}

// This writes every field into storage owned by Julia. Copy assignment remains trivial
// despite the generated value constructors; Julia never owns C++-allocated memory here.
extern "C" void write_packet(Packet* output) {
    *output = make_packet();
}

// Return differently shaped generated structs to exercise the target's return convention:
// a small integer aggregate, a floating-point aggregate, and a large nested message.
// Julia declares the struct itself as the ccall return type in all three cases.
// Clang warns because these types have C++ constructors and cannot be declared in C.
// This fixture deliberately tests their return ABI; silence only that specific warning.
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreturn-type-c-linkage"
#endif

extern "C" MyMessages::Sensors::GNSS::GNSSTimestamp return_timestamp() {
    return MyMessages::Sensors::GNSS::GNSSTimestamp{7, 123456};
}

extern "C" MyMessages::Sensors::GNSS::LatitudeLongitudeAltitudeWGS84 return_coordinates() {
    return MyMessages::Sensors::GNSS::LatitudeLongitudeAltitudeWGS84{0.25, -0.5, 1200.0};
}

extern "C" Packet return_packet() {
    return make_packet();
}

#ifdef __clang__
#pragma clang diagnostic pop
#endif

// Changing coefficients through a writable map must change the original array. Mix those
// writes with ordinary nested-member writes to exercise the complete shared layout.
extern "C" void update_packet(Packet* packet) {
    packet->samples_eigen()(1, 2) = 42.5;
    packet->row_eigen()(0, 1) = 80.0f;
    packet->column_eigen()(2, 0) = -30;
    packet->children[1].count = 3000;
    packet->states[0] = Signed::maximum;
    packet->bytes[1] = 255;
}

// Check behavior specific to C++ construction, separately from pointer interoperability.
// Include the real example to exercise vectors and cross-namespace message constructors.
extern "C" int check_constructors() {

    const Packet packet = make_packet();
    const int result = check_packet(&packet);
    if (result != 0) {
        return result;
    }

    // Default initialization covers nested structs, arrays, and unnamed zero enum values.
    const Packet empty;
    if (empty.sequence != 0 || empty.samples[5] != 0 || empty.children[1].count != 0 ||
        empty.scalars.u64 != 0 || static_cast<std::int64_t>(empty.states[0]) != 0) {
        return __LINE__;
    }

    using namespace MyMessages::Sensors::GNSS;
    const GNSSTimestamp timestamp{2, 30};
    double position[3] = {1, 2, 3};
    const double covariance[9] = {1, 2, 3, 4, 5, 6, 7, 8, 9};
    GNSSPositionMeasurement measurement{
        timestamp,
        GNSSFixType::fix_3d,
        position,
        covariance,
    };
    position[0] = 99;
    if (measurement.position_ecef[0] != 1 || measurement.timestamp.weeks != 2 ||
        measurement.timestamp.milliseconds != 30 ||
        measurement.fix_type != GNSSFixType::fix_3d) {
        return __LINE__;
    }
    measurement.position_ecef_eigen()(1) = 12;
    if (measurement.position_ecef[1] != 12) {
        return __LINE__;
    }
    return 0;

}
