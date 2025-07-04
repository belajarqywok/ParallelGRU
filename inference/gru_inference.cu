#include <stdio.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include "CycleTimer.h"
#define TILE_SIZE 12

__global__ void
copy_data_kernel(float* x_t, int x_height, int x_width, float* data, int m, int n, int start_i, int j) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    int index_y = index / x_width;
    int index_x = index % x_width;
    if (index < x_height * x_width) {
        x_t[index] = data[(start_i + index_y) * n + j + index_x];
    }
}

__global__ void
mat_init_zeros_kernel(float* a, int size) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < size) {
        a[index] = 0.0;
    }
}

__global__ void
mat_copy_kernel(float* dest, float* src, int size) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < size) {
        dest[index] = src[index];
    }
}

__global__ void
mat_multiplication_kernel(float* a, float* b, float* c, int c_width, int c_height, int a_width) {

    __shared__ float sA[TILE_SIZE][TILE_SIZE];
    __shared__ float sB[TILE_SIZE][TILE_SIZE];

    int row = blockDim.y * blockIdx.y + threadIdx.y;
    int col = blockDim.x * blockIdx.x + threadIdx.x;

    float tmp = 0.0;
    sA[threadIdx.y][threadIdx.x] = 0.0;
    sB[threadIdx.y][threadIdx.x] = 0.0;

    for (int k = 0; k < (a_width - 1) / TILE_SIZE + 1; ++k) {
        if ((row < c_height) && (threadIdx.x + k * TILE_SIZE < a_width)) {
            sA[threadIdx.y][threadIdx.x] = a[row * a_width + threadIdx.x + k * TILE_SIZE];
        } else {
            sA[threadIdx.y][threadIdx.x] = 0.0;
        }
        if ((col < c_width) && (threadIdx.y + k * TILE_SIZE < a_width)) {
            sB[threadIdx.y][threadIdx.x] = b[(threadIdx.y + k * TILE_SIZE) * c_width + col];
        } else {
            sB[threadIdx.y][threadIdx.x] = 0.0;
        }
        __syncthreads();

        for (int j = 0; j < TILE_SIZE; ++j) {
            tmp += sA[threadIdx.y][j] * sB[j][threadIdx.x];
        }
    }
    if (row < c_height && col < c_width) {
        c[row * c_width + col] = tmp;
    }
    
}

__global__ void 
mat_add_kernel(float* a, float* b, float* res, int width, int height) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < width * height) 
        res[index] = a[index] + b[index];
}

__global__ void 
mat_add_b_kernel(float* a, float* b, float* res, int width, int height) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < width * height) 
        res[index] = a[index] + b[index % width];
}

__global__ void 
mat_one_sub_kernel(float* a, float* res, int width, int height) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < width * height) 
        res[index] = 1 - a[index];
}

__global__ void 
mat_hadamard_kernel(float*a, float* b, float* res, int width, int height) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < width * height) 
        res[index] = a[index] * b[index];
}

__global__ void 
mat_sigmoid_kernel(float* a, int width, int height) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < width * height) 
        a[index] = 1 / (1 + exp(-1 * a[index]));
}

__global__ void 
mat_tanh_kernel(float* a, int width, int height) {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < width * height) 
        a[index] = tanh(a[index]);
}

