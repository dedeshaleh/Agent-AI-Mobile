# Applied to the fetched llama.cpp sources (FetchContent PATCH_COMMAND). Idempotent.
#
# ggml-opencl (b11727) was written for Qualcomm Adreno and Intel GPUs and
#   (1) drops every other device in ggml_opencl_is_device_supported(), so a Mali
#       GPU would never appear in the registry,
#   (2) exit(1)s while loading the gated_delta_net kernels when the GPU family is
#       neither Adreno nor Intel (those kernels are only used by Qwen3-Next style
#       models), and
#   (3) exit(1)s the whole process when any embedded kernel fails to compile.
# For an app, (2)/(3) must become recoverable errors: they are turned into
# C++ exceptions that propagate out of llama_model_load_from_file /
# llama_init_from_model into agenthq_llama.cpp, which answers
# AGENTHQ_ERR_GPU_UNAVAILABLE so Dart falls back to the CPU.
#
# Usage: cmake -DSRC=<llama.cpp source dir> -P patch-ggml-opencl.cmake
if (NOT SRC)
  message(FATAL_ERROR "patch-ggml-opencl.cmake: pass -DSRC=<llama.cpp source dir>")
endif()
set(_file "${SRC}/ggml/src/ggml-opencl/ggml-opencl.cpp")
if (NOT EXISTS "${_file}")
  message(FATAL_ERROR "patch-ggml-opencl.cmake: ${_file} not found")
endif()
file(READ "${_file}" _content)

string(FIND "${_content}" "agenthq patch" _already)
if (_already GREATER -1)
  message(STATUS "agenthq: ggml-opencl patch already applied")
  return()
endif()

set(_n_applied 0)
function(_agenthq_replace needle replacement what)
  string(FIND "${_content}" "${needle}" _pos)
  if (_pos EQUAL -1)
    message(WARNING "agenthq: ggml-opencl patch anchor not found (${what}); llama.cpp tag changed? OpenCL on Mali may not work.")
  else()
    string(REPLACE "${needle}" "${replacement}" _new "${_content}")
    set(_content "${_new}" PARENT_SCOPE)
    math(EXPR _n "${_n_applied} + 1")
    set(_n_applied "${_n}" PARENT_SCOPE)
  endif()
endfunction()

# (0) <stdexcept> for the throws below.
_agenthq_replace(
  "#include \"cl-program-cache.h\""
  "#include \"cl-program-cache.h\"\n#include <stdexcept> // agenthq patch"
  "stdexcept include")

# (1) accept non-Adreno/Intel GPUs with the generic kernels.
_agenthq_replace(
  "        GGML_LOG_WARN(\"ggml_opencl: unsupported GPU '%s'.\\n\", dev_ctx->device_name.c_str());\n        dev_ctx->gpu_family = GPU_FAMILY::UNKNOWN;\n        return false;"
  "        GGML_LOG_WARN(\"ggml_opencl: GPU '%s' is not Adreno/Intel; using generic kernels (agenthq patch)\\n\", dev_ctx->device_name.c_str());\n        dev_ctx->gpu_family = GPU_FAMILY::UNKNOWN;"
  "unsupported GPU family")

# (2) gated_delta_net kernels: skip instead of exit(1) on an unknown family.
_agenthq_replace(
  "        if (sg_size < 0) {\n            GGML_LOG_ERROR(\"Unsupported GPU Family: only Adreno and Intel are supported.\\n\");\n            exit(1);\n        }\n"
  "        if (sg_size < 0) {\n            GGML_LOG_WARN(\"ggml_opencl: skipping gated_delta_net kernels on this GPU family (agenthq patch)\\n\");\n        } else\n"
  "gated_delta_net exit")

# (3) kernel compile failures -> exception instead of exit(1).
_agenthq_replace(
  "            GGML_LOG_ERROR(\"OpenCL error creating program\");\n            if (fatal) exit(1);"
  "            GGML_LOG_ERROR(\"OpenCL error creating program\");\n            if (fatal) throw std::runtime_error(\"ggml_opencl: clCreateProgramWithSource failed\"); // agenthq patch"
  "create program exit")
_agenthq_replace(
  "        clReleaseProgram(p);\n        if (fatal) {\n            exit(1);\n        }\n        return nullptr;"
  "        clReleaseProgram(p);\n        if (fatal) {\n            throw std::runtime_error(std::string(\"ggml_opencl: kernel compile failed\") + (tag ? std::string(\" (\") + tag + \")\" : \"\")); // agenthq patch\n        }\n        return nullptr;"
  "compile error exit")

if (_n_applied EQUAL 0)
  message(WARNING "agenthq: no ggml-opencl patch hunk applied")
  return()
endif()
file(WRITE "${_file}" "${_content}")
message(STATUS "agenthq: ggml-opencl patch applied (${_n_applied}/5 hunks) to ${_file}")
