// ONNX Runtime is loaded dynamically so the SwiftPM app has no hard link-time
// dependency on a library path that varies between installs.
#include "ort_bridge.h"
#include "ort_c_api.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef const OrtApiBase* (*OrtGetApiBaseFn)(void);

static void* g_handle = NULL;
static const OrtApi* g_api = NULL;
static char g_load_error[512] = {0};

static void set_error(char* error, size_t error_len, const char* message) {
    if (!error || error_len == 0) return;
    snprintf(error, error_len, "%s", message ? message : "unknown error");
}

static const char* candidate_paths[] = {
    "/opt/homebrew/lib/libonnxruntime.dylib",
    "/usr/local/lib/libonnxruntime.dylib",
    NULL
};

static const OrtApi* api(void) {
    if (g_api) return g_api;
    const char* env = getenv("ONNXRUNTIME_LIB");
    char tried[512] = {0};
    if (env && env[0]) {
        g_handle = dlopen(env, RTLD_NOW | RTLD_LOCAL);
        if (!g_handle) {
            snprintf(g_load_error, sizeof(g_load_error), "dlopen(%s): %s", env, dlerror());
            return NULL;
        }
    } else {
        for (int i = 0; candidate_paths[i]; i++) {
            g_handle = dlopen(candidate_paths[i], RTLD_NOW | RTLD_LOCAL);
            if (g_handle) break;
        }
        if (!g_handle) {
            snprintf(g_load_error, sizeof(g_load_error), "libonnxruntime not found (tried %s and friends)%s", candidate_paths[0], tried);
            return NULL;
        }
    }
    OrtGetApiBaseFn get_base = (OrtGetApiBaseFn)dlsym(g_handle, "OrtGetApiBase");
    if (!get_base) {
        snprintf(g_load_error, sizeof(g_load_error), "OrtGetApiBase missing: %s", dlerror());
        return NULL;
    }
    const OrtApiBase* base = get_base();
    g_api = base->GetApi(ORT_API_VERSION);
    if (!g_api) {
        snprintf(g_load_error, sizeof(g_load_error), "OrtGetApiBase::GetApi(%d) returned NULL", ORT_API_VERSION);
    }
    return g_api;
}

int sf_ort_available(void) {
    return api() != NULL ? 1 : 0;
}

static void release_status(const OrtApi* ort, OrtStatus* status, char* error, size_t error_len) {
    if (status) {
        set_error(error, error_len, ort->GetErrorMessage(status));
        ort->ReleaseStatus(status);
    }
}

static void describe_value(const OrtApi* ort, OrtSession* session, int input, char* out, size_t cap, size_t* used) {
    OrtAllocator* alloc = NULL;
    ort->GetAllocatorWithDefaultOptions(&alloc);
    char* name = NULL;
    OrtTypeInfo* type_info = NULL;
    const OrtTensorTypeAndShapeInfo* shape = NULL;
    size_t dims = 0;
    int64_t d[8] = {0};
    ONNXTensorElementDataType elem = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    if (input) {
        ort->SessionGetInputName(session, 0, alloc, &name);
        ort->SessionGetInputTypeInfo(session, 0, &type_info);
    } else {
        ort->SessionGetOutputName(session, 0, alloc, &name);
        ort->SessionGetOutputTypeInfo(session, 0, &type_info);
    }
    if (type_info) ort->CastTypeInfoToTensorInfo(type_info, &shape);
    if (shape) {
        ort->GetDimensionsCount(shape, &dims);
        if (dims > 8) dims = 8;
        ort->GetDimensions(shape, d, dims);
        ort->GetTensorElementType(shape, &elem);
    }
    int written = snprintf(out + *used, cap - *used, "%s name=%s elem=%d dims=[", input ? "input" : "output", name ? name : "?", (int)elem);
    if (written > 0) *used += (size_t)written;
    for (size_t i = 0; i < dims; i++) {
        written = snprintf(out + *used, cap - *used, "%lld%s", (long long)d[i], i + 1 < dims ? "," : "");
        if (written > 0) *used += (size_t)written;
    }
    written = snprintf(out + *used, cap - *used, "]\n");
    if (written > 0) *used += (size_t)written;
    if (type_info) ort->ReleaseTypeInfo(type_info);
    if (name) ort->AllocatorFree(alloc, name);
}

