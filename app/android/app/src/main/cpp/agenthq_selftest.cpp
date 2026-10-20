// GPU kernel self-test (agenthq_gpu_selftest): the ops a Qwen-style decoder
// needs are run on the CPU backend and on one GPU backend with identical inputs
// and compared per op (NMSE), like llama.cpp's test-backend-ops but callable from
// inside the app. A standalone test binary cannot be used on Android: only an app
// that declares <uses-native-library libOpenCL.so> may dlopen the vendor driver.
//
// It also measures the subgroup size the OpenCL driver really uses, because the
// Intel code paths reused on Mali (cmake/patch-ggml-opencl.cmake) hard-code 16 and
// size their per-subgroup scratch memory from it.
#include "agenthq_llama.h"
#include "agenthq_internal.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"

#ifdef AGENTHQ_HAVE_OPENCL
#include <CL/cl.h>
#endif

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace {

// Mirrors the report to logcat (tag agenthq_selftest) so results survive even if
// the UI is not visible or the process dies half-way through.
void log_line(const std::string& line) {
#ifdef __ANDROID__
    __android_log_write(ANDROID_LOG_INFO, "agenthq_selftest", line.c_str());
#else
    fprintf(stderr, "%s\n", line.c_str());
#endif
}

using clock_t_ = std::chrono::steady_clock;
double ms_since(clock_t_::time_point t0) {
    return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}

// Deterministic uniform [-1, 1) generator so both backends see the same data.
struct Lcg {
    uint64_t s;
    float next() {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        return ((s >> 40) & 0xFFFFFF) / float(0xFFFFFF) * 2.0f - 1.0f;
    }
};

// Fills an allocated input tensor from `seed`: floats uniform [-1, 1) (quantized
// row-wise for quant types), I32 tensors get 0, 1, 2, ... (positions / row ids).
void fill_tensor(ggml_tensor* t, uint64_t seed) {
    const int64_t n = ggml_nelements(t);
    if (t->type == GGML_TYPE_I32) {
        std::vector<int32_t> v(n);
        for (int64_t i = 0; i < n; i++) v[i] = (int32_t) i;
        ggml_backend_tensor_set(t, v.data(), 0, ggml_nbytes(t));
        return;
    }
    Lcg rng{seed * 0x9E3779B97F4A7C15ULL + 7};
    std::vector<float> f(n);
    for (auto& x : f) x = rng.next();
    if (t->type == GGML_TYPE_F32) {
        ggml_backend_tensor_set(t, f.data(), 0, ggml_nbytes(t));
    } else if (t->type == GGML_TYPE_F16) {
        std::vector<ggml_fp16_t> h(n);
        ggml_fp32_to_fp16_row(f.data(), h.data(), n);
        ggml_backend_tensor_set(t, h.data(), 0, ggml_nbytes(t));
    } else {
        std::vector<uint8_t> q(ggml_nbytes(t));
        const int64_t n_per_row = t->ne[0];
        ggml_quantize_chunk(t->type, f.data(), q.data(), 0, n / n_per_row, n_per_row, nullptr);
        ggml_backend_tensor_set(t, q.data(), 0, q.size());
    }
}

ggml_tensor* in(ggml_context* ctx, ggml_type type, int64_t ne0, int64_t ne1 = 1, int64_t ne2 = 1, int64_t ne3 = 1) {
    ggml_tensor* t = ggml_new_tensor_4d(ctx, type, ne0, ne1, ne2, ne3);
    ggml_set_input(t);
    return t;
}

struct Case {
    const char* name;
    double tol;  // max NMSE vs the CPU result
    std::function<ggml_tensor*(ggml_context*)> build;
};

struct RunResult {
    std::vector<float> out;
    double ms = 0;
    bool supported = true;
    std::string error;
};

RunResult run_case(const Case& c, ggml_backend_t backend, ggml_backend_dev_t support_dev) {
    RunResult r;
    ggml_init_params ip = {ggml_tensor_overhead() * 64 + ggml_graph_overhead(), nullptr, true};
    ggml_context* ctx = ggml_init(ip);
    ggml_backend_buffer_t buf = nullptr;
    try {
        ggml_tensor* out = c.build(ctx);
        ggml_set_output(out);
        if (support_dev) {
            for (ggml_tensor* t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) {
                if (t->op != GGML_OP_NONE && !ggml_backend_dev_supports_op(support_dev, t)) {
                    r.supported = false;
                    r.error = std::string("op ") + ggml_op_desc(t) + " tidak didukung backend GPU ini (ggml menjalankannya di CPU)";
                }
            }
            if (!r.supported) { ggml_free(ctx); return r; }
        }
        buf = ggml_backend_alloc_ctx_tensors(ctx, backend);
        if (!buf) throw std::runtime_error("alokasi buffer gagal");
        uint64_t seed = 1;
        for (ggml_tensor* t = ggml_get_first_tensor(ctx); t; t = ggml_get_next_tensor(ctx, t)) {
            if (t->flags & GGML_TENSOR_FLAG_INPUT) fill_tensor(t, seed++);
        }
        ggml_cgraph* gf = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, out);
        // First run pays kernel-compile / first-use costs; the second one is timed.
        if (ggml_backend_graph_compute(backend, gf) != GGML_STATUS_SUCCESS) throw std::runtime_error("graph_compute gagal");
        ggml_backend_synchronize(backend);
        const auto t0 = clock_t_::now();
        if (ggml_backend_graph_compute(backend, gf) != GGML_STATUS_SUCCESS) throw std::runtime_error("graph_compute gagal (run 2)");
        ggml_backend_synchronize(backend);
        r.ms = ms_since(t0);

        const int64_t n = ggml_nelements(out);
        r.out.resize(n);
        if (out->type == GGML_TYPE_F32) {
            ggml_backend_tensor_get(out, r.out.data(), 0, ggml_nbytes(out));
        } else if (out->type == GGML_TYPE_F16) {
            std::vector<ggml_fp16_t> h(n);
            ggml_backend_tensor_get(out, h.data(), 0, ggml_nbytes(out));
            ggml_fp16_to_fp32_row(h.data(), r.out.data(), n);
        } else {
            throw std::runtime_error(std::string("tipe output tidak didukung: ") + ggml_type_name(out->type));
        }
    } catch (const std::exception& e) {
        r.error = e.what();
    } catch (...) {
        r.error = "exception tak dikenal";
    }
    if (buf) ggml_backend_buffer_free(buf);
    ggml_free(ctx);
    return r;
}

