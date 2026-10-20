#include "agenthq_llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "llama.h"

#ifdef AGENTHQ_HAVE_VULKAN
#include "ggml-vulkan.h"
#endif
#ifdef AGENTHQ_HAVE_OPENCL
#include "ggml-opencl.h"
#include <CL/cl.h>
#endif

#ifdef __ANDROID__
#include <android/log.h>
#endif

#if defined(AGENTHQ_HAVE_VULKAN) && defined(__ANDROID__)
#include <dlfcn.h>
#include <vulkan/vulkan_core.h>

// ggml-vulkan calls vkGetPhysicalDeviceFeatures2 (Vulkan 1.1 core) directly
// instead of through its dynamic dispatcher, but Android's libvulkan.so only
// exports it from API 28, and the app links against the API 26 stub. This
// definition is hidden (-fvisibility=hidden) so the linker binds ggml's
// references here; at runtime it forwards to the loader's symbol when present
// (Android 9+), otherwise falls back to the 1.0 query (no pNext chain) — such
// a device cannot offer Vulkan 1.2 anyway and ggml rejects it later.
extern "C" VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice device,
                                                                   VkPhysicalDeviceFeatures2* features) {
    static PFN_vkGetPhysicalDeviceFeatures2 real = [] {
        void* sym = dlsym(RTLD_DEFAULT, "vkGetPhysicalDeviceFeatures2");
        if (!sym) sym = dlsym(RTLD_DEFAULT, "vkGetPhysicalDeviceFeatures2KHR");
        return reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(sym);
    }();
    if (real) {
        real(device, features);
    } else if (features) {
        vkGetPhysicalDeviceFeatures(device, &features->features);
    }
}
#endif

