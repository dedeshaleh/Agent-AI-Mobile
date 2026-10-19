# libagenthq_llama — native LLM runtime

Thin C shim (`agenthq_llama.h/.cpp`) over [llama.cpp](https://github.com/ggml-org/llama.cpp),
pinned to tag **`b11727`** and fetched at configure time with CMake `FetchContent`
(shallow clone; sources are never vendored into this repo). Output is one shared
library, `libagenthq_llama.so`, with llama/ggml linked statically. Dart talks to it via
`lib/ai/local/llama_bindings.dart` and `llama_ffi_engine.dart`.

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
`MAX_PATH`, so keep `$out` short.

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
