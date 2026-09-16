// The harness first compiles the valid branch, proving the include paths and compiler
// setup work. Each TEST_* branch must then fail compilation for its prohibited operation.
#include "Interop/Interop.hpp"

#if defined(TEST_CONST_WRITE)
void use_view(const Interop::Packet& packet) {
    packet.samples_eigen()(0, 0) = 1;
}
#elif defined(TEST_TEMPORARY)
void use_view() {
    auto view = Interop::Packet{}.samples_eigen();
}
#elif defined(TEST_CONST_TEMPORARY)
void use_view() {
    auto view = static_cast<const Interop::Packet&&>(Interop::Packet{}).samples_eigen();
}
#else
double use_view(Interop::Packet& packet, const Interop::Packet& reading) {
    packet.samples_eigen()(0, 0) = 1;
    return reading.samples_eigen()(0, 0);
}
#endif