double nmse(const std::vector<float>& ref, const std::vector<float>& got) {
    if (ref.empty() || ref.size() != got.size()) return INFINITY;
    double num = 0, den = 0;
    for (size_t i = 0; i < ref.size(); i++) {
        if (!std::isfinite(got[i])) return INFINITY;
        const double d = (double) ref[i] - got[i];
        num += d * d;
        den += (double) ref[i] * ref[i];
    }
    return den > 0 ? num / den : num;
}

// Shapes follow Qwen3-4B: n_embd 2560, head_dim 128, 32 heads / 8 KV heads, ffn 9728.
std::vector<Case> make_cases() {
    const int64_t E = 2560;
    const float eps = 1e-6f;
    return {
        {"mul_mat q4_K [2560x512]·[2560x1] (gemv, 1 token)", 5e-4,
         [=](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_Q4_K, E, 512), in(c, GGML_TYPE_F32, E, 1)); }},
        {"mul_mat q4_K [2560x512]·[2560x8] (prompt 8 token)", 5e-4,
         [=](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_Q4_K, E, 512), in(c, GGML_TYPE_F32, E, 8)); }},
        {"mul_mat q4_K [2560x9728]·[2560x1] (ffn)", 5e-4,
         [=](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_Q4_K, E, 9728), in(c, GGML_TYPE_F32, E, 1)); }},
        {"mul_mat q6_K [2560x512]·[2560x1]", 5e-4,
         [=](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_Q6_K, E, 512), in(c, GGML_TYPE_F32, E, 1)); }},
        {"mul_mat q8_0 [2560x512]·[2560x4]", 5e-4,
         [=](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_Q8_0, E, 512), in(c, GGML_TYPE_F32, E, 4)); }},
        {"mul_mat f16 [2560x256]·[2560x4]", 1e-4,
         [=](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_F16, E, 256), in(c, GGML_TYPE_F32, E, 4)); }},
        {"mul_mat f32 [128x64]·[128x64]", 1e-5,
         [](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_F32, 128, 64), in(c, GGML_TYPE_F32, 128, 64)); }},
        {"rms_norm [2560x4]", 1e-5,
         [=](ggml_context* c) { return ggml_rms_norm(c, in(c, GGML_TYPE_F32, E, 4), eps); }},
        {"rms_norm·w [2560x4] (fused)", 1e-5,
         [=](ggml_context* c) { return ggml_mul(c, ggml_rms_norm(c, in(c, GGML_TYPE_F32, E, 4), eps), in(c, GGML_TYPE_F32, E, 1)); }},
        {"rms_norm·w [128x32x4] (q/k norm)", 1e-5,
         [=](ggml_context* c) { return ggml_mul(c, ggml_rms_norm(c, in(c, GGML_TYPE_F32, 128, 32, 4), eps), in(c, GGML_TYPE_F32, 128, 1)); }},
        {"norm [2560x4]", 1e-5,
         [=](ggml_context* c) { return ggml_norm(c, in(c, GGML_TYPE_F32, E, 4), eps); }},
        {"soft_max_ext [512x8x8] + mask f32", 1e-5,
         [](ggml_context* c) { return ggml_soft_max_ext(c, in(c, GGML_TYPE_F32, 512, 8, 8), in(c, GGML_TYPE_F32, 512, 8), 0.088f, 0.0f); }},
        {"soft_max_ext [512x8x8] + mask f16", 1e-4,
         [](ggml_context* c) { return ggml_soft_max_ext(c, in(c, GGML_TYPE_F32, 512, 8, 8), in(c, GGML_TYPE_F16, 512, 8), 0.088f, 0.0f); }},
        {"rope neox [128x32x4]", 1e-5,
         [](ggml_context* c) {
             return ggml_rope_ext(c, in(c, GGML_TYPE_F32, 128, 32, 4), in(c, GGML_TYPE_I32, 4), nullptr, 128, GGML_ROPE_TYPE_NEOX,
                                  40960, 1000000.0f, 1.0f, 0.0f, 1.0f, 0.0f, 0.0f);
         }},
        {"flash_attn_ext q[128x4x32] k/v f16 [128x64x8]", 5e-4,
         [](ggml_context* c) {
             ggml_tensor* q = in(c, GGML_TYPE_F32, 128, 4, 32);
             ggml_tensor* k = in(c, GGML_TYPE_F16, 128, 64, 8);
             ggml_tensor* v = in(c, GGML_TYPE_F16, 128, 64, 8);
             return ggml_flash_attn_ext(c, q, k, v, nullptr, 1.0f / sqrtf(128.0f), 0.0f, 0.0f);
         }},
        {"mul [2560x4]·[2560x1] (broadcast)", 1e-6,
         [=](ggml_context* c) { return ggml_mul(c, in(c, GGML_TYPE_F32, E, 4), in(c, GGML_TYPE_F32, E, 1)); }},
        {"add [2560x4]+[2560x4]", 1e-6,
         [=](ggml_context* c) { return ggml_add(c, in(c, GGML_TYPE_F32, E, 4), in(c, GGML_TYPE_F32, E, 4)); }},
        {"add [16]+[16] (tensor kecil, Qwen3.5)", 1e-6,
         [](ggml_context* c) { return ggml_add(c, in(c, GGML_TYPE_F32, 16), in(c, GGML_TYPE_F32, 16)); }},
        {"mul [100x3]·[100x1] (ukuran ganjil)", 1e-6,
         [](ggml_context* c) { return ggml_mul(c, in(c, GGML_TYPE_F32, 100, 3), in(c, GGML_TYPE_F32, 100, 1)); }},
        {"silu [9728x4]", 1e-6,
         [](ggml_context* c) { return ggml_silu(c, in(c, GGML_TYPE_F32, 9728, 4)); }},
        {"swiglu [9728x4]", 1e-6,
         [](ggml_context* c) { return ggml_swiglu_split(c, in(c, GGML_TYPE_F32, 9728, 4), in(c, GGML_TYPE_F32, 9728, 4)); }},
        {"get_rows q4_K [2560x1024] 4 baris (embedding)", 1e-6,
         [=](ggml_context* c) { return ggml_get_rows(c, in(c, GGML_TYPE_Q4_K, E, 1024), in(c, GGML_TYPE_I32, 4)); }},
        {"cpy f32→f16 [128x64] (KV cache)", 1e-6,
         [](ggml_context* c) { return ggml_cpy(c, in(c, GGML_TYPE_F32, 128, 64), in(c, GGML_TYPE_F16, 128, 64)); }},
        {"scale [2560x4]", 1e-6,
         [=](ggml_context* c) { return ggml_scale(c, in(c, GGML_TYPE_F32, E, 4), 0.5f); }},

        // --- Qwen3.5 (hybrid Gated DeltaNet): n_embd 2048, head_dim 256, partial IMRoPE ---
        {"mul_mat q4_K [2048x512]·[2048x1] (Qwen3.5)", 5e-4,
         [](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_Q4_K, 2048, 512), in(c, GGML_TYPE_F32, 2048, 1)); }},
        {"rms_norm·w [256x8x1] (head 256)", 1e-5,
         [=](ggml_context* c) { return ggml_mul(c, ggml_rms_norm(c, in(c, GGML_TYPE_F32, 256, 8, 1), eps), in(c, GGML_TYPE_F32, 256, 1)); }},
        {"rms_norm·w [2048x1] (1 token)", 1e-5,
         [=](ggml_context* c) { return ggml_mul(c, ggml_rms_norm(c, in(c, GGML_TYPE_F32, 2048, 1), eps), in(c, GGML_TYPE_F32, 2048, 1)); }},
        {"rope_multi imrope [256x8x1] n_rot 64", 1e-5,
         [](ggml_context* c) {
             int sections[GGML_MROPE_SECTIONS] = {11, 11, 10, 0};
             return ggml_rope_multi(c, in(c, GGML_TYPE_F32, 256, 8, 1), in(c, GGML_TYPE_I32, 4), nullptr, 64, sections,
                                    GGML_ROPE_TYPE_IMROPE, 262144, 10000000.0f, 1.0f, 0.0f, 1.0f, 0.0f, 0.0f);
         }},
        {"flash_attn_ext head 256 q[256x1x8] kv f16 [256x64x2]", 5e-4,
         [](ggml_context* c) {
             return ggml_flash_attn_ext(c, in(c, GGML_TYPE_F32, 256, 1, 8), in(c, GGML_TYPE_F16, 256, 64, 2),
                                        in(c, GGML_TYPE_F16, 256, 64, 2), nullptr, 1.0f / 16.0f, 0.0f, 0.0f);
         }},
        {"attn tanpa FA: KQ f16 [256x64x2]·[256x1x8]", 1e-4,
         [](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_F16, 256, 64, 2), in(c, GGML_TYPE_F32, 256, 1, 8)); }},
        {"attn tanpa FA: softmax [64x1x8] + mask f16", 1e-4,
         [](ggml_context* c) { return ggml_soft_max_ext(c, in(c, GGML_TYPE_F32, 64, 1, 8), in(c, GGML_TYPE_F16, 64, 1), 1.0f / 16.0f, 0.0f); }},
        {"attn tanpa FA: KQV f16 [64x256x2]·[64x1x8]", 1e-4,
         [](ggml_context* c) { return ggml_mul_mat(c, in(c, GGML_TYPE_F16, 64, 256, 2), in(c, GGML_TYPE_F32, 64, 1, 8)); }},
        {"ssm_conv [4x1024x1]*[4x1024]", 1e-5,
         [](ggml_context* c) { return ggml_ssm_conv(c, in(c, GGML_TYPE_F32, 4, 1024, 1), in(c, GGML_TYPE_F32, 4, 1024)); }},
        {"l2_norm [128x16]", 1e-5,
         [](ggml_context* c) { return ggml_l2_norm(c, in(c, GGML_TYPE_F32, 128, 16), 1e-6f); }},
        {"sigmoid [1024x4]", 1e-6,
         [](ggml_context* c) { return ggml_sigmoid(c, in(c, GGML_TYPE_F32, 1024, 4)); }},
        {"softplus [1024x4]", 1e-6,
         [](ggml_context* c) { return ggml_softplus(c, in(c, GGML_TYPE_F32, 1024, 4)); }},
        {"exp [1024x4]", 1e-6,
         [](ggml_context* c) { return ggml_exp(c, in(c, GGML_TYPE_F32, 1024, 4)); }},
        {"neg [1024x4]", 1e-6,
         [](ggml_context* c) { return ggml_neg(c, in(c, GGML_TYPE_F32, 1024, 4)); }},
        {"sub [1024x4]-[1024x4]", 1e-6,
         [](ggml_context* c) { return ggml_sub(c, in(c, GGML_TYPE_F32, 1024, 4), in(c, GGML_TYPE_F32, 1024, 4)); }},
        {"concat dim0 [3x1024]+[1x1024]", 1e-6,
         [](ggml_context* c) { return ggml_concat(c, in(c, GGML_TYPE_F32, 3, 1024), in(c, GGML_TYPE_F32, 1, 1024), 0); }},
        {"cont(transpose) [1024x4]", 1e-6,
         [](ggml_context* c) { return ggml_cont(c, ggml_transpose(c, in(c, GGML_TYPE_F32, 1024, 4))); }},
        {"cont(permute) [256x8x4]", 1e-6,
         [](ggml_context* c) { return ggml_cont(c, ggml_permute(c, in(c, GGML_TYPE_F32, 256, 8, 4), 0, 2, 1, 3)); }},
        {"pad [100x3] +28", 1e-6,
         [](ggml_context* c) { return ggml_pad(c, in(c, GGML_TYPE_F32, 100, 3), 28, 0, 0, 0); }},
        {"repeat_4d [128x2x1] → [128x2x8]", 1e-6,
         [](ggml_context* c) { return ggml_repeat_4d(c, in(c, GGML_TYPE_F32, 128, 2, 1), 128, 2, 8, 1); }},
        {"sum_rows [512x16]", 1e-6,
         [](ggml_context* c) { return ggml_sum_rows(c, in(c, GGML_TYPE_F32, 512, 16)); }},
        {"cumsum [64x16]", 1e-6,
         [](ggml_context* c) { return ggml_cumsum(c, in(c, GGML_TYPE_F32, 64, 16)); }},
        {"tri lower [64x64]", 1e-6,
         [](ggml_context* c) { return ggml_tri(c, in(c, GGML_TYPE_F32, 64, 64), GGML_TRI_TYPE_LOWER); }},
        {"get_rows f32 [1024x8] 4 baris", 1e-6,
         [](ggml_context* c) { return ggml_get_rows(c, in(c, GGML_TYPE_F32, 1024, 8), in(c, GGML_TYPE_I32, 4)); }},
    };
}

