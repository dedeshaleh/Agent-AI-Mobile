# Applied to the fetched llama.cpp sources (FetchContent PATCH_COMMAND). Idempotent
# per hunk and able to upgrade a tree patched by an earlier version of this script.
#
# ggml-opencl (b11727) was written for Qualcomm Adreno and Intel GPUs:
#   (1) every other device is dropped in ggml_opencl_is_device_supported();
#   (2) loading the gated_delta_net kernels exit(1)s for other families;
#   (3) any kernel compile failure exit(1)s the whole process;
#   (4) the kernels only define INTEL_GPU/ADRENO_GPU (and with them N_SIMDWIDTH,
#       N_DST, REQD_SUBGROUP_SIZE_*) when the compiler advertises
#       cl_intel_required_subgroup_size / cl_qcom_reqd_sub_group_size;
#   (5) ~37 op dispatchers branch on gpu_family and GGML_ASSERT(false) otherwise.
# Mali (Valhall, e.g. G610) has 16-wide subgroups like Intel, so non-Adreno GPUs are
# treated as the INTEL family ("generic 16-wide GPU"): the Intel kernel variants are
# selected with -D flags (attribute macros defined empty) and the few places that
# hard-code Intel's 32-wide reductions use 16 instead. (2)/(3) become C++ exceptions
# that propagate out of llama_model_load_from_file into agenthq_llama.cpp, which
# answers AGENTHQ_ERR_GPU_UNAVAILABLE so Dart falls back to the CPU.
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

set(_n_applied 0)
set(_n_skipped 0)
# Replaces every occurrence of `needle` with `replacement`; skipped when the
# replacement is already present. An optional 4th argument names a VARIABLE holding
# a legacy anchor (text written by an earlier version of this script) that is
# upgraded to the same replacement. Anchors are passed by variable name because the
# C++ snippets contain ';', which CMake would otherwise split as list separators.
function(_agenthq_replace needle replacement what)
  string(FIND "${_content}" "${replacement}" _done)
  if (_done GREATER -1)
    math(EXPR _s "${_n_skipped} + 1")
    set(_n_skipped "${_s}" PARENT_SCOPE)
    return()
  endif()
  set(_hit OFF)
  string(FIND "${_content}" "${needle}" _pos)
  if (NOT _pos EQUAL -1)
    string(REPLACE "${needle}" "${replacement}" _content "${_content}")
    set(_hit ON)
  endif()
  if (ARGC GREATER 3)
    set(_legacy "${${ARGV3}}")
    string(FIND "${_content}" "${_legacy}" _lpos)
    if (NOT _lpos EQUAL -1)
      string(REPLACE "${_legacy}" "${replacement}" _content "${_content}")
      set(_hit ON)
    endif()
  endif()
  if (_hit)
    set(_content "${_content}" PARENT_SCOPE)
    math(EXPR _n "${_n_applied} + 1")
    set(_n_applied "${_n}" PARENT_SCOPE)
  else()
    message(WARNING "agenthq: ggml-opencl patch anchor not found (${what}); llama.cpp tag changed? OpenCL on Mali may not work.")
  endif()
endfunction()

set(_generic_macro "#define AGENTHQ_GENERIC_GPU(ctx) ((ctx)->gpu_family == GPU_FAMILY::INTEL && (ctx)->device_name.find(\"Intel\") == std::string::npos) // agenthq patch: Mali & co. ride the Intel (16-wide) code paths")

# (0) <stdexcept> for the throws below + the generic-GPU macro.
set(_legacy0 "#include \"cl-program-cache.h\"\n#include <stdexcept> // agenthq patch\n")
_agenthq_replace(
  "#include \"cl-program-cache.h\"\n"
  "#include \"cl-program-cache.h\"\n#include <stdexcept> // agenthq patch\n${_generic_macro}\n"
  "stdexcept include + macro"
  _legacy0)

