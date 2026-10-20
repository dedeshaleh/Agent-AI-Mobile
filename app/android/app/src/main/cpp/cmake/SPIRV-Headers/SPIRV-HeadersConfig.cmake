# Stub package config so that ggml-vulkan's `find_package(SPIRV-Headers CONFIG
# REQUIRED)` succeeds with the FetchContent checkout (no Vulkan SDK installed).
# The include directory itself is added to ggml-vulkan in ../../CMakeLists.txt
# (AGENTHQ_SPIRV_HEADERS_INCLUDE); ggml only checks that the package exists.
if (NOT TARGET SPIRV-Headers::SPIRV-Headers)
  add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)
  if (AGENTHQ_SPIRV_HEADERS_INCLUDE)
    set_target_properties(SPIRV-Headers::SPIRV-Headers PROPERTIES
      INTERFACE_INCLUDE_DIRECTORIES "${AGENTHQ_SPIRV_HEADERS_INCLUDE}")
  endif()
endif()
set(SPIRV-Headers_FOUND TRUE)