void append_num(std::string& json, double v) {
    char buf[32];
    if (!std::isfinite(v)) { json += "null"; return; }
    snprintf(buf, sizeof buf, "%.4g", v);
    json += buf;
}

// Subgroup sizes the OpenCL driver really uses for a trivial kernel: the static
// query per work-group size and the value read back from a running kernel.
std::string probe_subgroups(int backend) {
    std::string json = "{";
#ifdef AGENTHQ_HAVE_OPENCL
    if (backend != AGENTHQ_BACKEND_OPENCL) { json += "\"error\":\"hanya OpenCL\"}"; return json; }
    cl_platform_id plat = nullptr;
    cl_device_id dev = nullptr;
    cl_uint n = 0;
    std::string error;
    cl_context ctx = nullptr;
    cl_command_queue q = nullptr;
    cl_program prog = nullptr;
    cl_kernel k = nullptr;
    cl_mem buf = nullptr;
    size_t max_wg = 0, kernel_wg = 0;
    std::string ndrange = "{", runtime = "{";
    do {
        if (clGetPlatformIDs(1, &plat, &n) != CL_SUCCESS || n == 0) { error = "clGetPlatformIDs"; break; }
        if (clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, &n) != CL_SUCCESS || n == 0) { error = "clGetDeviceIDs"; break; }
        clGetDeviceInfo(dev, CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof max_wg, &max_wg, nullptr);
        cl_int err = 0;
        ctx = clCreateContext(nullptr, 1, &dev, nullptr, nullptr, &err);
        if (!ctx) { error = "clCreateContext " + std::to_string(err); break; }
        q = clCreateCommandQueue(ctx, dev, 0, &err);
        if (!q) { error = "clCreateCommandQueue " + std::to_string(err); break; }
        const char* src =
            "#pragma OPENCL EXTENSION cl_khr_subgroups : enable\n"
            "kernel void k(global int* o) { if (get_local_id(0) == 0) o[get_group_id(0)] = get_sub_group_size(); }\n";
        prog = clCreateProgramWithSource(ctx, 1, &src, nullptr, &err);
        if (!prog) { error = "clCreateProgramWithSource " + std::to_string(err); break; }
        if (clBuildProgram(prog, 1, &dev, "-cl-std=CL3.0", nullptr, nullptr) != CL_SUCCESS &&
            clBuildProgram(prog, 1, &dev, "-cl-std=CL2.0", nullptr, nullptr) != CL_SUCCESS) {
            char log[2048] = {0};
            clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof log - 1, log, nullptr);
            error = std::string("clBuildProgram: ") + log;
            break;
        }
        k = clCreateKernel(prog, "k", &err);
        if (!k) { error = "clCreateKernel " + std::to_string(err); break; }
        clGetKernelWorkGroupInfo(k, dev, CL_KERNEL_WORK_GROUP_SIZE, sizeof kernel_wg, &kernel_wg, nullptr);
        const size_t sizes[] = {16, 32, 64, 128, 256, 512, 1024};
        bool first = true;
        for (size_t ls : sizes) {
            if (ls > max_wg) break;
            size_t sg = 0;
            const cl_int e = clGetKernelSubGroupInfo(k, dev, CL_KERNEL_MAX_SUB_GROUP_SIZE_FOR_NDRANGE, sizeof ls, &ls, sizeof sg, &sg, nullptr);
            if (!first) ndrange += ",";
            first = false;
            ndrange += "\"" + std::to_string(ls) + "\":" + (e == CL_SUCCESS ? std::to_string(sg) : std::string("null"));
        }
        buf = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sizeof(cl_int) * 16, nullptr, &err);
        if (!buf) { error = "clCreateBuffer " + std::to_string(err); break; }
        clSetKernelArg(k, 0, sizeof buf, &buf);
        const size_t run_sizes[] = {16, 64, 256, 1024};
        first = true;
        for (size_t ls : run_sizes) {
            if (ls > max_wg || ls > kernel_wg) break;
            const size_t gws = ls * 2;
            cl_int out[16] = {0};
            cl_int e = clEnqueueNDRangeKernel(q, k, 1, nullptr, &gws, &ls, 0, nullptr, nullptr);
            if (e == CL_SUCCESS) e = clFinish(q);
            if (e == CL_SUCCESS) e = clEnqueueReadBuffer(q, buf, CL_TRUE, 0, sizeof out, out, 0, nullptr, nullptr);
            if (!first) runtime += ",";
            first = false;
            runtime += "\"" + std::to_string(ls) + "\":" + (e == CL_SUCCESS ? std::to_string(out[0]) : std::string("null"));
        }
    } while (false);
    ndrange += "}";
    runtime += "}";
    if (buf) clReleaseMemObject(buf);
    if (k) clReleaseKernel(k);
    if (prog) clReleaseProgram(prog);
    if (q) clReleaseCommandQueue(q);
    if (ctx) clReleaseContext(ctx);
    json += "\"max_wg\":" + std::to_string(max_wg) + ",\"kernel_wg\":" + std::to_string(kernel_wg);
    json += ",\"ndrange\":" + ndrange + ",\"runtime\":" + runtime;
    std::string esc;
    agenthq_internal_json_escape(error.c_str(), esc);
    json += ",\"error\":\"" + esc + "\"}";
