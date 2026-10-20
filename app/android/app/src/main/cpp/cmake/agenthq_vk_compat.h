// Force-included (-include) into ggml-vulkan sources only.
//
// ggml-vulkan-buffers.cpp calls std::aligned_alloc, but Bionic hides
// aligned_alloc() below API 28 and the app targets android-26 (build.gradle.kts).
// libc++'s <cstdlib> pulls it in with `using ::aligned_alloc _LIBCPP_USING_IF_EXISTS`,
// so providing a global aligned_alloc before <cstdlib> is seen makes
// std::aligned_alloc resolve to this posix_memalign wrapper. Freed with free().
#ifndef AGENTHQ_VK_COMPAT_H
#define AGENTHQ_VK_COMPAT_H

#if defined(__ANDROID__)
#include <android/api-level.h>
#if __ANDROID_API__ < 28
#include <stdlib.h>
static inline void* aligned_alloc(size_t alignment, size_t size) {
    void* p = nullptr;
    if (alignment < sizeof(void*)) alignment = sizeof(void*);
    return posix_memalign(&p, alignment, size) == 0 ? p : nullptr;
}
#endif
#endif

#endif // AGENTHQ_VK_COMPAT_H
