#include "agenthq_llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"

#ifdef __ANDROID__
#include <android/log.h>
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

int agenthq_load(const char* model_path, int n_ctx, int n_threads, int n_batch) {
    if (!model_path || !*model_path) return fail(AGENTHQ_ERR_INVALID_ARG, "model_path is empty");
    if (n_ctx <= 0)     n_ctx = 2048;
    if (n_threads <= 0) n_threads = 4;
    if (n_batch <= 0)   n_batch = 512;
    if (n_batch > n_ctx) n_batch = n_ctx;

    backend_init_once();
    std::lock_guard<std::mutex> lk(g_mu);
    unload_locked();

    const auto t0 = clock_t_::now();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    g_model = llama_model_load_from_file(model_path, mp);
    if (!g_model) return fail(AGENTHQ_ERR_MODEL_LOAD, "llama_model_load_from_file failed");
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = (uint32_t) n_ctx;
    cp.n_batch         = (uint32_t) n_batch;
    cp.n_ubatch        = (uint32_t) n_batch;
    cp.n_seq_max       = 1;
    cp.n_threads       = n_threads;
    cp.n_threads_batch = n_threads;
    cp.no_perf         = true;
    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) {
        unload_locked();
        return fail(AGENTHQ_ERR_CONTEXT, "llama_init_from_model failed");
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
    for (int i = 0; i < n_prompt; i += g_n_batch) {
        const int n = std::min(g_n_batch, n_prompt - i);
        const int rc = llama_decode(g_ctx, llama_batch_get_one(tokens.data() + i, n));
        if (rc != 0) {
            llama_sampler_free(smpl);
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
    const int rc = llama_decode(g_ctx, llama_batch_get_one(&t, 1));
    if (rc != 0) {
        finish_generation();
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
