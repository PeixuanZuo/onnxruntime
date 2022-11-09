// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "core/providers/cuda/tensor/scatter_nd_impl.h"
#include "core/providers/cuda/cu_inc/common.cuh"
#include "core/providers/cuda/atomic/common.cuh"
#include <curand_kernel.h>

namespace onnxruntime {
namespace cuda {

template <typename T>
__global__ void _ScatterNDKernel(
    T* output_data,
    const size_t num_indices,
    const int64_t* indices_data,
    const int64_t last_index_dimension,
    const int64_t* element_counts_and_input_dims,
    const T* updates_data,
    const size_t num_updates_elements) {
  CALCULATE_ELEMENTWISE_INDEX_OR_EXIT(id, num_indices);

  // Compute the base offset into the output data
  int64_t data_offset = 0;

  size_t indices_start = last_index_dimension * id;
  size_t indices_end = indices_start + last_index_dimension;
  for (size_t i = indices_start; i < indices_end; ++i) {
    int64_t index = indices_data[i];

    int64_t element_count_dim = element_counts_and_input_dims[i - indices_start];
    int64_t dim_value = element_counts_and_input_dims[i - indices_start + last_index_dimension];

    // Clamp the index if out of range
    // This would have been an error in the CPU kernel, but throwing in the CUDA EP
    // is hard. This is the approach taken by other frameworks for out of bound indices
    // in their corresponding GPU backends as well.
    // index >= -dim_value && index < dim_value

    if (index >= 0) {
      if (index >= dim_value) {
        index = dim_value - 1;
      }
    } else {
      if (index < -dim_value) {
        index = 0;
      } else {
        index += dim_value;
      }
    }

    data_offset += (index * element_count_dim);
  }

  const T* updates_data_base = updates_data + num_updates_elements * id;
  T* output_data_base = output_data + data_offset;

  for (size_t i = 0; i < num_updates_elements; ++i) {
    output_data_base[i] = updates_data_base[i];
  }
}

Status ScatterNDImpl(
    cudaStream_t stream,
    void* output_data,
    const size_t element_size,
    const size_t num_indices,
    const int64_t* indices_data,
    const int64_t last_index_dimension,
    const int64_t* element_counts_and_input_dims,
    const void* updates_data,
    const size_t num_updates_elements) {
  if (num_indices == 0)
    return Status::OK();

  // Parallelize on number of indices
  int blocksPerGrid = static_cast<int>(ceil(static_cast<float>(num_indices) / GridDim::maxThreadsPerBlock));

  switch (element_size) {
    case sizeof(int8_t):
      _ScatterNDKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          reinterpret_cast<int8_t*>(output_data),
          num_indices,
          indices_data,
          last_index_dimension,
          element_counts_and_input_dims,
          reinterpret_cast<const int8_t*>(updates_data),
          num_updates_elements);
      break;

    case sizeof(int16_t):
      _ScatterNDKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          reinterpret_cast<int16_t*>(output_data),
          num_indices,
          indices_data,
          last_index_dimension,
          element_counts_and_input_dims,
          reinterpret_cast<const int16_t*>(updates_data),
          num_updates_elements);
      break;

    case sizeof(int32_t):
      _ScatterNDKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          reinterpret_cast<int32_t*>(output_data),
          num_indices,
          indices_data,
          last_index_dimension,
          element_counts_and_input_dims,
          reinterpret_cast<const int32_t*>(updates_data),
          num_updates_elements);
      break;

    case sizeof(int64_t):
      _ScatterNDKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          reinterpret_cast<int64_t*>(output_data),
          num_indices,
          indices_data,
          last_index_dimension,
          element_counts_and_input_dims,
          reinterpret_cast<const int64_t*>(updates_data),
          num_updates_elements);
      break;

    default:
      // Shouldn't hit this
      return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Type not supported for ScatterND operator");
  }

  return Status::OK();
}

__global__ void cuda_random_uniform_kernel(half* buffer, const int size) {
  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  curandState_t local_state;
  curand_init((unsigned long long int)1337, idx, 0, &local_state);
  for (int index = idx; index < size; index += blockDim.x * gridDim.x) {
    buffer[index] = (half)(curand_uniform(&local_state) * 0.2f - 0.1f);
    // buffer[index] = (T)(0.0f);
  }
}

void cudaRandomUniform(cudaStream_t stream, void* buffer, const int size) {
  cuda_random_uniform_kernel<<<256, 256, 0, stream>>>(reinterpret_cast<half*>(buffer), size);
}

template <unsigned TPB>
__global__ void SubnormalFlushKernel(half* output,
                                     const int hidden_size,
                                     int batch_size,
                                     int sequence_length,
                                     int flush_all_to_zero) {
  const int sequence_position = blockIdx.y * gridDim.x + blockIdx.x;

  const int output_offset = sequence_position * hidden_size;

  for (int it = threadIdx.x; it < hidden_size; it += TPB) {
    int offset = output_offset + it;
    short temp = *reinterpret_cast<short*>(&output[offset]);
    if (flush_all_to_zero == 1) {
      output[offset] = half(0);    
    } else {
      if ((temp & 0x7C00) == 0) {
        output[offset] = half(0);
      } else {
        output[offset] = output[offset];
      }
    }

  }
}

void SubnormalFlush(cudaStream_t stream,
                    void* output,
                    const int hidden_size,
                    int batch_size,
                    int sequence_length,
                    int flush_all_to_zero) {
  constexpr int tpb = 256;
  const dim3 grid(sequence_length, batch_size, 1);
  const dim3 block(tpb, 1, 1);

  SubnormalFlushKernel<tpb>
      <<<grid, block, 0, stream>>>(reinterpret_cast<half*>(output), hidden_size, batch_size, sequence_length, flush_all_to_zero);
}

}  // namespace cuda
}  // namespace onnxruntime
