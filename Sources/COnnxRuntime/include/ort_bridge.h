#ifndef ORT_BRIDGE_H
#define ORT_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns 1 when the ONNX Runtime dynamic library can be loaded, 0 otherwise.
int sf_ort_available(void);

/// Runs the SkySeg model. input is CHW float32 (3*width*height).
/// Writes a single-channel float mask of width*height into out_mask.
/// output_index selects which model output to use. Returns 0 on success.
int sf_ort_skyseg_run(const char* model_path,
                      const float* input,
                      int width,
                      int height,
                      int output_index,
                      float* out_mask,
                      int* out_width,
                      int* out_height,
                      char* error,
                      size_t error_len);

/// Describes the input and output shapes of a model. Returns 0 on success.
int sf_ort_describe(const char* model_path, char* buffer, size_t buffer_len);

#ifdef __cplusplus
}
#endif

#endif
