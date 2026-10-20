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
    // n_gpu_layers > 0 was requested but no usable Vulkan device exists (no
    // driver, Vulkan < 1.2, backend not compiled in) or the GPU load/context
    // creation failed. Caller should retry with n_gpu_layers = 0.
    AGENTHQ_ERR_GPU_UNAVAILABLE = -11,
};

// Loads a GGUF model and creates a context. n_batch <= 0 -> 512.
// n_gpu_layers: 0 = CPU only (default/safe), N = offload N layers to the GPU
// (Vulkan), >= 99 or negative = all layers. Returns 0 or a negative
// agenthq_error; details in agenthq_last_error().
AGENTHQ_API int agenthq_load(const char* model_path, int n_ctx, int n_threads, int n_batch,
                             int n_gpu_layers);
AGENTHQ_API void agenthq_unload(void);
AGENTHQ_API int agenthq_is_loaded(void);

// Number of layers actually offloaded to the GPU by the current model
// (0 when CPU only or nothing loaded).
AGENTHQ_API int agenthq_gpu_layers(void);

// Queries the ggml backend device registry (no model needed) and writes JSON:
//   {"available":true,"backend":"vulkan","device":"Mali-G610 MC6",
//    "vram_mb":7812,"integrated":true}
// or {"available":false,"backend":"vulkan","device":"","vram_mb":0,"integrated":false}.
// Returns bytes written (excluding NUL) or AGENTHQ_ERR_BUFFER_SMALL. Safe to
// call on devices without a Vulkan driver (the backend simply registers no
// device).
AGENTHQ_API int agenthq_gpu_info(char* out, int cap);

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
