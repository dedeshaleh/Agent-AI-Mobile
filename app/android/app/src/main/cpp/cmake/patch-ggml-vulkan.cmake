# Applied to the fetched llama.cpp sources (FetchContent PATCH_COMMAND). Idempotent.
#
# Android's Vulkan loader hands ggml a NULL vkGetBufferDeviceAddress on some Mali
# drivers even though the device reports bufferDeviceAddress = true, so the very
# first host-buffer allocation dereferences NULL (SIGSEGV in ggml_vk_host_malloc).
# Make the feature opt-out via GGML_VK_DISABLE_BDA, which agenthq_llama.cpp sets.
#
# Usage: cmake -DSRC=<llama.cpp source dir> -P patch-ggml-vulkan.cmake
if (NOT SRC)
  message(FATAL_ERROR "patch-ggml-vulkan.cmake: pass -DSRC=<llama.cpp source dir>")
endif()
set(_file "${SRC}/ggml/src/ggml-vulkan/ggml-vulkan.cpp")
if (NOT EXISTS "${_file}")
  message(FATAL_ERROR "patch-ggml-vulkan.cmake: ${_file} not found")
endif()
file(READ "${_file}" _content)
set(_needle   "device->buffer_device_address = vk12_features.bufferDeviceAddress;")
set(_patched  "device->buffer_device_address = vk12_features.bufferDeviceAddress && getenv(\"GGML_VK_DISABLE_BDA\") == nullptr; // agenthq patch")
string(FIND "${_content}" "${_patched}" _already)
if (_already GREATER -1)
  message(STATUS "agenthq: ggml-vulkan BDA patch already applied")
  return()
endif()
string(FIND "${_content}" "${_needle}" _pos)
if (_pos EQUAL -1)
  message(WARNING "agenthq: ggml-vulkan BDA patch anchor not found; llama.cpp tag changed? GPU mode may crash on Mali.")
  return()
endif()
string(REPLACE "${_needle}" "${_patched}" _content "${_content}")
file(WRITE "${_file}" "${_content}")
message(STATUS "agenthq: ggml-vulkan BDA patch applied to ${_file}")
