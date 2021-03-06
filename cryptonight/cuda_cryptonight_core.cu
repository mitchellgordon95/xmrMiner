#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>
#include "cuda.h"
#include "cuda_runtime.h"
#include "cryptonight.h"

#ifndef _WIN32
#include <unistd.h>
#endif

extern "C"
{
extern int device_arch[8][2];
extern int device_bfactor[8];
extern int device_bsleep[8];
}

#include "cuda_cryptonight_aes.hpp"
#include "cuda_device.hpp"

#if defined(XMRMINER_LARGEGRID) && (__CUDA_ARCH__ >= 300)
typedef uint64_t IndexType;
#else
typedef int IndexType;
#endif

__device__ __forceinline__ uint64_t cuda_mul128( uint64_t multiplier, uint64_t multiplicand, uint64_t* product_hi )
{
    *product_hi = __umul64hi( multiplier, multiplicand );
    return (multiplier * multiplicand );
}

template< typename T >
__device__ __forceinline__ T loadGlobal64( T * const addr )
{
    T x;
    asm volatile(
        "ld.global.cg.u64 %0, [%1];" : "=l"( x ) : "l"( addr )
    );
    return x;
}

template< typename T >
__device__ __forceinline__ T loadGlobal32( T * const addr )
{
    T x;
    asm volatile(
        "ld.global.cg.u32 %0, [%1];" : "=r"( x ) : "l"( addr )
    );
    return x;
}


template< typename T >
__device__ __forceinline__ void storeGlobal32( T* addr, T const & val )
{
    asm volatile(
        "st.global.cg.u32 [%0], %1;" : : "l"( addr ), "r"( val )
    );

}

__global__ void cryptonight_core_gpu_phase1( int threads, int bfactor, int partidx, uint32_t * __restrict__ long_state, uint32_t * __restrict__ ctx_state, uint32_t * __restrict__ ctx_key1 )
{
    __shared__ uint32_t sharedMemory[1024];

    cn_aes_gpu_init( sharedMemory );
    __syncthreads( );

    const int thread = ( blockDim.x * blockIdx.x + threadIdx.x ) >> 3;
    const int sub = ( threadIdx.x & 7 ) << 2;

    const int batchsize = 0x80000 >> bfactor;
    const int start = partidx * batchsize;
    const int end = start + batchsize;

    if ( thread < threads )
    {
        uint32_t key[40], text[4];

        MEMCPY8( key, ctx_key1 + thread * 40, 20 );
        if (partidx == 0)
        {
            MEMCPY8(text, ctx_state + thread * 50 + sub + 16, 2);
        }
        else
        {
            MEMCPY8(text, &long_state[((uint64_t) thread << 19) + sub + start - 32], 2);
        }
        __syncthreads();
        for (int i = start; i < end; i += 32)
        {
            cn_aes_pseudo_round_mut( sharedMemory, text, key );
            MEMCPY8( &long_state[( (uint64_t) thread << 19 ) + sub + i], text, 2 );
        }
    }
}

template< typename T >
__forceinline__ __device__ void unusedVar(const T&)
{
}

__forceinline__ __device__ uint32_t shuffle(volatile uint32_t* ptr, const uint32_t sub, const int val, const uint32_t src)
{
#if( __CUDA_ARCH__ < 300 )
    ptr[sub] = val;
    return ptr[src & 3];
#else
    unusedVar(ptr);
    unusedVar(sub);
    return __shfl(val, src, 4);
#endif
}

__device__ __forceinline__ uint32_t variant1_1(const uint32_t src)
 {
 	const uint8_t tmp = src >> 24;
 	const uint32_t table = 0x75310;
 	const uint8_t index = (((tmp >> 3) & 6) | (tmp & 1)) << 1;
 	return (src & 0x00ffffff) | ((tmp ^ ((table >> index) & 0x30)) << 24);
 }

