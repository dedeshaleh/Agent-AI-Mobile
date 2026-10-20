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

# (6) rms_norm_mul / rms_norm_mul_add size their per-subgroup scratch as `sgs` floats.
#     That equals nth/sgs only for Intel (32 x 32 = 1024 threads); with 16-wide
#     subgroups a 1024-thread group has 64 subgroups -> the kernel writes past the
#     scratch buffer -> garbage activations (the Mali "random text" symptom).
_agenthq_replace(
  "sizeof(float)*sgs, NULL"
  "sizeof(float)*((size_t) nth/sgs > sgs ? (size_t) nth/sgs : sgs), NULL /* agenthq patch: scratch per subgroup (a) */"
  "rms_norm_mul_add scratch size")
_agenthq_replace(
  "sizeof(float)*sgs,     NULL"
  "sizeof(float)*((size_t) nth/sgs > sgs ? (size_t) nth/sgs : sgs), NULL /* agenthq patch: scratch per subgroup (b) */"
  "rms_norm_mul scratch size")

# (7) the gated_delta_net kernels are skipped in (2), but supports_op still claimed
#     the op, so ggml scheduled it on the GPU and the dispatcher hit
#     GGML_ASSERT(kernel != nullptr) (SIGABRT with Qwen3.5, a Gated DeltaNet model).
#     Decline the op so ggml runs it on the CPU.
_agenthq_replace(
  "        case GGML_OP_GATED_DELTA_NET:\n            {\n                // Match the Vulkan backend: only F32 -> F32, S_v in {16, 32, 64, 128}.\n"
  "        case GGML_OP_GATED_DELTA_NET:\n            {\n                if (AGENTHQ_GENERIC_GPU(backend_ctx)) return false; // agenthq patch: kernels not built for this family, see (2)\n                // Match the Vulkan backend: only F32 -> F32, S_v in {16, 32, 64, 128}.\n"
  "gated_delta_net supports_op")

# (8) CL_CHECK aborts the whole process on any OpenCL error (SIGABRT). Throw instead:
#     the exception propagates out of graph compute to agenthq_llama.cpp's
#     safe_decode (AGENTHQ_ERR_DECODE) and to the self-test, which reports the
#     failing call and error code per op instead of killing the app.
_agenthq_replace(
  "            GGML_ASSERT(0);                                         \\"
  "            throw std::runtime_error(std::string(\"ggml_opencl: \") + #err + \" error \" + std::to_string(err_)); /* agenthq patch */ \\"
  "CL_CHECK abort -> throw")

# (9) kernel_rms_norm_mul / _mul_add reduce the per-subgroup partial sums with ONE
#     sub_group_reduce_add over sum[0..sgs), i.e. they assume <= sgs subgroups per
#     work-group (Intel: 1024/32 = 32 = sgs). With 16-wide subgroups a 1024-thread
#     group has 64 subgroups and 48 partial sums are silently dropped (self-test:
#     nmse 0.32 on [2560x4]). Cap the work-group at sgs*sgs threads (256).
set(_cap_wg "    if (AGENTHQ_GENERIC_GPU(backend_ctx)) max_workgroup_size = MIN(max_workgroup_size, (int) (sgs*sgs)); // agenthq patch: kernel sums at most sgs partial sums\n")
_agenthq_replace(
  "    cl_kernel kernel = backend_ctx->kernel_rms_norm_mul_add;\n\n    int nth = sgs;\n    int max_workgroup_size = backend_ctx->get_kernel_workgroup_size(kernel);\n"
  "    cl_kernel kernel = backend_ctx->kernel_rms_norm_mul_add;\n\n    int nth = sgs;\n    int max_workgroup_size = backend_ctx->get_kernel_workgroup_size(kernel);\n${_cap_wg}"
  "rms_norm_mul_add work-group cap")
_agenthq_replace(
  "    cl_kernel kernel = backend_ctx->kernel_rms_norm_mul;\n\n    int nth = sgs;\n    int max_workgroup_size = backend_ctx->get_kernel_workgroup_size(kernel);\n"
  "    cl_kernel kernel = backend_ctx->kernel_rms_norm_mul;\n\n    int nth = sgs;\n    int max_workgroup_size = backend_ctx->get_kernel_workgroup_size(kernel);\n${_cap_wg}"
  "rms_norm_mul work-group cap")

