cmake_minimum_required(VERSION 3.22)
project(agenthq_llama LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- llama.cpp (pinned) -----------------------------------------------------
# Override with -DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP=<existing checkout> to skip
# the clone (useful for standalone rebuilds; see README.md).
set(AGENTHQ_LLAMA_TAG "b11727" CACHE STRING "llama.cpp git tag")

# Optional GPU backend (ggml Vulkan) compiled into the same libagenthq_llama.so.
# Default ON; the CPU backend is always built. Needs a HOST C++ compiler to build
# llama.cpp's shader generator (vulkan-shaders-gen) and the NDK's glslc; when no
# host compiler is found the build falls back to CPU-only with a warning.
option(AGENTHQ_GPU_VULKAN "Build the ggml Vulkan backend into libagenthq_llama.so" ON)
set(AGENTHQ_VULKAN_HEADERS_TAG "v1.4.363"             CACHE STRING "KhronosGroup/Vulkan-Headers tag (vulkan.hpp; NDK ships only the C headers)")
set(AGENTHQ_SPIRV_HEADERS_TAG  "vulkan-sdk-1.4.363.0" CACHE STRING "KhronosGroup/SPIRV-Headers tag (spirv/unified1/spirv.hpp)")

# Optional second GPU backend (ggml OpenCL) for GPUs whose Vulkan driver is too old
# for ggml-vulkan (Mali-G610 on the Infinix X6871 reports Vulkan 1.1). Headers are
# fetched; the "library" is cl_shim.cpp (static trampolines that dlopen the vendor
# driver on first use), so the .so has no NEEDED on libOpenCL.so. The Khronos ICD loader
# was tried first and dropped: the Mali driver lacks clIcdGetPlatformIDsKHR. Needs
# python3 on the host for ggml's kernel embedding script.
option(AGENTHQ_GPU_OPENCL "Build the ggml OpenCL backend into libagenthq_llama.so" ON)
set(AGENTHQ_OPENCL_HEADERS_TAG "v2026.05.29" CACHE STRING "KhronosGroup/OpenCL-Headers tag")

set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE         OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL        OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI      OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE            OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL          OFF CACHE BOOL "" FORCE) # replaces LLAMA_CURL at this tag
set(LLAMA_CURL             OFF CACHE BOOL "" FORCE) # deprecated alias, kept for clarity
set(LLAMA_BUILD_COMMON     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES   OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS      OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP        OFF CACHE BOOL "" FORCE)
set(LLAMA_ALL_WARNINGS     OFF CACHE BOOL "" FORCE)