template< uint32_t variant >
#ifdef XMR_THREADS
__launch_bounds__(XMRMINER_THREADS * 4)
#endif
__global__ void cryptonight_core_gpu_phase2(int threads, int bfactor, int partidx, uint32_t * d_long_state, uint32_t * d_ctx_a, uint32_t * d_ctx_b, const uint32_t * d_tweak1_2)
{
    __shared__ uint32_t sharedMemory[1024];

    cn_aes_gpu_init(sharedMemory);

    __syncthreads();

    const int thread = (blockDim.x * blockIdx.x + threadIdx.x) >> 2;
    const int sub = threadIdx.x & 3;
    const int sub2 = sub & 2;

#if( __CUDA_ARCH__ < 300 )
    extern __shared__ uint32_t shuffleMem[];
    volatile uint32_t* sPtr = (volatile uint32_t*)(shuffleMem + (threadIdx.x & 0xFFFFFFFC));
#else
    volatile uint32_t* sPtr = NULL;
#endif
    if (thread >= threads)
        return;

	uint32_t tweak1_2[2];
 	if (variant > 0)
 	{
 		tweak1_2[0] = d_tweak1_2[thread * 2];
 		tweak1_2[1] = d_tweak1_2[thread * 2 + 1];
 	}

    int i, k;
    uint32_t j;
    const int batchsize = ITER >> (2 + bfactor);
    const int start = partidx * batchsize;
    const int end = start + batchsize;
    uint32_t * long_state = &d_long_state[(IndexType) thread << 19];
    uint32_t * ctx_a = d_ctx_a + thread * 4;
    uint32_t * ctx_b = d_ctx_b + thread * 4;
    uint32_t a, d[2];
    uint32_t t1[2], t2[2], res;

    a = ctx_a[sub];
    d[1] = ctx_b[sub];
#pragma unroll 2
    for (i = start; i < end; ++i)
    {
#pragma unroll 2
        for (int x = 0; x < 2; ++x)
        {
            j = ((shuffle(sPtr, sub, a, 0) & 0x1FFFF0) >> 2) + sub;

            const uint32_t x_0 = loadGlobal32<uint32_t>(long_state + j);
            const uint32_t x_1 = shuffle(sPtr, sub, x_0, sub + 1);
            const uint32_t x_2 = shuffle(sPtr, sub, x_0, sub + 2);
            const uint32_t x_3 = shuffle(sPtr, sub, x_0, sub + 3);
            d[x] = a ^
                    t_fn0(x_0 & 0xff) ^
                    t_fn1((x_1 >> 8) & 0xff) ^
                    t_fn2((x_2 >> 16) & 0xff) ^
                    t_fn3((x_3 >> 24));


            //XOR_BLOCKS_DST(c, b, &long_state[j]);
            t1[0] = shuffle(sPtr, sub, d[x], 0);
            //long_state[j] = d[0] ^ d[1];
            const uint32_t z = d[0] ^ d[1];
 			storeGlobal32(long_state + j, (variant > 0 && sub == 2) ? variant1_1(z) : z);

            //MUL_SUM_XOR_DST(c, a, &long_state[((uint32_t *)c)[0] & 0x1FFFF0]);
            j = ((*t1 & 0x1FFFF0) >> 2) + sub;

            uint32_t yy[2];
            *((uint64_t*) yy) = loadGlobal64<uint64_t>(((uint64_t *) long_state)+(j >> 1));
            uint32_t zz[2];
            zz[0] = shuffle(sPtr, sub, yy[0], 0);
            zz[1] = shuffle(sPtr, sub, yy[1], 0);

            t1[1] = shuffle(sPtr, sub, d[x], 1);
#pragma unroll
            for (k = 0; k < 2; k++)
                t2[k] = shuffle(sPtr, sub, a, k + sub2);

            *((uint64_t *) t2) += sub2 ? (*((uint64_t *) t1) * *((uint64_t*) zz)) : __umul64hi(*((uint64_t *) t1), *((uint64_t*) zz));

            res = *((uint64_t *) t2) >> (sub & 1 ? 32 : 0);

            storeGlobal32(long_state + j, (variant > 0 && sub2) ? (tweak1_2[sub & 1] ^ res) : res);
            a = (sub & 1 ? yy[1] : yy[0]) ^ res;
        }
    }

    if (bfactor > 0)
    {
        ctx_a[sub] = a;
        ctx_b[sub] = d[1];
    }
}

