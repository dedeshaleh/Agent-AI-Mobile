// Internal bridge between agenthq_llama.cpp (which owns the backend probing
// helpers in an anonymous namespace) and agenthq_selftest.cpp. Not part of the
// C ABI; hidden visibility like everything else in the .so.
#ifndef AGENTHQ_INTERNAL_H
#define AGENTHQ_INTERNAL_H

#include <string>

#include "ggml-backend.h"

// Initialises ggml once and returns the first GPU/iGPU device of ONE backend
// (agenthq_backend), or nullptr with `reason` (Indonesian UI text). Performs the
// same driver guards as agenthq_gpu_info (Vulkan < 1.2 is never touched). May throw.
ggml_backend_dev_t agenthq_internal_find_device(int backend, std::string& reason);

void agenthq_internal_set_error(const std::string& msg);
void agenthq_internal_json_escape(const char* in, std::string& out);

#endif // AGENTHQ_INTERNAL_H