int sf_ort_describe(const char* model_path, char* buffer, size_t buffer_len) {
    const OrtApi* ort = api();
    if (!ort) {
        set_error(buffer, buffer_len, g_load_error);
        return 1;
    }
    OrtEnv* env = NULL;
    OrtSessionOptions* opts = NULL;
    OrtSession* session = NULL;
    char error[512] = {0};
    release_status(ort, ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "starryhaven", &env), error, sizeof(error));
    if (error[0]) { set_error(buffer, buffer_len, error); return 2; }
    release_status(ort, ort->CreateSessionOptions(&opts), error, sizeof(error));
    if (error[0]) { set_error(buffer, buffer_len, error); return 2; }
    release_status(ort, ort->CreateSession(env, model_path, opts, &session), error, sizeof(error));
    if (error[0]) {
        set_error(buffer, buffer_len, error);
        ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env);
        return 3;
    }
    size_t used = 0;
    describe_value(ort, session, 1, (char*)buffer, buffer_len, &used);
    size_t n = 0;
    ort->SessionGetOutputCount(session, &n);
    for (size_t i = 0; i < n && used < buffer_len; i++) {
        OrtAllocator* alloc = NULL;
        ort->GetAllocatorWithDefaultOptions(&alloc);
        char* name = NULL;
        OrtTypeInfo* type_info = NULL;
        const OrtTensorTypeAndShapeInfo* shape = NULL;
        size_t dims = 0;
        int64_t d[8] = {0};
        ONNXTensorElementDataType elem = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
        ort->SessionGetOutputName(session, i, alloc, &name);
        ort->SessionGetOutputTypeInfo(session, i, &type_info);
        if (type_info) ort->CastTypeInfoToTensorInfo(type_info, &shape);
        if (shape) {
            ort->GetDimensionsCount(shape, &dims);
            if (dims > 8) dims = 8;
            ort->GetDimensions(shape, d, dims);
            ort->GetTensorElementType(shape, &elem);
        }
        int written = snprintf(buffer + used, buffer_len - used, "output[%zu] name=%s elem=%d dims=[", i, name ? name : "?", (int)elem);
        if (written > 0) used += (size_t)written;
        for (size_t j = 0; j < dims; j++) {
            written = snprintf(buffer + used, buffer_len - used, "%lld%s", (long long)d[j], j + 1 < dims ? "," : "");
            if (written > 0) used += (size_t)written;
        }
        written = snprintf(buffer + used, buffer_len - used, "]\n");
        if (written > 0) used += (size_t)written;
        if (type_info) ort->ReleaseTypeInfo(type_info);
        if (name) ort->AllocatorFree(alloc, name);
    }
    ort->ReleaseSession(session);
    ort->ReleaseSessionOptions(opts);
    ort->ReleaseEnv(env);
    return 0;
}