// x_t: width: 28, height: batch_size
// old_h_t: width: hidden_unit, height: batch_size
// new_h_t: width: hidden_unit, height: batch_size
// w_z, w_r, w_h: width: hidden_unit, height: 28
// u_z, u_r, u_h: width: hidden_unit, height: hidden_unit
// b_z, b_r, b_h: width: hidden_unit, height: 1
void gru_forward_kernel(int batch_size, int x_width, int hidden_unit,
                float* x_t, float* old_h_t, float* new_h_t,
                float* w_z, float* w_r, float* w_h,
                float* u_z, float* u_r, float* u_h,
                float* b_z, float* b_r, float* b_h) {

    const int threadsPerBlock = 512;
    const int blocks = (hidden_unit * batch_size + threadsPerBlock - 1) / threadsPerBlock;
    dim3 dimGrid((hidden_unit/TILE_SIZE) + 1, (batch_size/TILE_SIZE) + 1, 1);//Number of Blocks required
    dim3 dimBlock(TILE_SIZE, TILE_SIZE, 1);//Number of threads in each block


    float* tmp1;
    float* tmp2;
    cudaMalloc((void **)&tmp1, hidden_unit * batch_size * sizeof(float));
    cudaMalloc((void **)&tmp2, hidden_unit * batch_size * sizeof(float));

    // z_t = sigmoid(x_t * w_z + old_h_t * u_z + b_z)
    mat_multiplication_kernel<<<dimGrid, dimBlock>>>(x_t, w_z, tmp1, hidden_unit, batch_size, x_width);
    mat_multiplication_kernel<<<dimGrid, dimBlock>>>(old_h_t, u_z, tmp2, hidden_unit, batch_size, hidden_unit);

    float* z_t;
    cudaMalloc((void **)&z_t, hidden_unit * batch_size * sizeof(float));
    mat_add_kernel<<<blocks, threadsPerBlock>>>(tmp1, tmp2, z_t, hidden_unit, batch_size); 
    mat_add_b_kernel<<<blocks, threadsPerBlock>>>(z_t, b_z, z_t, hidden_unit, batch_size);
    mat_sigmoid_kernel<<<blocks, threadsPerBlock>>>(z_t, hidden_unit, batch_size);

    // r_t = sigmoid(x_t * w_r + old_h_t * u_r + b_r)
    mat_multiplication_kernel<<<dimGrid, dimBlock>>>(x_t, w_r, tmp1, hidden_unit, batch_size, x_width);
    mat_multiplication_kernel<<<dimGrid, dimBlock>>>(old_h_t, u_r, tmp2, hidden_unit, batch_size, hidden_unit);
    
    float* r_t;
    cudaMalloc((void **)&r_t, hidden_unit * batch_size * sizeof(float));

    mat_add_kernel<<<blocks, threadsPerBlock>>>(tmp1, tmp2, r_t, hidden_unit, batch_size); 
    mat_add_b_kernel<<<blocks, threadsPerBlock>>>(r_t, b_r, r_t, hidden_unit, batch_size);
    mat_sigmoid_kernel<<<blocks, threadsPerBlock>>>(r_t, hidden_unit, batch_size);

    // h_hat = phi(x_t * w_h + (r_t . old_h_t) * u_h + b_h)
    mat_multiplication_kernel<<<dimGrid, dimBlock>>>(x_t, w_h, tmp1, hidden_unit, batch_size, x_width);
    mat_hadamard_kernel<<<blocks, threadsPerBlock>>>(r_t, old_h_t, r_t, hidden_unit, batch_size);
    mat_multiplication_kernel<<<dimGrid, dimBlock>>>(r_t, u_h, tmp2, hidden_unit, batch_size, hidden_unit);

    float* h_hat;
    cudaMalloc((void **)&h_hat, hidden_unit * batch_size * sizeof(float));

    mat_add_kernel<<<blocks, threadsPerBlock>>>(tmp1, tmp2, h_hat, hidden_unit, batch_size); 
    mat_add_b_kernel<<<blocks, threadsPerBlock>>>(h_hat, b_h, h_hat, hidden_unit, batch_size);
    mat_tanh_kernel<<<blocks, threadsPerBlock>>>(h_hat, hidden_unit, batch_size);

    // new_h_t = (1-z_t).old_h_t + z_t.h_hat
    float* tmp3;
    cudaMalloc((void **)&tmp3, hidden_unit * batch_size * sizeof(float));
    mat_one_sub_kernel<<<blocks, threadsPerBlock>>>(z_t, tmp3, hidden_unit, batch_size);
    mat_hadamard_kernel<<<blocks, threadsPerBlock>>>(tmp3, old_h_t, tmp3, hidden_unit, batch_size);
    mat_hadamard_kernel<<<blocks, threadsPerBlock>>>(z_t, h_hat, h_hat, hidden_unit, batch_size);
    mat_add_kernel<<<blocks, threadsPerBlock>>>(tmp3, h_hat, new_h_t, hidden_unit, batch_size);

}

