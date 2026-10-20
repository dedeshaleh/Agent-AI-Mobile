# libagenthq_llama — native LLM runtime

Thin C shim (`agenthq_llama.h/.cpp`) over [llama.cpp](https://github.com/ggml-org/llama.cpp),
pinned to tag **`b11727`** and fetched at configure time with CMake `FetchContent`
(shallow clone; sources are never vendored into this repo). Output is one shared
library, `libagenthq_llama.so`, with llama/ggml linked statically. Dart talks to it via
`lib/ai/local/llama_bindings.dart` and `llama_ffi_engine.dart`.

## Backends

- **CPU** (always): ggml-cpu with the `-march` below.
- **GPU, Vulkan** (`AGENTHQ_GPU_VULKAN=ON`, default): ggml-vulkan compiled into the same
  `.so`; `NEEDED` gains `libvulkan.so` (the Android loader, present on every device since
  API 24; the *driver* may be missing). Opt-in at runtime via `agenthq_load(..., n_gpu_layers)`
  (0 = CPU, 99 = all layers). Without a usable Vulkan 1.2 device `ggml_backend_vk_reg()`
  returns NULL and the shim answers `AGENTHQ_ERR_GPU_UNAVAILABLE` (-11) so Dart retries on
  the CPU. `agenthq_gpu_info()` reports the first GPU/iGPU in the ggml device registry as
  JSON (`{"available":true,"backend":"vulkan","device":"Mali-G610 MC6","vram_mb":..,"integrated":true}`)
  without loading a model; `agenthq_gpu_layers()` returns the layers actually offloaded.
- Vulkan build inputs (no Vulkan SDK on this PC):
  - `vulkan.hpp` + recent `vulkan_core.h`: FetchContent `KhronosGroup/Vulkan-Headers`
    (`AGENTHQ_VULKAN_HEADERS_TAG`); the NDK sysroot only has C headers at header version 275.
  - `spirv/unified1/spirv.hpp`: FetchContent `KhronosGroup/SPIRV-Headers`; ggml's
    `find_package(SPIRV-Headers CONFIG)` is satisfied by the stub in `cmake/SPIRV-Headers/`.
  - `glslc`: `$ANDROID_NDK/shader-tools/<host>/glslc` (found via `Vulkan_GLSLC_EXECUTABLE`).
    NDK r27's glslc rejects `GL_KHR_cooperative_matrix`, `GL_EXT_integer_dot_product`,
    `GL_EXT_bfloat16`; those optional shader variants are skipped (irrelevant for Mali).
  - `libvulkan.so`: the NDK sysroot copy (`Vulkan_LIBRARY`).
  - **Host compiler** for llama.cpp's `vulkan-shaders-gen` (an `ExternalProject` built for and
    run on the PC): `CMakeLists.txt` looks for `g++`/`clang++`/`cl` on PATH and in winget's
    WinLibs / LLVM-MinGW / MSYS2 folders and writes `cmake/host-toolchain.cmake.in` into the
    build dir as `GGML_VULKAN_SHADERS_GEN_TOOLCHAIN` (MinGW is linked `-static`). On this PC:
    `winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e --scope user` (GCC 16.2, no admin;
    VS 2026 is installed without the C++ workload). With no host compiler the configure prints
    a warning and builds CPU-only.
  - `cmake/agenthq_vk_compat.h` is force-included into ggml-vulkan: `std::aligned_alloc`
    needs API 28 on Bionic while the app targets android-26.

## Build flags

- Target: `arm64-v8a` only, `-march=armv8.2-a+dotprod+fp16` via `GGML_CPU_ARM_ARCH`
  (Dimensity 8200: Cortex-A78/A510, no i8mm/SVE). ggml's runtime CPU dispatch
  (`GGML_CPU_ALL_VARIANTS`) requires `GGML_BACKEND_DL` + shared ggml libs, so it is not
  used for this single static-linked `.so`.
