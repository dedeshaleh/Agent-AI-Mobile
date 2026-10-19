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
};

// Loads a GGUF model and creates a context. n_batch <= 0 -> 512. Returns 0 or
// a negative agenthq_error; details in agenthq_last_error().
AGENTHQ_API int agenthq_load(const char* model_path, int n_ctx, int n_threads, int n_batch);
AGENTHQ_API void agenthq_unload(void);
AGENTHQ_API int agenthq_is_loaded(void);

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
