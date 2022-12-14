#include <stdio.h>
#include <memory.h>

#include "cuda_helper.h"
#include <sm_30_intrinsics.h>

static uint32_t *d_tempBranch1Nonces[MAX_GPUS];
static uint32_t *d_numValid[MAX_GPUS];
static uint32_t *h_numValid[MAX_GPUS];

static uint32_t *d_partSum[2][MAX_GPUS]; // fuer bis zu vier partielle Summen


// True/False tester
typedef uint32_t(*cuda_compactTestFunction_t)(const uint32_t *inpHash);

static __device__ __forceinline__ uint32_t QuarkTrueTest(const uint32_t *inpHash)
{
	return ((inpHash[0] & 0x08) == 0x08);
}

static __device__ __forceinline__ uint32_t QuarkFalseTest(const uint32_t *inpHash)
{
	return ((inpHash[0] & 0x08) == 0);
}

__device__ cuda_compactTestFunction_t d_QuarkTrueFunction = QuarkTrueTest, d_QuarkFalseFunction = QuarkFalseTest;

cuda_compactTestFunction_t h_QuarkTrueFunction[MAX_GPUS], h_QuarkFalseFunction[MAX_GPUS];

// Setup-Funktionen
__host__ void quark_compactTest_cpu_init(int thr_id, uint32_t threads)
{
	CUDA_SAFE_CALL(cudaMemcpyFromSymbolAsync(&h_QuarkTrueFunction[thr_id], d_QuarkTrueFunction, sizeof(cuda_compactTestFunction_t), 0, cudaMemcpyDeviceToHost, gpustream[thr_id]));
	CUDA_SAFE_CALL(cudaMemcpyFromSymbolAsync(&h_QuarkFalseFunction[thr_id], d_QuarkFalseFunction, sizeof(cuda_compactTestFunction_t), 0, cudaMemcpyDeviceToHost, gpustream[thr_id]));

	// wir brauchen auch Speicherplatz auf dem Device
	CUDA_SAFE_CALL(cudaMalloc(&d_tempBranch1Nonces[thr_id], sizeof(uint32_t) * threads * 2));
	CUDA_SAFE_CALL(cudaMalloc(&d_numValid[thr_id], 2 * sizeof(uint32_t)));
	CUDA_SAFE_CALL(cudaMallocHost(&h_numValid[thr_id], 2 * sizeof(uint32_t)));

	uint32_t s1;
	s1 = (threads / 256) * 2;

	CUDA_SAFE_CALL(cudaMalloc(&d_partSum[0][thr_id], sizeof(uint32_t) * s1)); // BLOCKSIZE (Threads/Block)
	CUDA_SAFE_CALL(cudaMalloc(&d_partSum[1][thr_id], sizeof(uint32_t) * s1)); // BLOCKSIZE (Threads/Block)
}

// Die Summenfunktion (vom NVIDIA SDK)
__global__ void quark_compactTest_gpu_SCAN(uint32_t *data, int width, uint32_t *partial_sums=NULL, cuda_compactTestFunction_t testFunc=NULL, uint32_t threads=0, uint32_t startNounce=0, const uint32_t *inpHashes=NULL, const uint32_t *d_validNonceTable=NULL)
{
	__shared__ uint32_t sums[32];
	int id = ((blockIdx.x * blockDim.x) + threadIdx.x);
	//int lane_id = id % warpSize;
	int lane_id = id % width;
	// determine a warp_id within a block
	 //int warp_id = threadIdx.x / warpSize;
	int warp_id = threadIdx.x / width;

	sums[lane_id] = 0;

	// Below is the basic structure of using a shfl instruction
	// for a scan.
	// Record "value" as a variable - we accumulate it along the way
	uint32_t value;
	if(testFunc != NULL)
	{
		if (id < threads)
		{
			if(d_validNonceTable == NULL)
			{
				// keine Nonce-Liste
				value = (*testFunc)(&inpHashes[id << 4]);
			}else
			{
				// Nonce-Liste verf?Ebar
				int nonce = d_validNonceTable[id] - startNounce;
				value = (*testFunc)(&inpHashes[nonce << 4]);
			}			
		}else
		{
			value = 0;
		}
	}else
	{
		value = data[id];
	}

	__syncthreads();

	// Now accumulate in log steps up the chain
	// compute sums, with another thread's value who is
	// distance delta away (i).  Note
	// those threads where the thread 'i' away would have
	// been out of bounds of the warp are unaffected.  This
	// creates the scan sum.
#pragma unroll

	for (int i=1; i<=width; i*=2)
	{
		uint32_t n = SHFL_UP((int)value, i, width);

		if (lane_id >= i) value += n;
	}

	// value now holds the scan value for the individual thread
	// next sum the largest values for each warp

	// write the sum of the warp to smem
	//if (threadIdx.x % warpSize == warpSize-1)
	if (threadIdx.x % width == width-1)
	{
		sums[warp_id] = value;
	}

	__syncthreads();

	//
	// scan sum the warp sums
	// the same shfl scan operation, but performed on warp sums
	//
	if (warp_id == 0)
	{
		uint32_t warp_sum = sums[lane_id];

		for (int i=1; i<=width; i*=2)
		{
			uint32_t n = SHFL_UP((int)warp_sum, i, width);

		if (lane_id >= i) warp_sum += n;
		}

		sums[lane_id] = warp_sum;
	}

	__syncthreads();

	// perform a uniform add across warps in the block
	// read neighbouring warp's sum and add it to threads value
	uint32_t blockSum = 0;

	if (warp_id > 0)
	{
		blockSum = sums[warp_id-1];
	}

	value += blockSum;

	// Now write out our result
	data[id] = value;

	// last thread has sum, write write out the block's sum
	if (partial_sums != NULL && threadIdx.x == blockDim.x-1)
	{
		partial_sums[blockIdx.x] = value;
	}
}

