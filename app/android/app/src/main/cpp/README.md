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
  API 24; the *driver* may be missing). Opt-in at runtime via
  `agenthq_load(..., n_gpu_layers, backend)` (`n_gpu_layers` 0 = CPU, 99 = all layers,
  anything between = hybrid GPU+CPU; `backend` 0 = CPU, 1 = Vulkan, 2 = OpenCL). Without a
  usable Vulkan 1.2 device the shim answers `AGENTHQ_ERR_GPU_UNAVAILABLE` (-11) so Dart
  retries on the CPU. `agenthq_gpu_info(backend, ...)` reports that backend's first GPU/iGPU
  as JSON (`{"available":true,"backend":"opencl","device":"Mali-G610 MC6","vram_mb":..,
  "integrated":true,"api_version":"OpenCL 3.0","reason":""}`) without loading a model;
  `agenthq_gpu_layers()` / `agenthq_gpu_backend()` return what the loaded model actually
  offloads, `agenthq_model_layers()` its `n_layer`.
- **GPU, OpenCL** (`AGENTHQ_GPU_OPENCL=ON`, default): ggml-opencl for GPUs whose Vulkan
  driver is < 1.2 (Mali-G610 on the Infinix X6871 reports 1.1). No NDK OpenCL SDK exists, so:
  - Headers: FetchContent `KhronosGroup/OpenCL-Headers` (`AGENTHQ_OPENCL_HEADERS_TAG`).
  - Library: FetchContent `KhronosGroup/OpenCL-ICD-Loader` (`AGENTHQ_OPENCL_LOADER_TAG`) built
    as a **static** lib (`OPENCL_ICD_LOADER_BUILD_SHARED_LIBS=OFF`, layers/tools/tests off) and
    linked into `libagenthq_llama.so`; `cmake/modules/FindOpenCL.cmake` answers ggml's
    `find_package(OpenCL REQUIRED)` with that target. Result: **no `NEEDED libOpenCL.so`**, the
    `.so` loads on devices without a driver, and `cl*` symbols are hidden (`--exclude-libs,ALL`).
  - Runtime discovery: the loader reads `.icd` files from `/system/vendor/Khronos/OpenCL/vendors`
    (absent on most phones) and the `OCL_ICD_FILENAMES` env (colon-separated libraries to
    `dlopen`, see `loader/icd.c`). `agenthq_llama.cpp` sets `OCL_ICD_FILENAMES=libOpenCL.so`
    in `backend_init_once()` before any CL call. The bare soname is used on purpose: the vendor
    driver is listed in `/vendor/etc/public.libraries.txt`, so the app linker namespace
    resolves `libOpenCL.so` via the vendor namespace, while an absolute `/vendor/lib64/...`
    path is rejected ("not accessible for the namespace"). No `.icd` file is written. The
    driver must expose `cl_khr_icd` (`clIcdGetPlatformIDsKHR`); ARM Mali drivers do.
  - 64-bit only: ggml-opencl b11727 does not compile for armeabi-v7a (int64 → size_t
    narrowing errors), so the CMake skips it when `CMAKE_SIZEOF_VOID_P != 8`; the debug
    Gradle build still configures v7a/x86_64 and those get CPU(+Vulkan) only.
  - Kernels: `GGML_OPENCL_EMBED_KERNELS=ON` (ggml's `kernels/embed_kernel.py` needs a host
    `python3`; the CMake looks in `%LOCALAPPDATA%/Programs/Python/Python3*`), Adreno-only
    kernels off (`GGML_OPENCL_USE_ADRENO_KERNELS=OFF`), target OpenCL 3.0.
  - `cmake/patch-ggml-opencl.cmake` (FetchContent PATCH_COMMAND, idempotent, 5 hunks):
    accept non-Adreno/Intel GPUs instead of dropping them, skip the `gated_delta_net`
    kernels instead of `exit(1)` on an unknown GPU family, and turn kernel-compile `exit(1)`
    into `std::runtime_error` (ggml-opencl is built with `-fexceptions`), which the shim
    catches around `llama_model_load_from_file` → -11 → CPU fallback.
  - Kernel binary cache: `agenthq_set_cache_dir(dir)` sets `GGML_OPENCL_KERNEL_CACHE_DIR`;
    Dart passes `<files>/cl-cache` before the first load (default would be `/tmp`, absent on
    Bionic → cache off).
  - Device selection never touches the global ggml registry (that would initialise every
    backend, and ggml-vulkan crashes on 1.1 drivers): `find_backend_device()` uses
    `ggml_backend_vk_reg()` / `ggml_backend_opencl_reg()` directly and passes
    `llama_model_params.devices = {dev, NULL}`. The shim also calls `clGetPlatformIDs` itself
    (through the static loader) to distinguish "no driver" from "ggml rejected the device".
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
`-DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP=<path to llama.cpp at b11727>` (and likewise
`..._OPENCL_HEADERS`, `..._OPENCL_ICD_LOADER`, `..._VULKAN_HEADERS`, `..._SPIRV_HEADERS`).
With a reused llama.cpp checkout FetchContent skips `PATCH_COMMAND`, so run the patch scripts
by hand first: `cmake -DSRC=<llama.cpp> -P cmake/patch-ggml-vulkan.cmake` and
`... -P cmake/patch-ggml-opencl.cmake` (both idempotent).
The clone uses `core.longpaths=true`; deep build directories can still hit Windows
`MAX_PATH`, so keep `$out` short. Add `-DAGENTHQ_GPU_VULKAN=OFF` / `-DAGENTHQ_GPU_OPENCL=OFF`
for smaller builds.
Measured with b11727 (`llvm-strip --strip-unneeded`, which is what Gradle does when packaging):
CPU-only 4.0 MB, CPU+Vulkan 23.1 MB (18.4 MB is `.rodata`: the embedded SPIR-V shader
variants), CPU+Vulkan+OpenCL 25.9 MB (`.rodata` 20.3 MB, `.text` 4.6 MB; the extra ≈2.7 MB
is the embedded OpenCL kernel sources plus the ICD loader). Unstripped build outputs are
51 / 83 / 89 MB because the NDK toolchain adds `-g`.
`NEEDED` with Vulkan+OpenCL: `liblog.so libvulkan.so libm.so libdl.so libc++_shared.so libc.so`
(no `libOpenCL.so`); CPU-only lacks `libvulkan.so`. Exported symbols are only `agenthq_*`; the Vulkan imports are
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