namespace {

constexpr const char* kLogTag = "agenthq_llama";
constexpr uint32_t kSeed = 42;

std::mutex g_mu;  // guards everything below except g_stop
llama_model*   g_model = nullptr;
llama_context* g_ctx   = nullptr;
llama_sampler* g_smpl  = nullptr;
const llama_vocab* g_vocab = nullptr;

bool g_generating = false;
int  g_max_tokens = 0;
int  g_n_gen      = 0;
int  g_n_past     = 0;
int  g_n_batch    = 512;
int  g_gpu_layers = 0;  // layers actually offloaded by the loaded model
int  g_backend    = AGENTHQ_BACKEND_CPU;  // backend of the offloaded layers
int  g_n_layer    = 0;  // n_layer of the loaded model

std::atomic<bool> g_stop{false};

std::mutex  g_err_mu;
std::string g_err;

double g_load_ms = 0, g_prompt_ms = 0, g_gen_ms = 0;
int    g_prompt_tokens = 0, g_gen_tokens = 0;
std::chrono::steady_clock::time_point g_gen_t0;

using clock_t_ = std::chrono::steady_clock;
double ms_since(clock_t_::time_point t0) {
    return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}

void set_error(const std::string& msg) {
    std::lock_guard<std::mutex> lk(g_err_mu);
    g_err = msg;
}

int fail(int code, const std::string& msg) {
    set_error(msg);
    return code;
}

void log_cb(ggml_log_level level, const char* text, void* /*user*/) {
#ifdef __ANDROID__
    int prio = ANDROID_LOG_INFO;
    if (level == GGML_LOG_LEVEL_DEBUG) prio = ANDROID_LOG_DEBUG;
    std::string line(text ? text : "");
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
    if (!line.empty()) __android_log_write(prio, kLogTag, line.c_str());
#else
    (void) level;
    if (text) fputs(text, stderr);
#endif
}

void backend_init_once() {
    static std::once_flag once;
    std::call_once(once, [] {
        // Mali/Android: the loader returns NULL for vkGetBufferDeviceAddress although the
        // device advertises the feature; ggml would crash on its first host buffer.
        // Read by the patched ggml-vulkan.cpp (cmake/patch-ggml-vulkan.cmake).
        setenv("GGML_VK_DISABLE_BDA", "1", 0);
#if defined(AGENTHQ_HAVE_OPENCL) && defined(__ANDROID__)
        // The statically linked Khronos ICD loader looks for .icd files in
        // /system/vendor/Khronos/OpenCL/vendors (absent on most phones) and for the
        // colon-separated OCL_ICD_FILENAMES list. The bare soname is resolved by the
        // Android linker through the vendor namespace because libOpenCL.so is listed
        // in /vendor/etc/public.libraries.txt; an absolute /vendor/lib64 path would be
        // rejected by the app's linker namespace. Must run before the first CL call
        // (the loader enumerates vendors once, and ggml caches its device probe).
        setenv("OCL_ICD_FILENAMES", "libOpenCL.so", 0);
        // Without a cache dir ggml tries std::filesystem::temp_directory_path(), which
        // is /tmp on Bionic and does not exist -> cache silently disabled.
        if (getenv("GGML_OPENCL_KERNEL_CACHE_DIR") == nullptr) setenv("GGML_OPENCL_KERNEL_CACHE_DIR", "off", 0);
#endif
        llama_log_set(log_cb, nullptr);
        llama_backend_init();
    });
}

void free_sampler() {
    if (g_smpl) { llama_sampler_free(g_smpl); g_smpl = nullptr; }
}

void finish_generation() {
    if (g_generating) {
        g_gen_ms = ms_since(g_gen_t0);
        g_gen_tokens = g_n_gen;
    }
    g_generating = false;
}

void unload_locked() {
    finish_generation();
    free_sampler();
    if (g_ctx)   { llama_free(g_ctx);         g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    g_vocab = nullptr;
    g_gpu_layers = 0;
    g_backend = AGENTHQ_BACKEND_CPU;
    g_n_layer = 0;
}

// Highest VkPhysicalDevice apiVersion on this device, or 0 when Vulkan is unusable.
// ggml-vulkan needs core Vulkan 1.2 (timeline semaphores, buffer device address);
// on 1.1 drivers (e.g. Mali-G610 on Infinix X6871) the loader hands ggml NULL
// function pointers and it segfaults, so we refuse before ggml ever initialises.
uint32_t vulkan_device_api_version() {
#if defined(AGENTHQ_HAVE_VULKAN) && defined(__ANDROID__)
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "agenthq-probe";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = &app;
    VkInstance inst = VK_NULL_HANDLE;
    if (vkCreateInstance(&ci, nullptr, &inst) != VK_SUCCESS || inst == VK_NULL_HANDLE) return 0;
    uint32_t count = 0;
    uint32_t best = 0;
    if (vkEnumeratePhysicalDevices(inst, &count, nullptr) == VK_SUCCESS && count > 0) {
        std::vector<VkPhysicalDevice> devs(count);
        if (vkEnumeratePhysicalDevices(inst, &count, devs.data()) == VK_SUCCESS) {
            for (uint32_t i = 0; i < count; i++) {
                VkPhysicalDeviceProperties props{};
                vkGetPhysicalDeviceProperties(devs[i], &props);
                best = std::max(best, props.apiVersion);
            }
        }
    }
    vkDestroyInstance(inst, nullptr);
    return best;
#else
    return 0;
#endif
}

std::string vulkan_version_string(uint32_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%u.%u", VK_VERSION_MAJOR(v), VK_VERSION_MINOR(v));
    return buf;
}

const char* backend_name(int backend) {
    switch (backend) {
        case AGENTHQ_BACKEND_VULKAN: return "vulkan";
        case AGENTHQ_BACKEND_OPENCL: return "opencl";
        default:                     return "cpu";
    }
}

// OpenCL driver probe through the ICD loader (no ggml involved): number of
// platforms, and the first GPU device's CL_DEVICE_VERSION ("OpenCL 3.0 ...")
// trimmed to "OpenCL X.Y". 0 platforms = no vendor library could be loaded.
unsigned opencl_platform_count(std::string* version_out) {
#ifdef AGENTHQ_HAVE_OPENCL
    cl_uint n = 0;
    if (clGetPlatformIDs(0, nullptr, &n) != CL_SUCCESS) return 0;
    if (version_out && n > 0) {
        std::vector<cl_platform_id> plats(n);
        if (clGetPlatformIDs(n, plats.data(), nullptr) == CL_SUCCESS) {
            for (cl_platform_id p : plats) {
                cl_device_id dev = nullptr;
                cl_uint nd = 0;
                if (clGetDeviceIDs(p, CL_DEVICE_TYPE_GPU, 1, &dev, &nd) != CL_SUCCESS || nd == 0) continue;
                char buf[128] = {0};
                if (clGetDeviceInfo(dev, CL_DEVICE_VERSION, sizeof buf - 1, buf, nullptr) == CL_SUCCESS) {
                    std::string v(buf);
                    // "OpenCL 3.0 v1.r38p1-01eac0..." -> "OpenCL 3.0"
                    size_t sp = v.find(' ');
                    if (sp != std::string::npos) sp = v.find(' ', sp + 1);
                    *version_out = sp == std::string::npos ? v : v.substr(0, sp);
                }
                break;
            }
        }
    }
    return n;
#else
    (void) version_out;
    return 0;
#endif
}

// First GPU/iGPU device of ONE backend's registry, or nullptr with `reason`
// (Indonesian UI text) set. The global ggml registry is deliberately not used:
// enumerating it would initialise every compiled-in backend, and ggml-vulkan
// must never be touched on a Vulkan 1.1 driver (see vulkan_device_api_version).
// Callers probe Vulkan's apiVersion first; this function may throw.
ggml_backend_dev_t find_backend_device(int backend, std::string& reason) {
    ggml_backend_reg_t reg = nullptr;
    switch (backend) {
        case AGENTHQ_BACKEND_VULKAN:
#ifdef AGENTHQ_HAVE_VULKAN
            reg = ggml_backend_vk_reg();
            if (!reg) { reason = "Inisialisasi Vulkan gagal"; return nullptr; }
#else
            reason = "Backend Vulkan tidak dikompilasi ke libagenthq_llama.so";
            return nullptr;
#endif
            break;
        case AGENTHQ_BACKEND_OPENCL:
#ifdef AGENTHQ_HAVE_OPENCL
            if (opencl_platform_count(nullptr) == 0) { reason = "Driver OpenCL tidak ditemukan"; return nullptr; }
            reg = ggml_backend_opencl_reg();
            if (!reg) { reason = "Inisialisasi OpenCL gagal"; return nullptr; }
#else
            reason = "Backend OpenCL tidak dikompilasi ke libagenthq_llama.so";
            return nullptr;
#endif
            break;
        default:
            reason = "Backend tidak dikenal";
            return nullptr;
    }
    const size_t n = ggml_backend_reg_dev_count(reg);
    for (size_t i = 0; i < n; i++) {
        ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, i);
        const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
        if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) return dev;
    }
    reason = backend == AGENTHQ_BACKEND_OPENCL
                 ? "ggml menolak perangkat OpenCL (butuh OpenCL C 2.0+ dan fp16)"
                 : "ggml tidak menemukan perangkat GPU Vulkan";
    return nullptr;
}

