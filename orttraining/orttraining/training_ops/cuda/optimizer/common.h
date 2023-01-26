// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once
#include "core/providers/cuda/cuda_common.h"

namespace onnxruntime {
namespace cuda {

template <typename T>
Status CopyIfNotSameBuffer(cudaStream_t stream, const Tensor& source_tensor, Tensor& target_tensor) {
  const T* source = source_tensor.template Data<T>();
  T* target = target_tensor.template MutableData<T>();
  if (target != source) {
    CUDA_RETURN_IF_ERROR(cudaMemcpyAsync(target, source, source_tensor.SizeInBytes(), cudaMemcpyDeviceToDevice,
                                         stream));
  }
  return Status::OK();
}

Status CopyIfNotSameCUDABuffer(OpKernelContext* ctx, size_t number_of_values, const TensorSeq* values,
                               TensorSeq* updated_values);

}  // namespace cuda
}  // namespace onnxruntime
