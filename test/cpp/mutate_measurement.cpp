// The generated header is included outside the linkage block: it contains C++ types
// and Eigen templates. Only the callable function below needs C linkage.
#include "MyMessages/MyMessages.hpp"

using MyMessages::Sensors::GNSS::GNSSMeasurement;

extern "C" {

// Translate the measured position by a known offset. The pointer borrows storage from
// Julia; the Eigen view writes directly into that storage without copying the vector.
void translate_position(GNSSMeasurement* measurement) {

    auto position = measurement->position_ecef_eigen();
    position(0) += 10.0;
    position(1) += 20.0;
    position(2) += 30.0;

}

} // extern "C"