void json_escape(const char* in, std::string& out) {
    for (const char* p = in ? in : ""; *p; p++) {
        const unsigned char c = (unsigned char) *p;
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char) c;
                }
        }
    }
}

// llama_decode does not catch C++ exceptions; the Vulkan backend can throw
// (vk::SystemError on device-lost / out-of-memory). Map them to a decode error
// so the Dart side gets AGENTHQ_ERR_DECODE instead of a native crash.
int safe_decode(llama_batch batch) {
    try {
        return llama_decode(g_ctx, batch);
    } catch (const std::exception& e) {
        set_error(std::string("llama_decode threw: ") + e.what());
        return -99;
    } catch (...) {
        set_error("llama_decode threw");
        return -99;
    }
}

// Tokenises with BOS/EOS as configured by the model and special tokens parsed
// (ChatML markers are inserted by Dart as text).
bool tokenize(const char* text, std::vector<llama_token>& out) {
    const int len = (int) strlen(text);
    out.resize((size_t) len + 8);
    int n = llama_tokenize(g_vocab, text, len, out.data(), (int) out.size(), true, true);
    if (n < 0) {
        out.resize((size_t) -n);
        n = llama_tokenize(g_vocab, text, len, out.data(), (int) out.size(), true, true);
    }
    if (n < 0) return false;
    out.resize((size_t) n);
    return true;
}

}  // namespace

