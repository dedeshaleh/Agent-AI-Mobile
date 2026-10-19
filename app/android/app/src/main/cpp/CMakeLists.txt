cmake_minimum_required(VERSION 3.22)
project(agenthq_llama LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- llama.cpp (pinned) -----------------------------------------------------
# Override with -DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP=<existing checkout> to skip
# the clone (useful for standalone rebuilds; see README.md).
set(AGENTHQ_LLAMA_TAG "b11727" CACHE STRING "llama.cpp git tag")

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
FetchContent_Declare(
  llama_cpp
  GIT_REPOSITORY https://github.com/ggml-org/llama.cpp.git
  GIT_TAG        ${AGENTHQ_LLAMA_TAG}
  GIT_SHALLOW    TRUE
  GIT_PROGRESS   TRUE
  GIT_CONFIG     core.longpaths=true # Windows: some llama.cpp paths exceed MAX_PATH in deep build dirs
)
FetchContent_MakeAvailable(llama_cpp)

# --- shim -------------------------------------------------------------------
add_library(agenthq_llama SHARED agenthq_llama.cpp)
target_include_directories(agenthq_llama PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(agenthq_llama PRIVATE -Wall -Wextra -fvisibility=hidden)
target_link_libraries(agenthq_llama PRIVATE llama ggml)
if (ANDROID)
  target_link_libraries(agenthq_llama PRIVATE log)
endif()

# 16 KB page alignment (Android 15), hide statically linked llama/ggml symbols,
# drop unreferenced sections.
target_link_options(agenthq_llama PRIVATE
  "-Wl,-z,max-page-size=16384"
  "-Wl,--exclude-libs,ALL"
  "-Wl,--gc-sections")