# Dimensity 8200 (Cortex-A78/A510): armv8.2-a with dotprod + fp16, no i8mm/SVE.
# Runtime dispatch (GGML_CPU_ALL_VARIANTS) needs GGML_BACKEND_DL + shared ggml
# libraries, so a fixed -march is used for this single static-linked .so.
if (ANDROID_ABI STREQUAL "arm64-v8a" OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
endif()

include(FetchContent)

# --- Vulkan backend prerequisites ------------------------------------------
# llama.cpp's ggml-vulkan needs (a) vulkan.hpp + a recent vulkan_core.h (the NDK
# sysroot only has the C headers at VK_HEADER_VERSION 275), (b) SPIRV-Headers,
# (c) glslc (NDK shader-tools) and (d) a host compiler for vulkan-shaders-gen,
# which is built as an ExternalProject and *executed* at build time.
set(AGENTHQ_GPU_VULKAN_ENABLED OFF)
if (AGENTHQ_GPU_VULKAN)
  set(_agenthq_vk_ok ON)

  # (d) host compiler -> toolchain file for the ExternalProject.
  if (CMAKE_CROSSCOMPILING AND NOT GGML_VULKAN_SHADERS_GEN_TOOLCHAIN)
    set(_agenthq_host_hints "")
    if (CMAKE_HOST_WIN32)
      # winget portable packages (WinLibs / LLVM-MinGW, user scope) plus MSYS2/MinGW defaults.
      file(GLOB _agenthq_winget_bins
        "$ENV{LOCALAPPDATA}/Microsoft/WinGet/Packages/BrechtSanders.WinLibs*/mingw64/bin"
        "$ENV{LOCALAPPDATA}/Microsoft/WinGet/Packages/MartinStorsjo.LLVM-MinGW*/*/bin")
      list(APPEND _agenthq_host_hints
        ${_agenthq_winget_bins}
        "$ENV{LOCALAPPDATA}/Microsoft/WinGet/Links"
        "C:/msys64/ucrt64/bin" "C:/msys64/mingw64/bin" "C:/mingw64/bin")
    endif()
    find_program(AGENTHQ_HOST_C_COMPILER   NAMES gcc clang cl   HINTS ${_agenthq_host_hints} NO_CMAKE_FIND_ROOT_PATH)
    find_program(AGENTHQ_HOST_CXX_COMPILER NAMES g++ clang++ cl HINTS ${_agenthq_host_hints} NO_CMAKE_FIND_ROOT_PATH)
    if (AGENTHQ_HOST_C_COMPILER AND AGENTHQ_HOST_CXX_COMPILER)
      message(STATUS "agenthq: host compiler for vulkan-shaders-gen: ${AGENTHQ_HOST_CXX_COMPILER}")
      # Gradle passes CMAKE_MAKE_PROGRAM with Windows backslashes, which CMake would read
      # as escapes inside the generated toolchain file.
      file(TO_CMAKE_PATH "${CMAKE_MAKE_PROGRAM}" AGENTHQ_HOST_MAKE_PROGRAM)
      configure_file(${CMAKE_CURRENT_SOURCE_DIR}/cmake/host-toolchain.cmake.in
                     ${CMAKE_BINARY_DIR}/agenthq-host-toolchain.cmake @ONLY)
      set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${CMAKE_BINARY_DIR}/agenthq-host-toolchain.cmake" CACHE FILEPATH "" FORCE)
    else()
      message(WARNING "agenthq: no host C/C++ compiler found (gcc/clang/cl) to build vulkan-shaders-gen; "
                      "building CPU-only. Install e.g. `winget install BrechtSanders.WinLibs.POSIX.UCRT` "
                      "or pass -DGGML_VULKAN_SHADERS_GEN_TOOLCHAIN=<host toolchain file>.")
      set(_agenthq_vk_ok OFF)
    endif()
  endif()

  # (c) glslc from the NDK (no Vulkan SDK on this PC).
  if (_agenthq_vk_ok AND NOT Vulkan_GLSLC_EXECUTABLE)
    set(_agenthq_glslc_hints "")
    if (ANDROID_NDK)
      file(GLOB _agenthq_glslc_hints "${ANDROID_NDK}/shader-tools/*")
    endif()
    find_program(Vulkan_GLSLC_EXECUTABLE NAMES glslc HINTS ${_agenthq_glslc_hints} NO_CMAKE_FIND_ROOT_PATH)
    if (NOT Vulkan_GLSLC_EXECUTABLE)
      message(WARNING "agenthq: glslc not found (expected under ${ANDROID_NDK}/shader-tools); building CPU-only.")
      set(_agenthq_vk_ok OFF)
    endif()
  endif()

  if (_agenthq_vk_ok)
    # (a)+(b) header-only Khronos repos, shallow clones.
    FetchContent_Declare(vulkan_headers
      GIT_REPOSITORY https://github.com/KhronosGroup/Vulkan-Headers.git
      GIT_TAG        ${AGENTHQ_VULKAN_HEADERS_TAG}
      GIT_SHALLOW    TRUE)
    FetchContent_Declare(spirv_headers
      GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Headers.git
      GIT_TAG        ${AGENTHQ_SPIRV_HEADERS_TAG}
      GIT_SHALLOW    TRUE)
    FetchContent_Populate(vulkan_headers)
    FetchContent_Populate(spirv_headers)

    # Satisfy FindVulkan without a Vulkan SDK: headers from Khronos, loader from the NDK sysroot.
    set(Vulkan_INCLUDE_DIR "${vulkan_headers_SOURCE_DIR}/include" CACHE PATH "" FORCE)
    if (NOT Vulkan_LIBRARY)
      find_library(Vulkan_LIBRARY NAMES vulkan)   # <sysroot>/usr/lib/aarch64-linux-android/<api>/libvulkan.so
    endif()
    if (NOT Vulkan_LIBRARY)
      message(WARNING "agenthq: libvulkan.so not found in the NDK sysroot; building CPU-only.")
      set(_agenthq_vk_ok OFF)
    endif()
  endif()

  if (_agenthq_vk_ok)
    # ggml-vulkan does find_package(SPIRV-Headers CONFIG REQUIRED); point it at a stub
    # config that wraps the fetched checkout. The Android toolchain re-roots package
    # search (MODE_PACKAGE ONLY), so allow host paths for packages too.
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
    set(SPIRV-Headers_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake/SPIRV-Headers" CACHE PATH "" FORCE)
    set(AGENTHQ_SPIRV_HEADERS_INCLUDE "${spirv_headers_SOURCE_DIR}/include")

    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    set(AGENTHQ_GPU_VULKAN_ENABLED ON)
    message(STATUS "agenthq: GGML_VULKAN=ON (glslc: ${Vulkan_GLSLC_EXECUTABLE}; loader: ${Vulkan_LIBRARY})")
  else()
    set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
  endif()
else()
  set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
endif()

# --- OpenCL backend prerequisites ------------------------------------------
set(AGENTHQ_GPU_OPENCL_ENABLED OFF)
if (AGENTHQ_GPU_OPENCL AND NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  # ggml-opencl b11727 does not compile for 32-bit targets (int64 -> size_t narrowing in
  # work-size initialisers); Gradle still configures armeabi-v7a for debug builds.
  message(STATUS "agenthq: GGML_OPENCL skipped for 32-bit ABI ${ANDROID_ABI}")
  set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
elseif (AGENTHQ_GPU_OPENCL)
  set(_agenthq_cl_ok ON)

  # ggml-opencl embeds its kernels with kernels/embed_kernel.py (find_package(Python3)).
  if (NOT Python3_EXECUTABLE)
    set(_agenthq_py_hints "")
    if (CMAKE_HOST_WIN32)
      file(GLOB _agenthq_py_hints "$ENV{LOCALAPPDATA}/Programs/Python/Python3*" "C:/Python3*")
    endif()
    find_program(Python3_EXECUTABLE NAMES python3 python HINTS ${_agenthq_py_hints} NO_CMAKE_FIND_ROOT_PATH)
  endif()
  if (NOT Python3_EXECUTABLE)
    message(WARNING "agenthq: python3 not found (needed by ggml-opencl to embed kernels); building without OpenCL.")
    set(_agenthq_cl_ok OFF)
  endif()

  if (_agenthq_cl_ok)
    FetchContent_Declare(opencl_headers
      GIT_REPOSITORY https://github.com/KhronosGroup/OpenCL-Headers.git
      GIT_TAG        ${AGENTHQ_OPENCL_HEADERS_TAG}
      GIT_SHALLOW    TRUE)
    FetchContent_Populate(opencl_headers)
    set(AGENTHQ_OPENCL_INCLUDE_DIR "${opencl_headers_SOURCE_DIR}" CACHE INTERNAL "OpenCL-Headers include dir (CL/cl.h)")

    # Direct-binding shim (cl_shim.cpp): trampolines that dlopen the vendor
    # libOpenCL.so on first use. Replaces the Khronos ICD loader, which needs the
    # driver to export clIcdGetPlatformIDsKHR (the Mali driver on the X6871 does not).
    add_library(agenthq_cl_shim STATIC cl_shim.cpp)
    target_include_directories(agenthq_cl_shim PUBLIC ${AGENTHQ_OPENCL_INCLUDE_DIR})
    target_compile_options(agenthq_cl_shim PRIVATE -Wall -Wextra -Wno-deprecated-declarations)
    set_target_properties(agenthq_cl_shim PROPERTIES POSITION_INDEPENDENT_CODE ON)
    target_link_libraries(agenthq_cl_shim PUBLIC ${CMAKE_DL_LIBS})
    if (ANDROID)
      target_link_libraries(agenthq_cl_shim PUBLIC log)
    endif()
    add_library(OpenCL::OpenCL ALIAS agenthq_cl_shim)

    # ggml-opencl's find_package(OpenCL REQUIRED) is answered by cmake/modules/FindOpenCL.cmake.
    list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")
    set(GGML_OPENCL                    ON  CACHE BOOL "" FORCE)
    set(GGML_OPENCL_EMBED_KERNELS      ON  CACHE BOOL "" FORCE)  # no .cl files needed at runtime
    set(GGML_OPENCL_USE_ADRENO_KERNELS OFF CACHE BOOL "" FORCE)  # Mali: generic kernels only
    set(GGML_OPENCL_USE_ADRENO_BIN_KERNELS OFF CACHE BOOL "" FORCE)
    set(GGML_OPENCL_PROFILING          OFF CACHE BOOL "" FORCE)
    set(AGENTHQ_GPU_OPENCL_ENABLED ON)
    message(STATUS "agenthq: GGML_OPENCL=ON (headers: ${AGENTHQ_OPENCL_INCLUDE_DIR}; direct-binding cl_shim; python: ${Python3_EXECUTABLE})")
  else()
    set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
  endif()
else()
  set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
endif()

FetchContent_Declare(
  llama_cpp
  GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
  GIT_TAG        ${AGENTHQ_LLAMA_TAG}
  GIT_SHALLOW    TRUE
  GIT_PROGRESS   TRUE
  GIT_CONFIG     core.longpaths=true # Windows: some llama.cpp paths exceed MAX_PATH in deep build dirs
  # Mali/Android: make ggml's buffer-device-address use opt-out (GGML_VK_DISABLE_BDA),
  # otherwise the first Vulkan host buffer dereferences a NULL loader entry.
  # ggml-opencl: accept non-Adreno GPUs and turn kernel-compile exit(1) into exceptions.
  PATCH_COMMAND  ${CMAKE_COMMAND} -DSRC=<SOURCE_DIR> -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/patch-ggml-vulkan.cmake
         COMMAND ${CMAKE_COMMAND} -DSRC=<SOURCE_DIR> -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/patch-ggml-opencl.cmake
  UPDATE_DISCONNECTED TRUE
)
FetchContent_MakeAvailable(llama_cpp)

if (AGENTHQ_GPU_OPENCL_ENABLED AND TARGET ggml-opencl)
  # The patched exit(1) paths throw; exceptions must unwind through ggml-opencl.
  target_compile_options(ggml-opencl PRIVATE -fexceptions -frtti)
endif()

if (AGENTHQ_GPU_VULKAN_ENABLED AND TARGET ggml-vulkan)
  # spirv.hpp is included via __has_include; ggml-vulkan's CMake only checks the package exists.
  target_include_directories(ggml-vulkan PRIVATE ${AGENTHQ_SPIRV_HEADERS_INCLUDE})
  # vulkan.hpp exceptions are caught by ggml (ggml_backend_vk_reg returns NULL when
  # instance creation fails), so RTTI/exceptions stay on for this target.
  target_compile_options(ggml-vulkan PRIVATE -fexceptions -frtti)
  # std::aligned_alloc needs API 28 on Bionic; the app targets android-26.
  if (ANDROID)
    target_compile_options(ggml-vulkan PRIVATE "SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/cmake/agenthq_vk_compat.h")
  endif()
endif()

# --- shim -------------------------------------------------------------------
add_library(agenthq_llama SHARED agenthq_llama.cpp)
target_include_directories(agenthq_llama PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(agenthq_llama PRIVATE -Wall -Wextra -fvisibility=hidden)
target_link_libraries(agenthq_llama PRIVATE llama ggml)
if (AGENTHQ_GPU_VULKAN_ENABLED)
  target_compile_definitions(agenthq_llama PRIVATE AGENTHQ_HAVE_VULKAN=1)
endif()
if (AGENTHQ_GPU_OPENCL_ENABLED)
  # The shim calls clGetPlatformIDs/clGetDeviceInfo itself (driver probe for gpu_info).
  target_compile_definitions(agenthq_llama PRIVATE AGENTHQ_HAVE_OPENCL=1 CL_TARGET_OPENCL_VERSION=300)
  target_link_libraries(agenthq_llama PRIVATE agenthq_cl_shim)
endif()
if (ANDROID)
  target_link_libraries(agenthq_llama PRIVATE log)
endif()

# 16 KB page alignment (Android 15), hide statically linked llama/ggml symbols,
# drop unreferenced sections.
target_link_options(agenthq_llama PRIVATE
  "-Wl,-z,max-page-size=16384"
  "-Wl,--exclude-libs,ALL"
  "-Wl,--gc-sections")