extern "C" {

int agenthq_load(const char* model_path, int n_ctx, int n_threads, int n_batch, int n_gpu_layers,
                 int backend) {
    if (!model_path || !*model_path) return fail(AGENTHQ_ERR_INVALID_ARG, "model_path is empty");
    if (n_ctx <= 0)     n_ctx = 2048;
    if (n_threads <= 0) n_threads = 4;
    if (n_batch <= 0)   n_batch = 512;
    if (n_batch > n_ctx) n_batch = n_ctx;
    if (n_gpu_layers < 0 || n_gpu_layers >= 99) n_gpu_layers = 999;  // "all"
    if (backend == AGENTHQ_BACKEND_CPU) n_gpu_layers = 0;

    backend_init_once();
    std::lock_guard<std::mutex> lk(g_mu);
    unload_locked();

    const bool want_gpu = n_gpu_layers > 0;
    ggml_backend_dev_t gpu = nullptr;
    if (want_gpu) {
        if (backend != AGENTHQ_BACKEND_VULKAN && backend != AGENTHQ_BACKEND_OPENCL) {
            return fail(AGENTHQ_ERR_INVALID_ARG, "unknown backend " + std::to_string(backend));
        }
        if (backend == AGENTHQ_BACKEND_VULKAN) {
            const uint32_t vk_version = vulkan_device_api_version();
            if (vk_version < VK_API_VERSION_1_2) {
                return fail(AGENTHQ_ERR_GPU_UNAVAILABLE,
                            vk_version == 0 ? "no usable Vulkan driver"
                                            : "GPU Vulkan " + vulkan_version_string(vk_version) + ", ggml needs 1.2");
            }
        }
        std::string reason;
        try {
            gpu = find_backend_device(backend, reason);
        } catch (const std::exception& e) {
            return fail(AGENTHQ_ERR_GPU_UNAVAILABLE, std::string(backend_name(backend)) + " init failed: " + e.what());
        } catch (...) {
            return fail(AGENTHQ_ERR_GPU_UNAVAILABLE, std::string(backend_name(backend)) + " init failed");
        }
        if (!gpu) return fail(AGENTHQ_ERR_GPU_UNAVAILABLE, std::string(backend_name(backend)) + ": " + reason);
    }

    const auto t0 = clock_t_::now();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = want_gpu ? n_gpu_layers : 0;
    // The device list is always explicit so llama never enumerates the whole registry
    // (which would initialise *every* GPU backend; Vulkan crashed on Mali drivers).
    // CPU mode: ggml_backend_cpu_reg() reaches the CPU device without the registry.
    // GPU mode: only the selected backend's device; llama keeps the non-offloaded
    // layers on the CPU with n_threads threads (hybrid GPU+CPU).
    static ggml_backend_dev_t dev_list[2] = {nullptr, nullptr};
    dev_list[0] = want_gpu ? gpu : ggml_backend_reg_dev_get(ggml_backend_cpu_reg(), 0);
    mp.devices = dev_list;
    try {
        g_model = llama_model_load_from_file(model_path, mp);
    } catch (const std::exception& e) {
        g_model = nullptr;
        set_error(std::string("model load threw: ") + e.what());
    } catch (...) {
        g_model = nullptr;
        set_error("model load threw");
    }
    if (!g_model) {
        // A GPU load that fails is reported as GPU_UNAVAILABLE so the caller can
        // retry on the CPU; a CPU load failure is the real error.
        if (want_gpu) return fail(AGENTHQ_ERR_GPU_UNAVAILABLE, "llama_model_load_from_file failed with GPU offload");
        return fail(AGENTHQ_ERR_MODEL_LOAD, "llama_model_load_from_file failed");
    }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = (uint32_t) n_ctx;
    cp.n_batch         = (uint32_t) n_batch;
    cp.n_ubatch        = (uint32_t) n_batch;
    cp.n_seq_max       = 1;
    cp.n_threads       = n_threads;
    cp.n_threads_batch = n_threads;
    cp.no_perf         = true;
    try {
        g_ctx = llama_init_from_model(g_model, cp);
    } catch (const std::exception& e) {
        g_ctx = nullptr;
        set_error(std::string("context creation threw: ") + e.what());
    } catch (...) {
        g_ctx = nullptr;
        set_error("context creation threw");
    }
    if (!g_ctx) {
        unload_locked();
        if (want_gpu) return fail(AGENTHQ_ERR_GPU_UNAVAILABLE, "llama_init_from_model failed with GPU offload");
        return fail(AGENTHQ_ERR_CONTEXT, "llama_init_from_model failed");
    }
    // llama offloads min(n_gpu_layers, n_layer + 1) (the +1 is the output layer).
    g_n_layer = llama_model_n_layer(g_model);
    if (want_gpu) {
        g_gpu_layers = std::min(n_gpu_layers, g_n_layer + 1);
        g_backend = backend;
    } else {
        g_gpu_layers = 0;
        g_backend = AGENTHQ_BACKEND_CPU;
    }
    g_n_batch = n_batch;
    g_load_ms = ms_since(t0);
    g_prompt_ms = g_gen_ms = 0;
    g_prompt_tokens = g_gen_tokens = 0;
    return AGENTHQ_OK;
}

void agenthq_unload(void) {
    std::lock_guard<std::mutex> lk(g_mu);
    unload_locked();
}

int agenthq_is_loaded(void) {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_ctx != nullptr ? 1 : 0;
}

int agenthq_gpu_layers(void) {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_ctx != nullptr ? g_gpu_layers : 0;
}

int agenthq_gpu_backend(void) {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_ctx != nullptr ? g_backend : AGENTHQ_BACKEND_CPU;
}

int agenthq_model_layers(void) {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_model != nullptr ? g_n_layer : 0;
}

void agenthq_set_cache_dir(const char* dir) {
    setenv("GGML_OPENCL_KERNEL_CACHE_DIR", dir && *dir ? dir : "off", 1);
}

int agenthq_gpu_info(int backend, char* out, int cap) {
    if (!out || cap <= 0) return fail(AGENTHQ_ERR_INVALID_ARG, "out buffer is null/empty");
    if (backend != AGENTHQ_BACKEND_VULKAN && backend != AGENTHQ_BACKEND_OPENCL) {
        return fail(AGENTHQ_ERR_INVALID_ARG, "gpu_info: backend must be 1 (vulkan) or 2 (opencl)");
    }
    backend_init_once();

    std::string desc, reason, api_version;
    bool available = false, integrated = false;
    size_t total = 0;
    bool probe = true;
    if (backend == AGENTHQ_BACKEND_VULKAN) {
        const uint32_t vk_version = vulkan_device_api_version();
        if (vk_version) api_version = vulkan_version_string(vk_version);
        if (vk_version == 0) {
            reason = "Tidak ada driver Vulkan yang bisa dipakai";
            probe = false;
        } else if (vk_version < VK_API_VERSION_1_2) {
            // Touching ggml-vulkan would crash on 1.1 drivers.
            reason = "Vulkan " + vulkan_version_string(vk_version) + " (ggml butuh 1.2)";
            probe = false;
        }
    } else {
        if (opencl_platform_count(&api_version) == 0) {
            reason = "Driver OpenCL tidak ditemukan";
            probe = false;
        }
    }
    if (probe) {
        try {
            ggml_backend_dev_t gpu = find_backend_device(backend, reason);
            if (gpu) {
                available  = true;
                // ggml-opencl reports every device as a discrete GPU; on Android the
                // OpenCL device is the SoC GPU sharing system RAM.
                integrated = ggml_backend_dev_type(gpu) == GGML_BACKEND_DEVICE_TYPE_IGPU;
#ifdef __ANDROID__
                if (backend == AGENTHQ_BACKEND_OPENCL) integrated = true;
#endif
                size_t free_ = 0;
                ggml_backend_dev_memory(gpu, &free_, &total);
                json_escape(ggml_backend_dev_description(gpu), desc);
                reason.clear();
            }
        } catch (const std::exception& e) {
            set_error(std::string(backend_name(backend)) + " query failed: " + e.what());
            reason = std::string("Inisialisasi ") + (backend == AGENTHQ_BACKEND_OPENCL ? "OpenCL" : "Vulkan") + " gagal";
        } catch (...) {
            set_error(std::string(backend_name(backend)) + " query failed");
            reason = std::string("Inisialisasi ") + (backend == AGENTHQ_BACKEND_OPENCL ? "OpenCL" : "Vulkan") + " gagal";
        }
    }

    char num[32];
    snprintf(num, sizeof num, "%llu", (unsigned long long) (total / (1024ull * 1024ull)));
    std::string json = "{\"available\":";
    json += available ? "true" : "false";
    json += ",\"backend\":\"";
    json += backend_name(backend);
    json += "\",\"device\":\"";
    json += desc;
    json += "\",\"vram_mb\":";
    json += num;
    json += ",\"integrated\":";
    json += integrated ? "true" : "false";
    json += ",\"api_version\":\"";
    std::string api_escaped;
    json_escape(api_version.c_str(), api_escaped);
    json += api_escaped;
    json += "\",\"reason\":\"";
    std::string reason_escaped;
    json_escape(reason.c_str(), reason_escaped);
    json += reason_escaped;
    json += "\"}";

    if ((int) json.size() + 1 > cap) {
        char buf[96];
        snprintf(buf, sizeof buf, "gpu_info needs %d bytes, buffer has %d", (int) json.size() + 1, cap);
        return fail(AGENTHQ_ERR_BUFFER_SMALL, buf);
    }
    memcpy(out, json.c_str(), json.size() + 1);
    return (int) json.size();
}

int agenthq_start(const char* prompt, int max_tokens, float temperature, float top_p,
                  float min_p, const char* grammar_or_null) {
    if (!prompt) return fail(AGENTHQ_ERR_INVALID_ARG, "prompt is null");
    if (max_tokens <= 0) max_tokens = 256;

    std::lock_guard<std::mutex> lk(g_mu);
    if (!g_ctx) return fail(AGENTHQ_ERR_NOT_LOADED, "no model loaded");

    finish_generation();
    free_sampler();
    g_stop.store(false);
    llama_memory_clear(llama_get_memory(g_ctx), true);

    std::vector<llama_token> tokens;
    if (!tokenize(prompt, tokens)) return fail(AGENTHQ_ERR_TOKENIZE, "llama_tokenize failed");
    if (tokens.empty()) return fail(AGENTHQ_ERR_TOKENIZE, "prompt produced no tokens");

    const int n_ctx = (int) llama_n_ctx(g_ctx);
    const int n_prompt = (int) tokens.size();
    if (n_prompt > n_ctx - max_tokens) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "prompt too long: %d tokens, n_ctx=%d, max_tokens=%d (limit %d)",
                 n_prompt, n_ctx, max_tokens, n_ctx - max_tokens);
        return fail(AGENTHQ_ERR_PROMPT_TOO_LONG, buf);
    }

    // Sampler chain: grammar -> top_p -> min_p -> temp -> dist(seed).
    llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (grammar_or_null && *grammar_or_null) {
        llama_sampler* grammar = llama_sampler_init_grammar(g_vocab, grammar_or_null, "root");
        if (!grammar) {
            llama_sampler_free(smpl);
            return fail(AGENTHQ_ERR_GRAMMAR, "grammar failed to parse");
        }
        llama_sampler_chain_add(smpl, grammar);
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_min_p(min_p, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(kSeed));

    const auto t0 = clock_t_::now();
    // Small chunks keep agenthq_stop() responsive during prompt processing, which can
    // take minutes when the model is being swapped.
    const int chunk = std::min(g_n_batch, 128);
    for (int i = 0; i < n_prompt; i += chunk) {
        if (g_stop.load()) {
            llama_sampler_free(smpl);
            return fail(AGENTHQ_ERR_CANCELLED, "cancelled during prompt processing");
        }
        const int n = std::min(chunk, n_prompt - i);
        const int rc = safe_decode(llama_batch_get_one(tokens.data() + i, n));
        if (rc != 0) {
            llama_sampler_free(smpl);
            if (rc == -99) return AGENTHQ_ERR_DECODE;  // message already set
            char buf[96];
            snprintf(buf, sizeof buf, "llama_decode(prompt) returned %d", rc);
            return fail(AGENTHQ_ERR_DECODE, buf);
        }
    }
    g_prompt_ms = ms_since(t0);
    g_prompt_tokens = n_prompt;

    g_smpl       = smpl;
    g_n_past     = n_prompt;
    g_max_tokens = max_tokens;
    g_n_gen      = 0;
    g_gen_tokens = 0;
    g_gen_ms     = 0;
    g_gen_t0     = clock_t_::now();
    g_generating = true;
    return AGENTHQ_OK;
}