// Uniform add: add partial sums array
__global__ void quark_compactTest_gpu_ADD(uint32_t *data, const uint32_t *partial_sums, int len)
{
	__shared__ uint32_t buf;
	int id = ((blockIdx.x * blockDim.x) + threadIdx.x);

	if (id > len) return;

	if (threadIdx.x == 0)
	{
		buf = partial_sums[blockIdx.x];
	}

	__syncthreads();
	data[id] += buf;
}

// Der Scatter
__global__ void quark_compactTest_gpu_SCATTER(const uint32_t *sum, uint32_t *outp, cuda_compactTestFunction_t testFunc, uint32_t threads=0, uint32_t startNounce=0, const uint32_t *inpHashes=NULL, const uint32_t *d_validNonceTable=NULL)
{
	int id = ((blockIdx.x * blockDim.x) + threadIdx.x);
	uint32_t actNounce = id;
	uint32_t value;
	if (id < threads)
	{
//		const uint32_t nounce = startNounce + id;
		if(d_validNonceTable == NULL)
		{
			// keine Nonce-Liste
			value = (*testFunc)(&inpHashes[id << 4]);
		}else
		{
			// Nonce-Liste verf?Ebar
			int nonce = d_validNonceTable[id] - startNounce;
			actNounce = nonce;
			value = (*testFunc)(&inpHashes[nonce << 4]);
		}

	}else
	{
		value = 0;
	}

	if( value )
	{
		int idx = sum[id];
		if(idx > 0)
			outp[idx-1] = startNounce + actNounce;
	}
}

__host__ static uint32_t quark_compactTest_roundUpExp(uint32_t val)
{
	if(val == 0)
		return 0;

	uint32_t mask = 0x80000000;
	while( (val & mask) == 0 ) mask = mask >> 1;

	if( (val & (~mask)) != 0 )
		return mask << 1;

	return mask;
}