# (10) soft_max kernels have no work-group reduction: "local size must be wave
#      size" (one subgroup per row). Intel uses 32; a 32-thread group on a 16-wide
#      GPU is two subgroups that each normalise with half the sum (self-test:
#      nmse 1.0). Use the real subgroup size.
_agenthq_replace(
  "    if (backend_ctx->gpu_family == INTEL) {\n        // This is the same as the initial value.\n        nth = MIN(32, ne00);\n    }"
  "    if (backend_ctx->gpu_family == INTEL) {\n        // This is the same as the initial value.\n        nth = AGENTHQ_GENERIC_GPU(backend_ctx) ? MIN(16, ne00) : MIN(32, ne00); // agenthq patch: one 16-wide subgroup per row\n    }"
  "soft_max wave size")

# (11) name the failing op when a kernel launch is rejected (e.g. -54
#      CL_INVALID_WORK_GROUP_SIZE): the exception text then says which ggml op and
#      which global/local sizes were used, instead of only the CL call.
_agenthq_replace(
  "        GGML_UNUSED(tensor);\n        CL_CHECK(clEnqueueNDRangeKernel(queue, kernel, work_dim, NULL, global_work_size, local_work_size, 0, NULL, NULL));\n"
  "        const cl_int enq_err = clEnqueueNDRangeKernel(queue, kernel, work_dim, NULL, global_work_size, local_work_size, 0, NULL, NULL); // agenthq patch: named launch errors\n        if (enq_err != CL_SUCCESS) {\n            std::string msg = \"ggml_opencl: launch error \" + std::to_string(enq_err);\n            if (tensor) msg += std::string(\" op=\") + ggml_op_desc(tensor) + \" tensor=\" + tensor->name + \" ne=[\" + std::to_string(tensor->ne[0]) + \",\" + std::to_string(tensor->ne[1]) + \",\" + std::to_string(tensor->ne[2]) + \",\" + std::to_string(tensor->ne[3]) + \"]\";\n            msg += \" gws=\";\n            for (cl_uint i = 0; i < work_dim; i++) msg += (i ? \"x\" : \"\") + std::to_string(global_work_size[i]);\n            msg += \" lws=\";\n            if (local_work_size) { for (cl_uint i = 0; i < work_dim; i++) msg += (i ? \"x\" : \"\") + std::to_string(local_work_size[i]); } else msg += \"auto\";\n            msg += \" kernel_wg=\" + std::to_string(get_kernel_workgroup_size(kernel));\n            GGML_LOG_ERROR(\"%s\\n\", msg.c_str());\n            throw std::runtime_error(msg);\n        }\n"
  "named launch errors")

# (12) the Mali driver rejects a launch whose local size does not divide the global
#      size (e.g. ADD on a 16-element tensor: gws=4, lws=64 -> -54
#      CL_INVALID_WORK_GROUP_SIZE), although it reports non-uniform work-group
#      support. Kernels that need a fixed group (reductions) always launch whole
#      groups, so on a generic GPU an indivisible launch lets the driver choose.
_agenthq_replace(
  "        for (cl_uint i = 0; i < work_dim; i++) {\n            if (global_work_size[i] == 0) {\n                return;\n            }\n        }\n#ifdef GGML_OPENCL_PROFILING\n"
  "        for (cl_uint i = 0; i < work_dim; i++) {\n            if (global_work_size[i] == 0) {\n                return;\n            }\n        }\n        if (local_work_size && AGENTHQ_GENERIC_GPU(this)) { // agenthq patch: Mali rejects partial work-groups\n            for (cl_uint i = 0; i < work_dim; i++) {\n                if (local_work_size[i] == 0 || global_work_size[i] % local_work_size[i] != 0) { local_work_size = nullptr; break; }\n            }\n        }\n#ifdef GGML_OPENCL_PROFILING\n"
  "uniform work-groups on generic GPU")

# (13) flash_attn_ext with head size 256 (Qwen3.5) gives wrong results on Mali
#      (self-test nmse 3.4; head 128 is exact). Decline head sizes > 128 on a generic
#      GPU: llama.cpp's flash-attention "auto" then disables FA for that model and
#      uses mul_mat + soft_max, which are verified on the GPU.
_agenthq_replace(
  "            const int dk = q->ne[0];\n            const int dv = v->ne[0];\n\n            const struct { int dk; int dv; } supported_dims[] = {\n"
  "            const int dk = q->ne[0];\n            const int dv = v->ne[0];\n            if (AGENTHQ_GENERIC_GPU(backend_ctx) && (dk > 128 || dv > 128)) return false; // agenthq patch: FA head > 128 is wrong on Mali\n\n            const struct { int dk; int dv; } supported_dims[] = {\n"
  "flash_attn head > 128")

if (_n_applied EQUAL 0)
  message(STATUS "agenthq: ggml-opencl patch: nothing to do (${_n_skipped} hunks already applied)")
  return()
endif()
file(WRITE "${_file}" "${_content}")
message(STATUS "agenthq: ggml-opencl patch applied (${_n_applied} new, ${_n_skipped} already present) to ${_file}")