int agenthq_next(char* out, int out_cap) {
    if (!out || out_cap <= 0) return fail(AGENTHQ_ERR_INVALID_ARG, "out buffer is null/empty");

    std::lock_guard<std::mutex> lk(g_mu);
    if (!g_ctx) return fail(AGENTHQ_ERR_NOT_LOADED, "no model loaded");
    if (!g_generating) return 0;
    if (g_stop.load()) { finish_generation(); return 0; }

    // Logits of the last decoded token are at index -1.
    const llama_token tok = llama_sampler_sample(g_smpl, g_ctx, -1);
    llama_sampler_accept(g_smpl, tok);
    if (llama_vocab_is_eog(g_vocab, tok)) { finish_generation(); return 0; }

    const int n = llama_token_to_piece(g_vocab, tok, out, out_cap, 0, false);
    if (n < 0) {
        finish_generation();
        char buf[96];
        snprintf(buf, sizeof buf, "token piece needs %d bytes, buffer has %d", -n, out_cap);
        return fail(AGENTHQ_ERR_BUFFER_SMALL, buf);
    }

    g_n_gen++;
    const int n_ctx = (int) llama_n_ctx(g_ctx);
    if (g_n_gen >= g_max_tokens || g_n_past + 1 >= n_ctx) {
        // Piece is still returned; the next call reports completion.
        finish_generation();
        return n;
    }

    llama_token t = tok;
    const int rc = safe_decode(llama_batch_get_one(&t, 1));
    if (rc != 0) {
        finish_generation();
        if (rc == -99) return AGENTHQ_ERR_DECODE;  // message already set
        char buf[96];
        snprintf(buf, sizeof buf, "llama_decode(token) returned %d", rc);
        return fail(AGENTHQ_ERR_DECODE, buf);
    }
    g_n_past++;
    return n;
}

void agenthq_stop(void) {
    g_stop.store(true);
}

const char* agenthq_last_error(void) {
    // Returned pointer stays valid until the next failing call.
    std::lock_guard<std::mutex> lk(g_err_mu);
    return g_err.c_str();
}

int agenthq_stats(double* load_ms, double* prompt_tokens_per_s, double* gen_tokens_per_s,
                  int* prompt_tokens, int* gen_tokens) {
    std::lock_guard<std::mutex> lk(g_mu);
    const int gen = g_generating ? g_n_gen : g_gen_tokens;
    const double gen_ms = g_generating ? ms_since(g_gen_t0) : g_gen_ms;
    if (load_ms)             *load_ms = g_load_ms;
    if (prompt_tokens_per_s) *prompt_tokens_per_s = g_prompt_ms > 0 ? g_prompt_tokens * 1000.0 / g_prompt_ms : 0.0;
    if (gen_tokens_per_s)    *gen_tokens_per_s = gen_ms > 0 ? gen * 1000.0 / gen_ms : 0.0;
    if (prompt_tokens)       *prompt_tokens = g_prompt_tokens;
    if (gen_tokens)          *gen_tokens = gen;
    return AGENTHQ_OK;
}

}  // extern "C"
