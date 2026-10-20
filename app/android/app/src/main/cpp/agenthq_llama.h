// C ABI of libagenthq_llama.so: a thin polling shim over llama.cpp for the
// Agent HQ Flutter app (dart:ffi). One global model/context, one generation
// at a time. All functions except agenthq_stop / agenthq_last_error must be
// called from a single thread (the Dart worker isolate).
#ifndef AGENTHQ_LLAMA_H
#define AGENTHQ_LLAMA_H

#ifdef __cplusplus
extern "C" {
#endif

#define AGENTHQ_API __attribute__((visibility("default")))

enum agenthq_error {
    AGENTHQ_OK                 = 0,
    AGENTHQ_ERR_INVALID_ARG    = -1,
    AGENTHQ_ERR_MODEL_LOAD     = -2,
    AGENTHQ_ERR_CONTEXT        = -3,
    AGENTHQ_ERR_NOT_LOADED     = -4,
    AGENTHQ_ERR_TOKENIZE       = -5,
    AGENTHQ_ERR_PROMPT_TOO_LONG = -6,
    AGENTHQ_ERR_DECODE         = -7,
    AGENTHQ_ERR_GRAMMAR        = -8,
    AGENTHQ_ERR_NOT_GENERATING = -9,
    AGENTHQ_ERR_BUFFER_SMALL   = -10,
    // n_gpu_layers > 0 was requested but the selected GPU backend has no usable
    // device (no driver, Vulkan < 1.2, backend not compiled in, kernels failed
    // to compile) or the GPU load/context creation failed. Caller should retry
    // with n_gpu_layers = 0 / backend = AGENTHQ_BACKEND_CPU.
    AGENTHQ_ERR_GPU_UNAVAILABLE = -11,
    // agenthq_stop() was called while the prompt was still being decoded.
    AGENTHQ_ERR_CANCELLED       = -12,
};

// GPU backend selector for agenthq_load / agenthq_gpu_info. Both GPU backends
// are compiled into the same .so; only the selected one is initialised for a
// load (ggml's device list is restricted to that backend's device).
enum agenthq_backend {
    AGENTHQ_BACKEND_CPU    = 0,
    AGENTHQ_BACKEND_VULKAN = 1,
    AGENTHQ_BACKEND_OPENCL = 2,
};

// Loads a GGUF model and creates a context. n_batch <= 0 -> 512.
// n_gpu_layers: 0 = CPU only (default/safe), N = offload N layers to the GPU
// selected by `backend`, >= 99 or negative = all layers. The remaining layers
// and the n_threads CPU threads are used as usual (hybrid GPU+CPU).
// backend: agenthq_backend; ignored when n_gpu_layers == 0.
// Returns 0 or a negative agenthq_error; details in agenthq_last_error().
AGENTHQ_API int agenthq_load(const char* model_path, int n_ctx, int n_threads, int n_batch,
                             int n_gpu_layers, int backend);
AGENTHQ_API void agenthq_unload(void);
AGENTHQ_API int agenthq_is_loaded(void);

// Number of layers actually offloaded to the GPU by the current model
// (0 when CPU only or nothing loaded).
AGENTHQ_API int agenthq_gpu_layers(void);

// agenthq_backend actually used by the loaded model (AGENTHQ_BACKEND_CPU when
// nothing is offloaded or nothing is loaded).
AGENTHQ_API int agenthq_gpu_backend(void);

// Transformer layer count (n_layer) of the loaded model, 0 when nothing is
// loaded. Used by the UI for the "balanced" GPU/CPU split preset.
AGENTHQ_API int agenthq_model_layers(void);

// Directory for the OpenCL kernel binary cache (GGML_OPENCL_KERNEL_CACHE_DIR);
// call before the first load. Compiling the ~200 embedded kernels on the GPU
// driver takes seconds on every load without it. NULL/"" disables the cache.
AGENTHQ_API void agenthq_set_cache_dir(const char* dir);

// Queries one GPU backend (no model needed) and writes JSON:
//   {"available":true,"backend":"opencl","device":"Mali-G610 MC6",
//    "vram_mb":7812,"integrated":true,"api_version":"OpenCL 3.0","reason":""}
// or {"available":false,"backend":"vulkan","device":"","vram_mb":0,
//     "integrated":false,"api_version":"1.1","reason":"Vulkan 1.1 (ggml butuh 1.2)"}.
// `reason` is Indonesian UI text. Returns bytes written (excluding NUL),
// AGENTHQ_ERR_BUFFER_SMALL or AGENTHQ_ERR_INVALID_ARG for backend 0/unknown.
// Never crashes on a missing driver: the Vulkan apiVersion is probed before
// ggml-vulkan is touched and the OpenCL ICD loader simply finds no platform.
AGENTHQ_API int agenthq_gpu_info(int backend, char* out, int cap);

// Runs the ggml ops a decoder needs (mul_mat q4_K/q6_K/q8_0/f16/f32, rms_norm,
// norm, soft_max, rope, flash_attn, mul/add/silu/swiglu, get_rows, cpy, scale) on
// the CPU and on `backend` (1 Vulkan, 2 OpenCL) with identical random inputs and
// writes a JSON report with the NMSE per op, plus the subgroup sizes the OpenCL
// driver really uses:
//   {"available":true,"backend":"opencl","device":"Mali-G610 MC6","reason":"",
//    "subgroup":{"max_wg":1024,"kernel_wg":1024,"ndrange":{"16":16,...},
//                "runtime":{"64":16,"256":16},"error":""},
//    "tests":[{"op":"mul_mat q4_K ...","nmse":1.2e-5,"tol":5e-4,"ok":true,
//              "supported":true,"gpu_ms":1.3,"cpu_ms":4.0,"error":""},...]}
// No model needed; does not touch the loaded model. Takes a few seconds. Returns
// bytes written, AGENTHQ_ERR_BUFFER_SMALL or AGENTHQ_ERR_INVALID_ARG.
AGENTHQ_API int agenthq_gpu_selftest(int backend, char* out, int cap);

// Clears memory, decodes the prompt (special tokens parsed) and prepares the
// sampler chain. Fails with AGENTHQ_ERR_PROMPT_TOO_LONG if
// prompt_tokens > n_ctx - max_tokens (counts reported in last error).
AGENTHQ_API int agenthq_start(const char* prompt, int max_tokens, float temperature,
                              float top_p, float min_p, const char* grammar_or_null);

// Writes the next token's piece into out (raw UTF-8 bytes, possibly a partial
// code point; no NUL terminator). Returns bytes written, 0 when generation has
// finished (EOG, max_tokens, context full or agenthq_stop), < 0 on error.
AGENTHQ_API int agenthq_next(char* out, int out_cap);

// Thread-safe: makes the next agenthq_next() return 0.
AGENTHQ_API void agenthq_stop(void);

AGENTHQ_API const char* agenthq_last_error(void);

// Timings of the last load / generation. Any pointer may be NULL.
AGENTHQ_API int agenthq_stats(double* load_ms, double* prompt_tokens_per_s,
                              double* gen_tokens_per_s, int* prompt_tokens, int* gen_tokens);

#ifdef __cplusplus
}
#endif

#endif // AGENTHQ_LLAMA_H
