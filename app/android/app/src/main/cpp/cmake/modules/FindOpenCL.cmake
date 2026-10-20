# Replacement for CMake's FindOpenCL used by ggml-opencl's `find_package(OpenCL REQUIRED)`.
#
# There is no OpenCL SDK in the NDK: headers come from KhronosGroup/OpenCL-Headers and
# the "library" is our static direct-binding shim (target `agenthq_cl_shim`, built from
# cl_shim.cpp by CMakeLists.txt before llama.cpp is added). The shim dlopen()s the vendor
# driver at runtime, so libagenthq_llama.so gets no NEEDED entry for libOpenCL.so and
# still loads on devices without a driver.
if (NOT TARGET agenthq_cl_shim)
  message(FATAL_ERROR "agenthq FindOpenCL: the shim target `agenthq_cl_shim` does not exist yet")
endif()
if (NOT AGENTHQ_OPENCL_INCLUDE_DIR)
  message(FATAL_ERROR "agenthq FindOpenCL: AGENTHQ_OPENCL_INCLUDE_DIR is not set")
endif()
set(OpenCL_FOUND        TRUE)
set(OPENCL_FOUND        TRUE)
set(OpenCL_INCLUDE_DIR  "${AGENTHQ_OPENCL_INCLUDE_DIR}")
set(OpenCL_INCLUDE_DIRS "${AGENTHQ_OPENCL_INCLUDE_DIR}")
set(OpenCL_LIBRARY      agenthq_cl_shim)
set(OpenCL_LIBRARIES    agenthq_cl_shim)
set(OpenCL_VERSION_STRING "3.0")
set(OpenCL_VERSION_MAJOR 3)
set(OpenCL_VERSION_MINOR 0)
if (NOT TARGET OpenCL::OpenCL)
  add_library(OpenCL::OpenCL ALIAS agenthq_cl_shim)
endif()