#else
    (void) backend;
    json += "\"error\":\"OpenCL tidak dikompilasi\"}";
#endif
    return json;
}

}  // namespace

extern "C" int agenthq_gpu_selftest(int backend, char* out, int cap) {
    if (!out || cap <= 0) { agenthq_internal_set_error("out buffer is null/empty"); return AGENTHQ_ERR_INVALID_ARG; }
    if (backend != AGENTHQ_BACKEND_VULKAN && backend != AGENTHQ_BACKEND_OPENCL) {
        agenthq_internal_set_error("gpu_selftest: backend must be 1 (vulkan) or 2 (opencl)");
        return AGENTHQ_ERR_INVALID_ARG;
    }
    const char* backend_str = backend == AGENTHQ_BACKEND_OPENCL ? "opencl" : "vulkan";

    std::string reason, device;
    ggml_backend_dev_t dev = nullptr;
    try {
        dev = agenthq_internal_find_device(backend, reason);
    } catch (const std::exception& e) {
        reason = std::string("Inisialisasi gagal: ") + e.what();
    } catch (...) {
        reason = "Inisialisasi gagal";
    }

    std::string json = "{\"available\":";
    json += dev ? "true" : "false";
    json += ",\"backend\":\"";
    json += backend_str;
    json += "\",\"device\":\"";
    if (dev) agenthq_internal_json_escape(ggml_backend_dev_description(dev), device);
    json += device;
    json += "\",\"reason\":\"";
    std::string esc;
    agenthq_internal_json_escape(reason.c_str(), esc);
    json += esc;
    json += "\",\"subgroup\":";
    const std::string subgroup = dev ? probe_subgroups(backend) : "{}";
    json += subgroup;
    json += ",\"tests\":[";
    log_line(std::string("selftest ") + backend_str + " device='" + device + "' reason='" + reason + "' subgroup=" + subgroup);

    if (dev) {
        ggml_backend_t gpu = nullptr;
        ggml_backend_t cpu = ggml_backend_cpu_init();
        ggml_backend_cpu_set_n_threads(cpu, 4);
        try {
            gpu = ggml_backend_dev_init(dev, nullptr);
        } catch (...) {
            gpu = nullptr;
        }
        bool first = true;
        for (const Case& c : make_cases()) {
            RunResult ref = run_case(c, cpu, nullptr);
            RunResult got;
            if (gpu) {
                got = run_case(c, gpu, dev);
            } else {
                got.error = "backend GPU gagal diinisialisasi";
            }
            const double err = (ref.error.empty() && got.error.empty() && got.supported) ? nmse(ref.out, got.out) : INFINITY;
            const bool ok = got.supported && got.error.empty() && ref.error.empty() && err <= c.tol;
            {
                char line[512];
                snprintf(line, sizeof line, "%-6s %-48s nmse=%.3g tol=%.0e gpu=%.1fms cpu=%.1fms %s",
                         !got.supported ? "CPU" : (!got.error.empty() || !ref.error.empty()) ? "GAGAL" : (ok ? "OK" : "SALAH"),
                         c.name, err, c.tol, got.ms, ref.ms, (got.error.empty() ? ref.error : got.error).c_str());
                log_line(line);
            }
            if (!first) json += ",";
            first = false;
            std::string name_esc, err_esc;
            agenthq_internal_json_escape(c.name, name_esc);
            agenthq_internal_json_escape((got.error.empty() ? ref.error : got.error).c_str(), err_esc);
            json += "{\"op\":\"" + name_esc + "\",\"nmse\":";
            append_num(json, err);
            json += ",\"tol\":";
            append_num(json, c.tol);
            json += ",\"ok\":";
            json += ok ? "true" : "false";
            json += ",\"supported\":";
            json += got.supported ? "true" : "false";
            json += ",\"gpu_ms\":";
            append_num(json, got.ms);
            json += ",\"cpu_ms\":";
            append_num(json, ref.ms);
            json += ",\"error\":\"" + err_esc + "\"}";
        }
        if (gpu) ggml_backend_free(gpu);
        ggml_backend_free(cpu);
    }
    json += "]}";

    if ((int) json.size() + 1 > cap) {
        char buf[96];
        snprintf(buf, sizeof buf, "gpu_selftest needs %d bytes, buffer has %d", (int) json.size() + 1, cap);
        agenthq_internal_set_error(buf);
        return AGENTHQ_ERR_BUFFER_SMALL;
    }
    memcpy(out, json.c_str(), json.size() + 1);
    return (int) json.size();
}