__global__ void cryptonight_core_gpu_phase3( int threads, int bfactor, int partidx, const uint32_t * __restrict__ long_state, uint32_t * __restrict__ d_ctx_state, uint32_t * __restrict__ d_ctx_key2 )
{
    __shared__ uint32_t sharedMemory[1024];

    cn_aes_gpu_init( sharedMemory );
    __syncthreads( );

    int thread = ( blockDim.x * blockIdx.x + threadIdx.x ) >> 3;
    int sub = ( threadIdx.x & 7 ) << 2;

    const int batchsize = 0x80000 >> bfactor;
    const int start = partidx * batchsize;
    const int end = start + batchsize;

    if ( thread < threads )
    {
        uint32_t key[40], text[4], i, j;
        MEMCPY8( key, d_ctx_key2 + thread * 40, 20 );
        MEMCPY8( text, d_ctx_state + thread * 50 + sub + 16, 2 );

        __syncthreads( );
        for (i = start; i < end; i += 32)
        {

#pragma unroll
            for ( j = 0; j < 4; ++j )
                text[j] ^= long_state[( (IndexType) thread << 19 ) + (sub + i + j)];

            cn_aes_pseudo_round_mut( sharedMemory, text, key );
        }

        MEMCPY8( d_ctx_state + thread * 50 + sub + 16, text, 2 );
    }
}

template< uint32_t variant >
__host__ void cryptonight_core_cpu_hash_template( int thr_id, int blocks,
	int threads, uint32_t *d_long_state, uint32_t *d_ctx_state,
	uint32_t *d_ctx_a, uint32_t *d_ctx_b, uint32_t *d_ctx_key1, uint32_t *d_ctx_key2,
    uint32_t *d_ctx_tweak1_2)
{
    dim3 grid( blocks );
    dim3 block( threads );
    dim3 block4( threads << 2 );
    dim3 block8( threads << 3 );

    int i, partcount = 1 << device_bfactor[thr_id];

    /* bfactor for phase 1 and 2
     *
     * begin kernel splitting with user defined bfactor 5
     */
    int bfactor2 = device_bfactor[thr_id] - 4;
    if (bfactor2 < 0)
        bfactor2 = 0;
    int partcount2 = 1 << bfactor2;

    for (int i = 0; i < partcount2; i++)
    {

        cryptonight_core_gpu_phase1<<< grid, block8 >>>(
            blocks*threads,
            bfactor2,
            i,
            d_long_state,
            d_ctx_state,
            d_ctx_key1
        );
        exit_if_cudaerror( thr_id, __FILE__, __LINE__ );
        if ( partcount > 1 ) usleep( device_bsleep[thr_id] );
    }
    for ( i = 0; i < partcount; i++ )
    {
        cryptonight_core_gpu_phase2<variant><<< grid, block4, block4.x * sizeof (uint32_t) * static_cast<int> (device_arch[thr_id][0] < 3) >>>(
			blocks*threads, device_bfactor[thr_id], i, d_long_state, d_ctx_a, d_ctx_b, d_ctx_tweak1_2 );
        exit_if_cudaerror( thr_id, __FILE__, __LINE__ );
        if ( partcount > 1 ) usleep( device_bsleep[thr_id] );
    }

    for (int i = 0; i < partcount2; i++)
    {
        cryptonight_core_gpu_phase3<<< grid, block8 >>>(
            blocks*threads,
            bfactor2,
            i,
            d_long_state,
            d_ctx_state,
            d_ctx_key2
        );
        exit_if_cudaerror( thr_id, __FILE__, __LINE__ );
    }
}

__host__ void cryptonight_core_cpu_hash( int thr_id, int blocks,
	int threads, uint32_t *d_long_state, uint32_t *d_ctx_state,
	uint32_t *d_ctx_a, uint32_t *d_ctx_b, uint32_t *d_ctx_key1, uint32_t *d_ctx_key2,
	uint32_t variant, uint32_t *d_ctx_tweak1_2)
{

	if(variant == 0)
		cryptonight_core_cpu_hash_template<0>(thr_id, blocks, threads, d_long_state, d_ctx_state, d_ctx_a, d_ctx_b, d_ctx_key1,
			d_ctx_key2, d_ctx_tweak1_2);
	else if(variant >= 1)
		cryptonight_core_cpu_hash_template<1>(thr_id, blocks, threads, d_long_state, d_ctx_state, d_ctx_a, d_ctx_b, d_ctx_key1,
			d_ctx_key2, d_ctx_tweak1_2);
}