void inference_cuda(int num_data, int batch_size, int window_size, int x_width, int hidden_unit, float step_size,
                        float* old_h_t, float* new_h_t,
                        float* w_z, float* w_r, float* w_h,
                        float* u_z, float* u_r, float* u_h,
                        float* b_z, float* b_r, float* b_h,
                        float* dense, float* predict, float* arr_data, int m, int n) {

    const int threadsPerBlock = 512;

    double startTime = CycleTimer::currentSeconds();

    // allocate variables
    float *device_data;

    float *device_x_t;
    float *device_old_h_t;
    float *device_new_h_t;
    float *device_w_z;
    float *device_w_r;
    float *device_w_h;
    float *device_u_z;
    float *device_u_r;
    float *device_u_h;
    float *device_b_z;
    float *device_b_r;
    float *device_b_h;

    float *device_dense;
    float *device_predict;

    cudaMalloc((void **)&device_data, m * n * sizeof(float));

    cudaMalloc((void **)&device_x_t, batch_size * x_width * sizeof(float));
    cudaMalloc((void **)&device_old_h_t, batch_size * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_new_h_t, batch_size * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_w_z, x_width * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_w_h, x_width * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_w_r, x_width * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_u_z, hidden_unit * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_u_h, hidden_unit * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_u_r, hidden_unit * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_b_z, 1 * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_b_h, 1 * hidden_unit * sizeof(float));
    cudaMalloc((void **)&device_b_r, 1 * hidden_unit * sizeof(float));

    cudaMalloc((void **)&device_dense, hidden_unit * 1 * sizeof(float));
    cudaMalloc((void **)&device_predict, batch_size * 1 * sizeof(float));

    cudaMemcpy(device_data, arr_data, m * n * sizeof(float), cudaMemcpyHostToDevice);

    cudaMemcpy(device_old_h_t, old_h_t, batch_size * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_new_h_t, new_h_t, batch_size * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_w_z, w_z, x_width * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_w_h, w_h, x_width * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_w_r, w_r, x_width * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_u_z, u_z, hidden_unit * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_u_h, u_h, hidden_unit * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_u_r, u_r, hidden_unit * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_b_z, b_z, 1 * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_b_h, b_h, 1 * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_b_r, b_r, 1 * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_dense, dense, 1 * hidden_unit * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(device_predict, predict, 1 * batch_size * sizeof(float), cudaMemcpyHostToDevice);

    const int blocks_h = (hidden_unit * batch_size + threadsPerBlock - 1) / threadsPerBlock;
    const int blocks_predict = (batch_size + threadsPerBlock - 1) / threadsPerBlock;
    const int blocks_x = (x_width * batch_size + threadsPerBlock - 1) / threadsPerBlock;

    double iterStartTime = CycleTimer::currentSeconds();

    // One iteration, loop through all data point
    for (int i = 0; i < num_data; i += batch_size) {
        double forwardStartTime = CycleTimer::currentSeconds();

        // batch_size * (num_data * x_width)
        int start_i = i;
        int end_i = min(num_data, i + batch_size);
        int batch = end_i - start_i;

        // for each time step
        for (int j = 0; j < window_size; j++) {

            copy_data_kernel<<<blocks_x, threadsPerBlock>>>(device_x_t, batch, x_width, device_data, m, n, start_i, j);

            // one forward iteration: 
            gru_forward_kernel(batch_size, x_width, hidden_unit, device_x_t, device_old_h_t, device_new_h_t, 
                device_w_z, device_w_r, device_w_h, device_u_z, device_u_r, device_u_h, device_b_z, device_b_r, device_b_h); 

            // update h_t for the next round
            mat_copy_kernel<<<blocks_h, threadsPerBlock>>>(device_old_h_t, device_new_h_t, batch_size * hidden_unit);
            mat_init_zeros_kernel<<<blocks_h, threadsPerBlock>>>(device_new_h_t, batch_size * hidden_unit);

        }

        // inference
        mat_multiplication_kernel<<<blocks_predict, threadsPerBlock>>>(device_dense, device_old_h_t, device_predict, batch_size, 1, hidden_unit);
        cudaMemcpy(predict, device_predict, batch_size * sizeof(float), cudaMemcpyDeviceToHost);

    }

    double iterEndTime = CycleTimer::currentSeconds();

    cudaFree(device_x_t);
    cudaFree(device_old_h_t);
    cudaFree(device_new_h_t);
    cudaFree(device_w_z);
    cudaFree(device_w_h);
    cudaFree(device_w_r);
    cudaFree(device_u_z);
    cudaFree(device_u_h);
    cudaFree(device_u_r);
    cudaFree(device_b_z);
    cudaFree(device_b_h);
    cudaFree(device_b_r);
    cudaFree(device_dense);
    cudaFree(device_predict);

    double endTime = CycleTimer::currentSeconds();
    printf("GPU Overall: %.3f ms\n", 1000.f * (endTime - startTime));
    printf("GPU Compute: %.3f ms\n", 1000.f * (iterEndTime - iterStartTime));
}


void
print_cuda_info() {

    // for fun, just print out some stats on the machine

    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n",
               static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n");
}



// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