int sf_ort_skyseg_run(const char* model_path,
                      const float* input,
                      int width,
                      int height,
                      int output_index,
                      float* out_mask,
                      int* out_width,
                      int* out_height,
                      char* error,
                      size_t error_len) {
    const OrtApi* ort = api();
    if (!ort) { set_error(error, error_len, g_load_error); return 1; }

    OrtEnv* env = NULL;
    OrtSessionOptions* opts = NULL;
    OrtSession* session = NULL;
    OrtStatus* status = NULL;
    if ((status = ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "starryhaven", &env))) {
        release_status(ort, status, error, error_len); return 2;
    }
    if ((status = ort->CreateSessionOptions(&opts))) {
        release_status(ort, status, error, error_len); ort->ReleaseEnv(env); return 2;
    }
    if ((status = ort->CreateSession(env, model_path, opts, &session))) {
        release_status(ort, status, error, error_len);
        ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env); return 3;
    }

    OrtAllocator* alloc = NULL;
    ort->GetAllocatorWithDefaultOptions(&alloc);
    char* input_name = NULL;
    ort->SessionGetInputName(session, 0, alloc, &input_name);

    OrtMemoryInfo* mem_info = NULL;
    if ((status = ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem_info))) {
        release_status(ort, status, error, error_len);
        ort->ReleaseSession(session); ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env); return 4;
    }

    int64_t input_shape[4] = {1, 3, height, width};
    size_t input_count = (size_t)3 * (size_t)width * (size_t)height;
    OrtValue* input_tensor = NULL;
    // Input is copied because OrtValue does not own caller memory.
    float* input_copy = (float*)malloc(input_count * sizeof(float));
    if (!input_copy) {
        set_error(error, error_len, "out of memory");
        ort->ReleaseMemoryInfo(mem_info); ort->ReleaseSession(session); ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env); return 5;
    }
    memcpy(input_copy, input, input_count * sizeof(float));
    if ((status = ort->CreateTensorWithDataAsOrtValue(mem_info, input_copy, input_count * sizeof(float), input_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input_tensor))) {
        release_status(ort, status, error, error_len);
        free(input_copy); ort->ReleaseMemoryInfo(mem_info); ort->ReleaseSession(session); ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env); return 5;
    }

    size_t output_count = 0;
    ort->SessionGetOutputCount(session, &output_count);
    if (output_index < 0 || (size_t)output_index >= output_count) output_index = 0;
    char* output_name = NULL;
    ort->SessionGetOutputName(session, (size_t)output_index, alloc, &output_name);

    const char* input_names[1] = {input_name};
    const char* output_names[1] = {output_name};
    OrtValue* output_tensor = NULL;
    status = ort->Run(session, NULL, input_names, (const OrtValue* const*)&input_tensor, 1, output_names, 1, &output_tensor);
    if (status) {
        release_status(ort, status, error, error_len);
        ort->ReleaseValue(input_tensor); free(input_copy); if (output_name) ort->AllocatorFree(alloc, output_name);
        if (input_name) ort->AllocatorFree(alloc, input_name);
        ort->ReleaseMemoryInfo(mem_info); ort->ReleaseSession(session); ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env); return 6;
    }

    OrtTensorTypeAndShapeInfo* shape = NULL;
    ort->GetTensorTypeAndShape(output_tensor, &shape);
    size_t nd = 0;
    ort->GetDimensionsCount(shape, &nd);
    int64_t dims[8] = {0};
    if (nd > 8) nd = 8;
    ort->GetDimensions(shape, dims, nd);
    ort->ReleaseTensorTypeAndShapeInfo(shape);

    void* raw = NULL;
    ort->GetTensorMutableData(output_tensor, &raw);
    size_t total = 1;
    for (size_t i = 0; i < nd; i++) total *= (size_t)(dims[i] > 0 ? dims[i] : 1);
    // Detect a channel dimension: outputs are [1,1,H,W] or [1,H,W] or [H,W].
    int ow = width, oh = height;
    if (nd == 4) { ow = (int)dims[3]; oh = (int)dims[2]; }
    else if (nd == 3) { ow = (int)dims[2]; oh = (int)dims[1]; }
    else if (nd == 2) { ow = (int)dims[1]; oh = (int)dims[0]; }
    if (total < (size_t)ow * (size_t)oh) {
        snprintf(error, error_len, "unexpected output size %zu for %dx%d", total, ow, oh);
        ort->ReleaseValue(output_tensor); ort->ReleaseValue(input_tensor); free(input_copy);
        if (output_name) ort->AllocatorFree(alloc, output_name);
        if (input_name) ort->AllocatorFree(alloc, input_name);
        ort->ReleaseMemoryInfo(mem_info); ort->ReleaseSession(session); ort->ReleaseSessionOptions(opts); ort->ReleaseEnv(env);
        return 7;
    }
    memcpy(out_mask, raw, (size_t)ow * (size_t)oh * sizeof(float));
    *out_width = ow;
    *out_height = oh;

    ort->ReleaseValue(output_tensor);
    ort->ReleaseValue(input_tensor);
    free(input_copy);
    if (output_name) ort->AllocatorFree(alloc, output_name);
    if (input_name) ort->AllocatorFree(alloc, input_name);
    ort->ReleaseMemoryInfo(mem_info);
    ort->ReleaseSession(session);
    ort->ReleaseSessionOptions(opts);
    ort->ReleaseEnv(env);
    return 0;
}