- `BUILD_SHARED_LIBS=OFF`, `GGML_OPENMP=OFF`, `GGML_NATIVE=OFF`, `GGML_LLAMAFILE=OFF`,
  `GGML_CPU_KLEIDIAI=OFF`, `LLAMA_OPENSSL=OFF` (this tag's replacement for `LLAMA_CURL`),
  `LLAMA_BUILD_{COMMON,TESTS,EXAMPLES,TOOLS,SERVER,APP}=OFF`.
- Linker: `-Wl,-z,max-page-size=16384` (Android 15 16 KB pages),
  `--exclude-libs,ALL`, `--gc-sections`.
- Requires `-DANDROID_STL=c++_shared` (set in `build.gradle.kts`).

## Standalone rebuild (Windows, PowerShell)

```powershell
$ndk = 'D:\MobileDeveloper\android-sdk\ndk\27.2.12479018'
$cmake = 'D:\MobileDeveloper\android-sdk\cmake\3.22.1\bin\cmake.exe'
$env:Path = 'D:\MobileDeveloper\android-sdk\cmake\3.22.1\bin;' + $env:Path   # ninja
$src = 'D:\Webserver\Mobile\Agent-AI-Mobile\app\android\app\src\main\cpp'
$out = "$env:TEMP\agenthq-native\build-arm64"                                  # keep this path short

& $cmake -S $src -B $out -G Ninja `
  "-DCMAKE_TOOLCHAIN_FILE=$ndk\build\cmake\android.toolchain.cmake" `
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared `
  -DCMAKE_BUILD_TYPE=Release
& $cmake --build $out -j 12
& "$ndk\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe" -d "$out\libagenthq_llama.so" | Select-String NEEDED
```

To reuse an existing checkout instead of cloning, add
`-DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP=<path to llama.cpp at b11727>`.
The clone uses `core.longpaths=true`; deep build directories can still hit Windows
`MAX_PATH`, so keep `$out` short. Add `-DAGENTHQ_GPU_VULKAN=OFF` for a CPU-only build.
Measured with b11727 (`llvm-strip --strip-unneeded`, which is what Gradle does when packaging):
CPU-only 4.0 MB, CPU+Vulkan 23.1 MB (18.4 MB is `.rodata`: the embedded SPIR-V shader
variants). Unstripped build outputs are 51 MB / 83 MB because the NDK toolchain adds `-g`.
`NEEDED` with Vulkan: `liblog.so libm.so libdl.so libvulkan.so libc++_shared.so libc.so`;
CPU-only lacks `libvulkan.so`. Exported symbols are only `agenthq_*`; the Vulkan imports are
1.0-level (`vkGetInstanceProcAddr`, `vkGetDeviceProcAddr`, `vkCmdCopyBuffer`,
`vkGetPhysicalDeviceFeatures`), so the API-26 loader stub satisfies them.
`vkGetPhysicalDeviceFeatures2` (Vulkan 1.1, exported by `libvulkan.so` only from API 28) is
called directly by ggml-vulkan; `agenthq_llama.cpp` defines a hidden forwarder that resolves
it with `dlsym` at runtime so the `.so` still loads on API 26/27.

## In the Flutter build

`android/app/build.gradle.kts` points `externalNativeBuild.cmake.path` at this
`CMakeLists.txt` with `abiFilters("arm64-v8a")`. Gradle configures into
`android/app/.cxx/` and the first build clones llama.cpp (network needed once).
The library lands in `app/build/app/intermediates/.../lib/arm64-v8a/libagenthq_llama.so`
and is packaged into the APK next to `libc++_shared.so`; Dart loads it with
`DynamicLibrary.open('libagenthq_llama.so')`.

## Bumping llama.cpp

Change `AGENTHQ_LLAMA_TAG` in `CMakeLists.txt`, rebuild standalone, and re-check
`agenthq_llama.cpp` against the new `include/llama.h` (the API churns between tags).
