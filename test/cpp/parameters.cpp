#include "Parameters/Parameters.hpp"

using Parameters::Components::Motor;
using Parameters::Components::Controller;
using Parameters::Components::Vehicle;

// Julia compares the compiler's layout with its own instantiated types. These values
// are independent of the generator's symbolic size calculations and static assertions.
extern "C" std::size_t parameter_layout(std::size_t type, std::size_t property) {

    using Small = Controller<1, 1>;
    using Large = Controller<4, 3>;
    using Fleet = Parameters::Nested::Fleet<2>;
    const std::size_t values[][4] = {
        {sizeof(Motor<1>), alignof(Motor<1>), offsetof(Motor<1>, values),
            offsetof(Motor<1>, tag)},
        {sizeof(Motor<4>), alignof(Motor<4>), offsetof(Motor<4>, values),
            offsetof(Motor<4>, tag)},
        {sizeof(Small), alignof(Small), offsetof(Small, motors), offsetof(Small, count)},
        {sizeof(Large), alignof(Large), offsetof(Large, motors), offsetof(Large, count)},
        {sizeof(Vehicle), alignof(Vehicle), offsetof(Vehicle, controllers), 0},
        {sizeof(Fleet), alignof(Fleet), offsetof(Fleet, vehicles), 0},
    };
    return values[type][property];

}

// Construct templates of several sizes to instantiate their layout checks. Array
// arguments are copied, and a parameterized Eigen view then updates Julia's storage.
extern "C" void update_controller(Controller<4, 3>* output) {

    const Motor<1> small{};
    const Controller<1, 1> small_controller{};
    const Vehicle vehicle{};
    const Parameters::Nested::Fleet<2> fleet{};
    (void)small;
    (void)small_controller;
    (void)vehicle;
    (void)fleet;

    const double coefficients[4] = {1, 2, 3, 4};
    const double backup_coefficients[2] = {5, 6};
    const Motor<4> motor{7, 2.0, coefficients};
    const Motor<4> motors[3] = {motor, motor, motor};
    const Motor<4> matrix[2] = {motor, motor};
    *output = Controller<4, 3>{
        3,
        8.0,
        motors,
        Motor<2>{9, 3.0, backup_coefficients},
        matrix,
    };
    output->motors[2].values_eigen()(3) = 42.0;

}