# (1) accept non-Adreno/Intel GPUs as Intel-like.
set(_legacy1 "        GGML_LOG_WARN(\"ggml_opencl: GPU '%s' is not Adreno/Intel; using generic kernels (agenthq patch)\\n\", dev_ctx->device_name.c_str());\n        dev_ctx->gpu_family = GPU_FAMILY::UNKNOWN;")
_agenthq_replace(
  "        GGML_LOG_WARN(\"ggml_opencl: unsupported GPU '%s'.\\n\", dev_ctx->device_name.c_str());\n        dev_ctx->gpu_family = GPU_FAMILY::UNKNOWN;\n        return false;"
  "        GGML_LOG_WARN(\"ggml_opencl: GPU '%s' is not Adreno/Intel; treating it as a 16-wide-subgroup GPU via the Intel code paths (agenthq patch)\\n\", dev_ctx->device_name.c_str());\n        dev_ctx->gpu_family = GPU_FAMILY::INTEL;"
  "unsupported GPU family"
  _legacy1)

# (2) gated_delta_net kernels: Intel's 32-wide variants do not exist for a 16-wide
#     generic GPU; skip them instead of exit(1).
_agenthq_replace(
  "backend_ctx->gpu_family == GPU_FAMILY::INTEL ? 32 : -1;"
  "(backend_ctx->gpu_family == GPU_FAMILY::INTEL && !AGENTHQ_GENERIC_GPU(backend_ctx)) ? 32 : -1; // agenthq patch"
  "gated_delta_net sg_size")
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

# (4) generic GPU: compile the Intel (16-wide subgroup) kernel variants.
set(_generic_defs "    if (AGENTHQ_GENERIC_GPU(backend_ctx)) {\n        // agenthq patch: Mali/other 16-wide-subgroup GPUs use the Intel kernel variants;\n        // the Intel-only required-subgroup-size attributes are defined empty.\n        compile_opts += \" -DINTEL_GPU=1 -DREQD_SUBGROUP_SIZE_16= -DREQD_SUBGROUP_SIZE_32=\";\n    }\n")
set(_legacy_defs  "    if (backend_ctx->gpu_family == GPU_FAMILY::UNKNOWN) {\n        // agenthq patch: Mali/other 16-wide-subgroup GPUs use the Intel kernel variants;\n        // the Intel-only required-subgroup-size attributes are defined empty.\n        compile_opts += \" -DINTEL_GPU=1 -DREQD_SUBGROUP_SIZE_16= -DREQD_SUBGROUP_SIZE_32=\";\n    }\n")
set(_legacy4a "    if (backend_ctx->adreno_use_large_buffer) {\n        compile_opts += \" -qcom-enable-large-buffer \";\n    }\n${_legacy_defs}\n    return compile_opts;")
_agenthq_replace(
  "    if (backend_ctx->adreno_use_large_buffer) {\n        compile_opts += \" -qcom-enable-large-buffer \";\n    }\n\n    return compile_opts;"
  "    if (backend_ctx->adreno_use_large_buffer) {\n        compile_opts += \" -qcom-enable-large-buffer \";\n    }\n${_generic_defs}\n    return compile_opts;"
  "generic family compile opts"
  _legacy4a)
set(_legacy4b "                               \" -cl-finite-math-only -cl-fast-relaxed-math\";\n${_legacy_defs}\n    // argsort\n")
_agenthq_replace(
  "                               \" -cl-finite-math-only -cl-fast-relaxed-math\";\n\n    // argsort\n"
  "                               \" -cl-finite-math-only -cl-fast-relaxed-math\";\n${_generic_defs}\n    // argsort\n"
  "generic family compile opts (argsort)"
  _legacy4b)

# (5) reductions that hard-code Intel's 32-wide subgroup: 16 on a generic GPU.
_agenthq_replace(
  "sgs = 32;"
  "sgs = AGENTHQ_GENERIC_GPU(backend_ctx) ? 16 : 32; // agenthq patch"
  "sgs = 32 sites")

if (_n_applied EQUAL 0)
  message(STATUS "agenthq: ggml-opencl patch: nothing to do (${_n_skipped} hunks already applied)")
  return()
endif()
file(WRITE "${_file}" "${_content}")
message(STATUS "agenthq: ggml-opencl patch applied (${_n_applied} new, ${_n_skipped} already present) to ${_file}")
