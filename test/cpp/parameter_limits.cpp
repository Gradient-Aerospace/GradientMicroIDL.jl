// Compile this valid control first, then repeat with invalid template arguments. The
// same declarations are available to consumers even without any concrete IDL references.
#include "Parameters/Parameters.hpp"

#ifndef TEST_LENGTH
#define TEST_LENGTH 1
#endif

Parameters::Components::Motor<TEST_LENGTH> motor;
