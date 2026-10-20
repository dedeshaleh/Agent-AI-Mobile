// Direct-binding OpenCL shim: every cl* symbol that ggml-opencl (b11727) and
// agenthq_llama.cpp reference is defined here as a trampoline that resolves the
// real entry point from the vendor driver with dlopen/dlsym on first use.
//
// Why not the Khronos ICD loader: it needs the driver to export the ICD
// extension (clGetExtensionFunctionAddress("clIcdGetPlatformIDsKHR")). The Mali
// driver on the Infinix X6871 (/vendor/lib64/libOpenCL.so, 136 exported cl*
// functions) does not provide it, so the loader found no platform ("platform IDs
// not available"). Binding the exported functions directly works with any driver.
//
// Linking: ggml-opencl links the static library built from this file instead of
// libOpenCL.so, so libagenthq_llama.so has no NEEDED on the vendor library and
// still loads on devices without an OpenCL driver (all trampolines then return
// an OpenCL error / NULL; nothing crashes). --exclude-libs,ALL hides the cl*
// symbols from the final .so.
#define CL_TARGET_OPENCL_VERSION 300
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#define CL_USE_DEPRECATED_OPENCL_1_0_APIS
#include <CL/cl.h>
#include <CL/cl_ext.h>  // CL_PLATFORM_NOT_FOUND_KHR

#include <dlfcn.h>
#include <mutex>

#ifdef __ANDROID__
#include <android/log.h>
#define AGENTHQ_CL_LOG(prio, ...) __android_log_print(prio, "agenthq_llama", __VA_ARGS__)
#else
#include <cstdio>
#define AGENTHQ_CL_LOG(prio, ...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#define ANDROID_LOG_INFO 4
#define ANDROID_LOG_DEBUG 3
#define ANDROID_LOG_WARN 5
#endif

namespace {

// Bare soname first: the Android linker resolves it through the vendor namespace
// because libOpenCL.so is listed in /vendor/etc/public.libraries.txt. Absolute
// paths are fallbacks for odd linker configs (they may be refused by the app
// namespace, which is fine).
const char* const kCandidates[] = {
    "libOpenCL.so",
    "/vendor/lib64/libOpenCL.so",
    "/system/vendor/lib64/libOpenCL.so",
    "/system/lib64/libOpenCL.so",
};

void* driver_handle() {
    static void* handle = [] {
        void* h = nullptr;
        for (const char* path : kCandidates) {
            h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
            if (h) {
                AGENTHQ_CL_LOG(ANDROID_LOG_INFO, "opencl: driver loaded from %s", path);
                return h;
            }
            const char* err = dlerror();
            AGENTHQ_CL_LOG(ANDROID_LOG_DEBUG, "opencl: dlopen(%s) failed: %s", path, err ? err : "?");
        }
        AGENTHQ_CL_LOG(ANDROID_LOG_WARN, "opencl: no OpenCL driver found (tried libOpenCL.so and /vendor paths)");
        return h;
    }();
    return handle;
}

void* resolve(const char* name) {
    void* h = driver_handle();
    if (!h) return nullptr;
    void* sym = dlsym(h, name);
    if (!sym) AGENTHQ_CL_LOG(ANDROID_LOG_WARN, "opencl: driver lacks %s", name);
    return sym;
}

}  // namespace

// ret name(params) { resolve; if missing -> `fail` statement; else forward args }
#define AGENTHQ_CL_TRAMPOLINE(ret, name, params, args, fail)                        \
    extern "C" CL_API_ENTRY ret CL_API_CALL name params {                           \
        using fn_t = ret(CL_API_CALL*) params;                                      \
        static fn_t fn = reinterpret_cast<fn_t>(resolve(#name));                    \
        if (!fn) { fail; }                                                          \
        return fn args;                                                             \
    }

#define AGENTHQ_FAIL_INT(code) return code
#define AGENTHQ_FAIL_PTR(code) do { if (errcode_ret) *errcode_ret = code; return nullptr; } while (0)

// --- platform / device ------------------------------------------------------
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetPlatformIDs,
    (cl_uint num_entries, cl_platform_id* platforms, cl_uint* num_platforms),
    (num_entries, platforms, num_platforms),
    { if (num_platforms) *num_platforms = 0; AGENTHQ_FAIL_INT(CL_PLATFORM_NOT_FOUND_KHR); })
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetPlatformInfo,
    (cl_platform_id platform, cl_platform_info param_name, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (platform, param_name, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_PLATFORM))
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetDeviceIDs,
    (cl_platform_id platform, cl_device_type device_type, cl_uint num_entries, cl_device_id* devices, cl_uint* num_devices),
    (platform, device_type, num_entries, devices, num_devices),
    { if (num_devices) *num_devices = 0; AGENTHQ_FAIL_INT(CL_DEVICE_NOT_FOUND); })
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetDeviceInfo,
    (cl_device_id device, cl_device_info param_name, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (device, param_name, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_DEVICE))