__host__ void quark_compactTest_cpu_singleCompaction(int thr_id, uint32_t threads, uint32_t *nrm,
														uint32_t *d_nonces1, cuda_compactTestFunction_t function,
														uint32_t startNounce, const uint32_t *inpHashes, const uint32_t *d_validNonceTable)
{
	int orgThreads = threads;
	threads = (int)quark_compactTest_roundUpExp((uint32_t)threads);
	// threadsPerBlock ausrechnen
	int blockSize = 256;
	int nSummen = threads / blockSize;

	int thr1 = (threads+blockSize-1) / blockSize;
	int thr2 = threads / (blockSize*blockSize);
	int blockSize2 = (nSummen < blockSize) ? nSummen : blockSize;
	int thr3 = (nSummen + blockSize2-1) / blockSize2;

	bool callThrid = (thr2 > 0) ? true : false;

	// Erster Initialscan
	quark_compactTest_gpu_SCAN<<<thr1,blockSize, 0, gpustream[thr_id]>>>(d_tempBranch1Nonces[thr_id], 32, d_partSum[0][thr_id], function, orgThreads, startNounce, inpHashes, d_validNonceTable);	
	CUDA_SAFE_CALL(cudaGetLastError());

	// weitere Scans
	if(callThrid)
	{		
		quark_compactTest_gpu_SCAN<<<thr2,blockSize, 0, gpustream[thr_id]>>>(d_partSum[0][thr_id], 32, d_partSum[1][thr_id]);
		CUDA_SAFE_CALL(cudaGetLastError());
		quark_compactTest_gpu_SCAN << <1, thr2, 0, gpustream[thr_id] >> >(d_partSum[1][thr_id], (thr2>32) ? 32 : thr2);
		CUDA_SAFE_CALL(cudaGetLastError());
	}
	else
	{
		quark_compactTest_gpu_SCAN<<<thr3,blockSize2, 0, gpustream[thr_id]>>>(d_partSum[0][thr_id], (blockSize2>32) ? 32 : blockSize2);
		CUDA_SAFE_CALL(cudaGetLastError());
	}

	if(callThrid)
	{
		cudaMemcpyAsync(nrm, &(d_partSum[1][thr_id])[thr2 - 1], sizeof(uint32_t), cudaMemcpyDeviceToHost, gpustream[thr_id]);
		CUDA_SAFE_CALL(cudaGetLastError());
	}
	else
	{
		cudaMemcpyAsync(nrm, &(d_partSum[0][thr_id])[nSummen - 1], sizeof(uint32_t), cudaMemcpyDeviceToHost, gpustream[thr_id]);
		CUDA_SAFE_CALL(cudaGetLastError());
	}
	
	// Addieren
	if(callThrid)
	{
		quark_compactTest_gpu_ADD<<<thr2-1, blockSize, 0, gpustream[thr_id]>>>(d_partSum[0][thr_id]+blockSize, d_partSum[1][thr_id], blockSize*thr2);
		CUDA_SAFE_CALL(cudaGetLastError());
	}
	quark_compactTest_gpu_ADD<<<thr1-1, blockSize, 0, gpustream[thr_id]>>>(d_tempBranch1Nonces[thr_id]+blockSize, d_partSum[0][thr_id], threads);
	CUDA_SAFE_CALL(cudaGetLastError());

	// Scatter
	quark_compactTest_gpu_SCATTER<<<thr1,blockSize,0, gpustream[thr_id]>>>(d_tempBranch1Nonces[thr_id], d_nonces1, 
		function, orgThreads, startNounce, inpHashes, d_validNonceTable);
	CUDA_SAFE_CALL(cudaGetLastError());
	cudaStreamSynchronize(gpustream[thr_id]);
}

////// ACHTUNG: Diese funktion geht aktuell nur mit threads > 65536 (Am besten 256 * 1024 oder 256*2048)
__host__ void quark_compactTest_cpu_dualCompaction(int thr_id, uint32_t threads, uint32_t *nrm,
													 uint32_t *d_nonces1, uint32_t *d_nonces2,
													 uint32_t startNounce, const uint32_t *inpHashes, const uint32_t *d_validNonceTable)
{
	quark_compactTest_cpu_singleCompaction(thr_id, threads, &nrm[0], d_nonces1, h_QuarkTrueFunction[thr_id], startNounce, inpHashes, d_validNonceTable);
	quark_compactTest_cpu_singleCompaction(thr_id, threads, &nrm[1], d_nonces2, h_QuarkFalseFunction[thr_id], startNounce, inpHashes, d_validNonceTable);
}

__host__ void quark_compactTest_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, const uint32_t *inpHashes, const uint32_t *d_validNonceTable,
											uint32_t *d_nonces1, uint32_t *nrm1,
											uint32_t *d_nonces2, uint32_t *nrm2)
{
	// Wenn validNonceTable genutzt wird, dann werden auch nur die Nonces betrachtet, die dort enthalten sind
	// "threads" ist in diesem Fall auf die L?nge dieses Array's zu setzen!
	
	quark_compactTest_cpu_dualCompaction(thr_id, threads,
		h_numValid[thr_id], d_nonces1, d_nonces2,
		startNounce, inpHashes, d_validNonceTable);

	*nrm1 = h_numValid[thr_id][0];
	*nrm2 = h_numValid[thr_id][1];
}

__host__ void quark_compactTest_single_false_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *inpHashes, uint32_t *d_validNonceTable,
											uint32_t *d_nonces1, uint32_t *nrm1)
{
	// Wenn validNonceTable genutzt wird, dann werden auch nur die Nonces betrachtet, die dort enthalten sind
	// "threads" ist in diesem Fall auf die L?nge dieses Array's zu setzen!

	quark_compactTest_cpu_singleCompaction(thr_id, threads, h_numValid[thr_id], d_nonces1, h_QuarkFalseFunction[thr_id], startNounce, inpHashes, d_validNonceTable);

	*nrm1 = h_numValid[thr_id][0];
}