// --- context / queue --------------------------------------------------------
AGENTHQ_CL_TRAMPOLINE(cl_context, clCreateContext,
    (const cl_context_properties* properties, cl_uint num_devices, const cl_device_id* devices,
     void (CL_CALLBACK* pfn_notify)(const char*, const void*, size_t, void*), void* user_data, cl_int* errcode_ret),
    (properties, num_devices, devices, pfn_notify, user_data, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_PLATFORM))
AGENTHQ_CL_TRAMPOLINE(cl_int, clReleaseContext, (cl_context context), (context), AGENTHQ_FAIL_INT(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_command_queue, clCreateCommandQueue,
    (cl_context context, cl_device_id device, cl_command_queue_properties properties, cl_int* errcode_ret),
    (context, device, properties, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_int, clReleaseCommandQueue, (cl_command_queue command_queue), (command_queue), AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clFlush, (cl_command_queue command_queue), (command_queue), AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clFinish, (cl_command_queue command_queue), (command_queue), AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))

// --- memory objects ---------------------------------------------------------
AGENTHQ_CL_TRAMPOLINE(cl_mem, clCreateBuffer,
    (cl_context context, cl_mem_flags flags, size_t size, void* host_ptr, cl_int* errcode_ret),
    (context, flags, size, host_ptr, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_mem, clCreateBufferWithProperties,
    (cl_context context, const cl_mem_properties* properties, cl_mem_flags flags, size_t size, void* host_ptr, cl_int* errcode_ret),
    (context, properties, flags, size, host_ptr, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_mem, clCreateSubBuffer,
    (cl_mem buffer, cl_mem_flags flags, cl_buffer_create_type buffer_create_type, const void* buffer_create_info, cl_int* errcode_ret),
    (buffer, flags, buffer_create_type, buffer_create_info, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_MEM_OBJECT))
AGENTHQ_CL_TRAMPOLINE(cl_mem, clCreateImage,
    (cl_context context, cl_mem_flags flags, const cl_image_format* image_format, const cl_image_desc* image_desc, void* host_ptr, cl_int* errcode_ret),
    (context, flags, image_format, image_desc, host_ptr, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_int, clReleaseMemObject, (cl_mem memobj), (memobj), AGENTHQ_FAIL_INT(CL_INVALID_MEM_OBJECT))

// --- programs / kernels -----------------------------------------------------
AGENTHQ_CL_TRAMPOLINE(cl_program, clCreateProgramWithSource,
    (cl_context context, cl_uint count, const char** strings, const size_t* lengths, cl_int* errcode_ret),
    (context, count, strings, lengths, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_program, clCreateProgramWithBinary,
    (cl_context context, cl_uint num_devices, const cl_device_id* device_list, const size_t* lengths,
     const unsigned char** binaries, cl_int* binary_status, cl_int* errcode_ret),
    (context, num_devices, device_list, lengths, binaries, binary_status, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_CONTEXT))
AGENTHQ_CL_TRAMPOLINE(cl_int, clBuildProgram,
    (cl_program program, cl_uint num_devices, const cl_device_id* device_list, const char* options,
     void (CL_CALLBACK* pfn_notify)(cl_program, void*), void* user_data),
    (program, num_devices, device_list, options, pfn_notify, user_data),
    AGENTHQ_FAIL_INT(CL_INVALID_PROGRAM))
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetProgramInfo,
    (cl_program program, cl_program_info param_name, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (program, param_name, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_PROGRAM))
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetProgramBuildInfo,
    (cl_program program, cl_device_id device, cl_program_build_info param_name, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (program, device, param_name, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_PROGRAM))
AGENTHQ_CL_TRAMPOLINE(cl_int, clReleaseProgram, (cl_program program), (program), AGENTHQ_FAIL_INT(CL_INVALID_PROGRAM))
AGENTHQ_CL_TRAMPOLINE(cl_kernel, clCreateKernel,
    (cl_program program, const char* kernel_name, cl_int* errcode_ret),
    (program, kernel_name, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_PROGRAM))
AGENTHQ_CL_TRAMPOLINE(cl_int, clSetKernelArg,
    (cl_kernel kernel, cl_uint arg_index, size_t arg_size, const void* arg_value),
    (kernel, arg_index, arg_size, arg_value),
    AGENTHQ_FAIL_INT(CL_INVALID_KERNEL))
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetKernelWorkGroupInfo,
    (cl_kernel kernel, cl_device_id device, cl_kernel_work_group_info param_name, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (kernel, device, param_name, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_KERNEL))
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetKernelSubGroupInfo,
    (cl_kernel kernel, cl_device_id device, cl_kernel_sub_group_info param_name, size_t input_value_size,
     const void* input_value, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (kernel, device, param_name, input_value_size, input_value, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_KERNEL))
AGENTHQ_CL_TRAMPOLINE(cl_int, clReleaseKernel, (cl_kernel kernel), (kernel), AGENTHQ_FAIL_INT(CL_INVALID_KERNEL))

// --- enqueue ----------------------------------------------------------------
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueNDRangeKernel,
    (cl_command_queue command_queue, cl_kernel kernel, cl_uint work_dim, const size_t* global_work_offset,
     const size_t* global_work_size, const size_t* local_work_size, cl_uint num_events_in_wait_list,
     const cl_event* event_wait_list, cl_event* event),
    (command_queue, kernel, work_dim, global_work_offset, global_work_size, local_work_size, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueReadBuffer,
    (cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_read, size_t offset, size_t size, void* ptr,
     cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event),
    (command_queue, buffer, blocking_read, offset, size, ptr, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueWriteBuffer,
    (cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_write, size_t offset, size_t size, const void* ptr,
     cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event),
    (command_queue, buffer, blocking_write, offset, size, ptr, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueCopyBuffer,
    (cl_command_queue command_queue, cl_mem src_buffer, cl_mem dst_buffer, size_t src_offset, size_t dst_offset, size_t size,
     cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event),
    (command_queue, src_buffer, dst_buffer, src_offset, dst_offset, size, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueFillBuffer,
    (cl_command_queue command_queue, cl_mem buffer, const void* pattern, size_t pattern_size, size_t offset, size_t size,
     cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event),
    (command_queue, buffer, pattern, pattern_size, offset, size, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(void*, clEnqueueMapBuffer,
    (cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_map, cl_map_flags map_flags, size_t offset, size_t size,
     cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event, cl_int* errcode_ret),
    (command_queue, buffer, blocking_map, map_flags, offset, size, num_events_in_wait_list, event_wait_list, event, errcode_ret),
    AGENTHQ_FAIL_PTR(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueUnmapMemObject,
    (cl_command_queue command_queue, cl_mem memobj, void* mapped_ptr, cl_uint num_events_in_wait_list,
     const cl_event* event_wait_list, cl_event* event),
    (command_queue, memobj, mapped_ptr, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueMarkerWithWaitList,
    (cl_command_queue command_queue, cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event),
    (command_queue, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))
AGENTHQ_CL_TRAMPOLINE(cl_int, clEnqueueBarrierWithWaitList,
    (cl_command_queue command_queue, cl_uint num_events_in_wait_list, const cl_event* event_wait_list, cl_event* event),
    (command_queue, num_events_in_wait_list, event_wait_list, event),
    AGENTHQ_FAIL_INT(CL_INVALID_COMMAND_QUEUE))

// --- events -----------------------------------------------------------------
AGENTHQ_CL_TRAMPOLINE(cl_int, clWaitForEvents, (cl_uint num_events, const cl_event* event_list), (num_events, event_list), AGENTHQ_FAIL_INT(CL_INVALID_EVENT))
AGENTHQ_CL_TRAMPOLINE(cl_int, clReleaseEvent, (cl_event event), (event), AGENTHQ_FAIL_INT(CL_INVALID_EVENT))
AGENTHQ_CL_TRAMPOLINE(cl_int, clGetEventProfilingInfo,
    (cl_event event, cl_profiling_info param_name, size_t param_value_size, void* param_value, size_t* param_value_size_ret),
    (event, param_name, param_value_size, param_value, param_value_size_ret),
    AGENTHQ_FAIL_INT(CL_INVALID_EVENT))

// Exposed for agenthq_llama.cpp's gpu_info: true when a driver library was dlopen()ed.
extern "C" int agenthq_cl_driver_loaded(void) { return driver_handle() != nullptr ? 1 : 0; }
