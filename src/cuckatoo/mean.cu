// Cuckatoo Cycle, a memory-hard proof-of-work by John Tromp
// Copyright (c) 2018-2020 Jiri Vadura (photon) and John Tromp
// This software is covered by the FAIR MINING license

#include <stdio.h>
#include <string.h>
#include <vector>
#include <assert.h>
#include "cuckatoo.h"
#include "graph.hpp"
#include "../crypto/siphash.cuh"
#include "../crypto/blake2.h"

typedef uint8_t u8;
typedef uint16_t u16;

// number of invocations of seeding kernel
// larger values reduce pressure on TLB
// which appears to be an issue on GTX cards
#ifndef NTLB
#define NTLB 1
#endif
// number of slices in edge splitting kernel
// larger values reduce memory use
// which is proportional to 1+1/NMEM
#ifndef NMEM
#define NMEM 4
#endif
// after seeding, main memory buffer is a NMEM x NTLB matrix
// of blocks of buckets
#define NMEMTLB (NMEM * NTLB)

#ifndef MAXSOLS
#define MAXSOLS 4
#endif

#ifndef IDXSHIFT
// number of bits of compression of surviving edge endpoints
// reduces space used in cycle finding, but too high a value
// results in NODE OVERFLOW warnings and fake cycles
// tag relay achieves a 2^12 reduction in edges
#define IDXSHIFT 12
#endif

const u32 MAXEDGES = NEDGES >> IDXSHIFT;

typedef uint64_t u64; // save some typing

#ifndef BUCKBITS
// assumes at least 2^18 bits of shared mem (32 KB) on thread block
// #define BUCKBITS (EDGEBITS-18)
#define BUCKBITS 12
#endif

const u32 NB       = 1 << BUCKBITS;
const u32 NB_NTLB  = NB / NTLB;
const u32 NB_NMEM  = NB / NMEM;
const u32 ZBITS     = EDGEBITS - BUCKBITS;
const u32 NZ        = 1 << ZBITS;
const u32 ZMASK     = NZ - 1;

// buckets are a little oversized to allow for variance in distribution
#define NEPS 128
#ifndef NEPS_A
#define NEPS_A 133
#endif
// max number of edges per bucket after seeding
const u32 EDGES_A = NZ * NEPS_A / NEPS;
#ifndef NEPS_B
#define NEPS_B 85
#endif
// max number of edges per bucket after one trim
const u32 EDGES_B = NZ * NEPS_B / NEPS;

__constant__ uint2 recoveredges[PROOFSIZE];
__constant__ siphash_keys dipkeys;

__device__ __forceinline__  void bitmapset(u32 *ebitmap, const u32 bucket) {
  u32 word = bucket >> 5;
  unsigned char bit = bucket & 0x1F;
  const u32 mask = 1 << bit;
  atomicOr(ebitmap + word, mask);
}

__device__ __forceinline__  bool bitmaptest(u32 *ebitmap, const u32 bucket) {
  u32 word = bucket >> 5;
  unsigned char bit = bucket & 0x1F;
  return (ebitmap[word] >> bit) & 1;
}

__device__ __forceinline__  u32 endpoint(u32 nonce, bool uorv) {
  return dipnode(dipkeys, nonce, uorv);
}

__device__ __forceinline__  u32 endpoint(uint2 nodes, bool uorv) {
  return uorv ? nodes.y : nodes.x;
}

#ifndef SEED_TPB
#define SEED_TPB 256
#endif
#ifndef TRIM0_TPB
#define TRIM0_TPB 1024
#endif
#ifndef TRIM1_TPB
#define TRIM1_TPB 512
#endif
#ifndef TRIM_TPB
#define TRIM_TPB 512
#endif
#ifndef RELAY_TPB
#define RELAY_TPB 512
#endif
#ifndef TAIL_TPB
#define TAIL_TPB SEED_TPB
#endif

#ifndef FLUSHA // should perhaps be in trimparams and passed as template parameter
#define FLUSHA 4
#endif

#ifndef NFLUSH
#define NFLUSH (8 / FLUSHA)
#endif

static_assert(NB % SEED_TPB == 0, "SEED_TPB must divide NB");

template<u32 maxOut>
__global__ void Seed(u32 * __restrict__ buffer, u32 * __restrict__ indexes, const u32 offset) {
  const u32 group = blockIdx.x;
  const u32 lid = threadIdx.x;
  const u32 gid = group * SEED_TPB + lid;
  const u32 nthreads = gridDim.x * SEED_TPB;

  extern __shared__ u32 tmp[][FLUSHA-1];
  u32 *counters = (u32 *)(tmp[NB]);

  for (u32 i = 0; i < NB/SEED_TPB; i++)
    counters[lid + SEED_TPB * i] = 0;

  __syncthreads();

  const u32 nloops = (NEDGES / NTLB - gid + nthreads-1) / nthreads;
  for (u32 i = 0; i < nloops; i++) {
    const u32 nonce = offset + gid * nloops + i;
    const u32 node0 = endpoint(nonce, 0);
    const u32 bucket = node0 >> ZBITS;
    u32 counter = atomicAdd(counters + bucket, 1);
    for (u32 nf=0; ; nf++) {
      if (counter < FLUSHA-1) // int counter would need additional test counter >= 0
        tmp[bucket][counter] = nonce;
      __syncthreads();
      if (nf == NFLUSH)
        break;
      if (counter == FLUSHA-1) {
        const u32 pos = min((u32)atomicAdd(indexes + bucket, FLUSHA), (u32)(maxOut - FLUSHA));
        const u64 idx = (u64)(bucket + (bucket / NB_NMEM) * (NTLB-1) * NB_NMEM) * maxOut + pos;
#if FLUSHA==4
        ((uint4 *)buffer)[idx/4] = make_uint4(tmp[bucket][0], tmp[bucket][1], tmp[bucket][2], nonce);
#elif FLUSHA==2
        ((uint2 *)buffer)[idx/2] = make_uint2(tmp[bucket][0], nonce);
#endif
        counters[bucket] %= FLUSHA;
      }
      __syncthreads();
      counter -= FLUSHA;
    }
    // negative counters are fine
    if ((int)counter >= FLUSHA-1) printf("WHOOPS!\n");
  }
  for (u32 i = 0; i < NB / SEED_TPB; i++) {
    const u32 bucket = lid + i * SEED_TPB;
    const u32 cnt = counters[bucket];
    if (cnt) {
      const u32 pos = min((u32)atomicAdd(indexes + bucket, FLUSHA), (u32)(maxOut - FLUSHA));
      const u64 idx = (u64)(bucket + (bucket / NB_NMEM) * (NTLB-1) * NB_NMEM) * maxOut + pos;
#if FLUSHA==4
        ((uint4 *)buffer)[idx/4] = make_uint4(tmp[bucket][0], cnt >= 2 ? tmp[bucket][1] : 0, cnt >= 3 ? tmp[bucket][2] : 0, 0);
#elif FLUSHA==2
        ((uint2 *)buffer)[idx/2] = make_uint2(tmp[bucket][0], 0);
#endif
    }
  }
}

#ifndef PART_BITS
// #bits used to partition edge set processing to save shared memory
// a value of 0 does no partitioning and is fastest
// a value of 1 partitions in two at about 33% slowdown
// higher values are not that interesting
#define PART_BITS 0
#endif

const u32 PART_MASK = (1 << PART_BITS) - 1;
const u32 NONPART_BITS = ZBITS - PART_BITS;
const word_t NONPART_MASK = (1 << NONPART_BITS) - 1;
const u32 BITMAPBYTES = (NZ >> PART_BITS) / 8;

template<u32 maxIn, u32 maxOut>
__global__ void Round0(u32 * src, u32 * dst, u32 * srcIdx, u32 * dstIdx, const u32 offset) {
  const u32 part = blockIdx.x & PART_MASK;
  const u32 group = blockIdx.x >> PART_BITS;
  const u32 lid = threadIdx.x;
  const u32 BITMAPWORDS = BITMAPBYTES / sizeof(u32);
  u32 nloops[NTLB];

  extern __shared__ u32 ebitmap[];

  static_assert(BITMAPWORDS % TRIM0_TPB == 0, "TRIM0_TPB must divide BITMAPWORDS");

  for (u32 i = 0; i < BITMAPWORDS/TRIM0_TPB; i++)
    ebitmap[lid + TRIM0_TPB * i] = 0;

  for (u32 a = 0; a < NTLB; a++)
    nloops[a] = (min(srcIdx[a * NB + offset + group], maxIn) - lid + TRIM0_TPB-1) / TRIM0_TPB;

  src += (u64)(offset * NTLB + group) * maxIn + lid;

  __syncthreads();

  for (u32 a = 0; a < NTLB; a++) {
    const u64 delta = a * NB_NMEM * (u64)maxIn;
    for (u32 i = 0; i < nloops[a]; i++) {
      u32 edge = src[delta + i * TRIM0_TPB];
      if (!edge) continue;
      u32 z = endpoint(edge, 0) & ZMASK;
      if (!PART_BITS || (z >> NONPART_BITS) == part)
        bitmapset(ebitmap, z & NONPART_MASK);
    }
  }

  __syncthreads();

  const u32 rowOffset = offset * NMEM;
  for (u32 a = 0; a < NTLB; a++) {
    const u64 delta = a * NB_NMEM * (u64)maxIn;
    for (u32 i = 0; i < nloops[a]; i++) {
      const u32 edge = src[delta + i * TRIM0_TPB];
      if (!edge) continue;
      const u32 node0 = endpoint(edge, 0);
      const u32 z = node0 & ZMASK;
      if ((!PART_BITS || (z >> NONPART_BITS) == part) && bitmaptest(ebitmap, (z & NONPART_MASK) ^ 1)) {
        const u32 bucket = endpoint(edge, 1) >> ZBITS;
        const u32 bktIdx = min(atomicAdd(dstIdx + rowOffset + bucket, 1), maxOut - 1);
        dst[bucket * maxOut + bktIdx] = edge;
      }
    }
  }
}

template<u32 maxIn, u32 maxOut>
__global__ void Round1(u32 * src, u32 * dst, u32 * srcIdx, u32 * dstIdx) {
  const u32 part = blockIdx.x & PART_MASK;
  const u32 group = blockIdx.x >> PART_BITS;
  const u32 lid = threadIdx.x;

  const u32 BITMAPWORDS = BITMAPBYTES / sizeof(u32);
  u32 nloops[NMEM];

  extern __shared__ u32 ebitmap[];

  static_assert(BITMAPWORDS % TRIM1_TPB == 0, "TRIM1_TPB must divide BITMAPWORDS");

  for (u32 i = 0; i < BITMAPWORDS/TRIM1_TPB; i++)
    ebitmap[lid + TRIM1_TPB * i] = 0;

  for (u32 a = 0; a < NMEM; a++)
    nloops[a] = (min(srcIdx[a * NB + group], maxIn) - lid + TRIM1_TPB-1) / TRIM1_TPB;

  src += (u64)maxIn * group + lid;

  __syncthreads();

  for (u32 a = 0; a < NMEM; a++) {
    const u64 delta = a * (u64)maxIn * NB;
    for (u32 i = 0; i < nloops[a]; i++) {
      u32 edge = src[delta + i * TRIM1_TPB];
      u32 z = endpoint(edge, 1) & ZMASK;
      if ((z >> NONPART_BITS) == part)
        bitmapset(ebitmap, z & NONPART_MASK);
    }
  }

  __syncthreads();

  for (u32 a = 0; a < NMEM; a++) {
    const u64 delta = a * (u64)maxIn * NB;
    for (u32 i = 0; i < nloops[a]; i++) {
      const u32 edge = src[delta + i * TRIM1_TPB];
      const u32 node1 = endpoint(edge, 1);
      const u32 z = node1 & ZMASK;
      if ((z >> NONPART_BITS) == part && bitmaptest(ebitmap, (z & NONPART_MASK) ^ 1)) {
        const u32 bucket = endpoint(edge, 0) >> ZBITS;
        const u32 bktIdx = min(atomicAdd(dstIdx + bucket, 1), maxOut - 1);
        dst[bucket * maxOut + bktIdx] = edge;
      }
    }
  }
}

template<u32 maxIn, typename EdgeIn, u32 maxOut>
__global__ void Round(const u32 round, EdgeIn * src, uint2 * dst, u32 * srcIdx, u32 * dstIdx) {
  const u32 part = blockIdx.x & PART_MASK;
  const u32 group = blockIdx.x >> PART_BITS;
  const u32 lid = threadIdx.x;

  const u32 BITMAPWORDS = BITMAPBYTES / sizeof(u32);

  extern __shared__ u32 ebitmap[];

  const u32 nloops = (min(srcIdx[group], maxIn) - lid + TRIM_TPB-1) / TRIM_TPB;

  static_assert(BITMAPWORDS % TRIM_TPB == 0, "TRIM_TPB must divide BITMAPWORDS");

  for (u32 i = 0; i < BITMAPWORDS/TRIM_TPB; i++)
    ebitmap[lid + TRIM_TPB * i] = 0;

  src += maxIn * group + lid;

  __syncthreads();

  for (u32 i = 0; i < nloops; i++) {
    const EdgeIn edge = src[i * TRIM_TPB]; // EdgeIn edge = __ldg(&src[index]);
    const u32 z = endpoint(edge, 0) & ZMASK;
    if ((z >> NONPART_BITS) == part)
      bitmapset(ebitmap, z & NONPART_MASK);
  }

  __syncthreads();

  for (u32 i = 0; i < nloops; i++) {
    const EdgeIn edge = src[i * TRIM_TPB]; // EdgeIn edge = __ldg(&src[index]);
    const u32 node = endpoint(edge, 0);
    const u32 z = node & ZMASK;
    if ((z >> NONPART_BITS) == part && bitmaptest(ebitmap, (z & NONPART_MASK) ^ 1)) {
      u32 node2 = endpoint(edge, 1);
      const u32 bucket = node2 >> ZBITS;
      const u32 bktIdx = min(atomicAdd(dstIdx + bucket, 1), maxOut - 1);
      dst[bucket * maxOut + bktIdx] = make_uint2(node2, node);
    }
  }
}

#ifndef LISTBITS
#define LISTBITS 12
#endif

const u32 NLISTS  = 1 << LISTBITS;
const u32 LISTMASK = NLISTS - 1;

#ifndef NNEXTS
#define NNEXTS NLISTS
#endif

const u32 COPYFLAG = NZ;

template<u32 bktInSize, u32 bktOutSize>
__global__  void Relay(const u32 round, const uint2 * source, uint2 * destination, const u32 * sourceIndexes, u32 * destinationIndexes, bool TAGGED)
{
  const u32 lid = threadIdx.x;
  const u32 group = blockIdx.x;

  __shared__ u32 lists[NLISTS];
  __shared__ u32 nexts[NNEXTS];

  const u32 nloops = (min(sourceIndexes[group], NNEXTS) - lid + RELAY_TPB-1) / RELAY_TPB;

  source += bktInSize * group;

  for (u32 i = 0; i < NLISTS/RELAY_TPB; i++)
    lists[i * RELAY_TPB + lid] = ~0;

  __syncthreads();

  for (u32 i = 0; i < nloops; i++) {
    const u32 index = i * RELAY_TPB + lid;
    const u32 list = endpoint(source[index], 0) & LISTMASK;
    nexts[index] = atomicExch(&lists[list], index);
  }

  __syncthreads();

  for (int i = nloops; --i >= 0;) {
    const u32 index = i * RELAY_TPB + lid;
    const uint2 edge = source[index];
    if (TAGGED && (edge.x & COPYFLAG)) continue; // copies don't relay
    u32 bucket = edge.y >> ZBITS;
    u32 copybit = 0;
    const u32 list = (edge.x & LISTMASK) ^ 1;
    for (u32 idx = lists[list]; idx != ~0; idx = nexts[idx]) {
      uint2 tagged = source[idx];
      if ((tagged.x ^ edge.x ^ 1) & ZMASK) continue;
      u32 bktIdx = min(atomicAdd(destinationIndexes + bucket, 1), bktOutSize - 1);
      u32 tag = (TAGGED ? tagged.x >> ZBITS : tagged.y >> 1) & ~1 | copybit;
      destination[(bucket * bktOutSize) + bktIdx] = make_uint2((tag << ZBITS) | (edge.y & ZMASK), (group << ZBITS) | (edge.x & ZMASK));
      copybit = 1;
    }
  }
}

template<u32 tpb, u32 maxIn>
__global__ void Tail(const uint2 *source, uint4 *destination, const u32 *sourceIndexes, u32 *destinationIndexes) {
  const u32 lid = threadIdx.x;
  const u32 group = blockIdx.x;

  __shared__ u32 lists[NLISTS];
  __shared__ u32 nexts[NNEXTS];

  const u32 nloops = (min(sourceIndexes[group], NNEXTS) - lid + tpb-1) / tpb;

  source += maxIn * group;

  for (u32 i = 0; i < NLISTS/tpb; i++)
    lists[i * tpb + lid] = ~0;

  __syncthreads();

  for (u32 i = 0; i < nloops; i++) {
    const u32 index = i * tpb + lid;
    const u32 list = source[index].x & LISTMASK;
    nexts[index] = atomicExch(&lists[list], index);
  }

  __syncthreads();

  for (int i = nloops; --i >= 0;) {
    const u32 index = i * tpb + lid;
    const uint2 edge = source[index];
    if (edge.x & 1) continue;
    const u32 list = (edge.x & LISTMASK) ^ 1;
    for (u32 idx = lists[list]; idx != ~0; idx = nexts[idx]) {
      uint2 other = source[idx];
      if (((other.x ^ edge.x) & ~COPYFLAG) != 1) continue;
      u32 bktIdx = atomicAdd(destinationIndexes, 2);
      destination[bktIdx/2] = make_uint4(edge.y, (group << ZBITS) |  (edge.x & ZMASK),
                                        other.y & (NEDGES-1), (group << ZBITS) | (other.x & ZMASK));
    }
  }
}

#define checkCudaErrors_V(ans) ({if (gpuAssert((ans), __FILE__, __LINE__) != cudaSuccess) return;})
#define checkCudaErrors_N(ans) ({if (gpuAssert((ans), __FILE__, __LINE__) != cudaSuccess) return NULL;})
#define checkCudaErrors(ans) ({int retval = gpuAssert((ans), __FILE__, __LINE__); if (retval != cudaSuccess) return retval;})

inline int gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
  int device_id;
  cudaGetDevice(&device_id);
  if (code != cudaSuccess) {
    snprintf(LAST_ERROR_REASON, MAX_NAME_LEN, "Device %d GPUassert: %s %s %d", device_id, cudaGetErrorString(code), file, line);
    cudaDeviceReset();
    if (abort) return code;
  }
  return code;
}

__global__ void Recovery(u32 *indexes) {
  const u32 gid = blockDim.x * blockIdx.x + threadIdx.x;
  const u32 lid = threadIdx.x;
  const u32 nthreads = blockDim.x * gridDim.x;
  __shared__ u32 nonces[PROOFSIZE];
  
  const u32 nloops = (NEDGES -gid + nthreads-1) / nthreads;
  if (lid < PROOFSIZE) nonces[lid] = 0;
  __syncthreads();
  for (u32 i = 0; i < nloops; i++) {
    u64 nonce = gid * nloops + i;
    u64 u = endpoint(nonce, 0);
    u64 v = endpoint(nonce, 1);
    for (u32 i = 0; i < PROOFSIZE; i++) {
      if (recoveredges[i].x == v && recoveredges[i].y == u)
        nonces[i] = nonce;
    }
  }
  __syncthreads();
  if (lid < PROOFSIZE) {
    if (nonces[lid] > 0)
      indexes[lid] = nonces[lid];
  }
}

struct blockstpb {
  u16 blocks;
  u16 tpb;
};

struct trimparams {
  u16 ntrims;
  blockstpb seed;
  blockstpb trim0;
  blockstpb trim1;
  blockstpb trim;
  blockstpb tail;
  blockstpb recover;

  trimparams() {
    ntrims         =        31;
    seed.blocks    =   NB_NTLB;
    seed.tpb       =  SEED_TPB;
    trim0.blocks   =   NB_NMEM;
    trim0.tpb      = TRIM0_TPB;
    trim1.blocks   =   NB_NMEM;
    trim1.tpb      = TRIM1_TPB;
    trim.blocks    =        NB;
    trim.tpb       =  TRIM_TPB;
    tail.blocks    =        NB;
    tail.tpb       =  TAIL_TPB;
    recover.blocks =      2048;
    recover.tpb    =       256;
  }
};

typedef u32 proof[PROOFSIZE];

// maintains set of trimmable edges
struct edgetrimmer {
  trimparams tp;
  edgetrimmer *dt;
  size_t sizeA, sizeB;
  const size_t indexesSize = NB * sizeof(u32);
  const size_t indexesSizeNTLB = NTLB * indexesSize;
  const size_t indexesSizeNMEM = NMEM * indexesSize;
  u8 *bufferA;
  u8 *bufferB;
  u8 *bufferA1;
  u32 *indexesA;
  u32 *indexesB;
  u32 nedges;
  u32 *uvnodes;
  siphash_keys sipkeys;
  bool abort;
  bool initsuccess = false;

  static_assert((NTLB & (NTLB-1)) == 0, "ensure NTLB is a 2 power");
  static_assert((NMEM & (NMEM-1)) == 0, "ensure NMEM is a 2 power");

  edgetrimmer(const trimparams _tp) : tp(_tp) {
    checkCudaErrors_V(cudaMalloc((void**)&dt, sizeof(edgetrimmer)));
    checkCudaErrors_V(cudaMalloc((void**)&uvnodes, PROOFSIZE * 2 * sizeof(u32)));
    checkCudaErrors_V(cudaMalloc((void**)&indexesA, indexesSizeNTLB));
    checkCudaErrors_V(cudaMalloc((void**)&indexesB, indexesSizeNMEM));
    sizeA = (u64)EDGES_A * NB * sizeof(u32);
    sizeB = (u64)EDGES_B * NB * sizeof(u32);
    const size_t bufferSize = sizeA + sizeB / NMEM;
    checkCudaErrors_V(cudaMalloc((void**)&bufferB, bufferSize));
    bufferA = bufferB + sizeB / NMEM;
    bufferA1 = bufferB + sizeB;
    // print_log("allocated %lld bytes bufferB %llx bufferA %llx bufferA1 %llx\n", bufferSize, bufferB, bufferA, bufferA1);
    // print_log("endB %llx endA %llx endBuffer %llx\n", bufferB+sizeB, bufferA+sizeA, bufferB+bufferSize);
    cudaMemcpy(dt, this, sizeof(edgetrimmer), cudaMemcpyHostToDevice);
    initsuccess = true;
    u32 maxbytes = 0x10000; // 64 KB
    cudaFuncSetAttribute(Seed  <EDGES_A/NTLB               >, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);
    cudaFuncSetAttribute(Round0<EDGES_A/NTLB,  EDGES_B/NMEM>, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);
    cudaFuncSetAttribute(Round1<EDGES_B/NMEM,     EDGES_B/2>, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);
    cudaFuncSetAttribute(Round <EDGES_B/2,   u32, EDGES_A/4>, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);
    cudaFuncSetAttribute(Round <EDGES_A/4, uint2, EDGES_B/4>, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);
    cudaFuncSetAttribute(Round <EDGES_B/4, uint2, EDGES_B/4>, cudaFuncAttributeMaxDynamicSharedMemorySize, maxbytes);
  }
  u64 globalbytes() const {
    return sizeA + sizeB/NMEM + indexesSizeNTLB + indexesSizeNMEM + sizeof(siphash_keys) + PROOFSIZE * 2*sizeof(u32) + sizeof(edgetrimmer);
  }
  ~edgetrimmer() {
    checkCudaErrors_V(cudaFree(bufferB));
    checkCudaErrors_V(cudaFree(indexesA));
    checkCudaErrors_V(cudaFree(indexesB));
    checkCudaErrors_V(cudaFree(uvnodes));
    checkCudaErrors_V(cudaFree(dt));
    cudaDeviceReset();
  }

#ifndef VBIDX
#define VBIDX 0
#endif

  void indexcount(u32 round, const u32 *indexes) {
#ifdef VERBOSE
    u32 nedges[NB];
    cudaMemcpy(nedges, indexes, NB * sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    u32 sum, max;
    for (u32 i = sum = max = 0; i < NB; i++) {
      sum += nedges[i];
      if (nedges[i] > max)
        max = nedges[i];
    }
    print_log("round %d edges avg %d max %d\n", round, sum/NB, max);
#endif
  }
  u32 trim() {
    cudaEvent_t start, stop;
    checkCudaErrors(cudaEventCreate(&start)); checkCudaErrors(cudaEventCreate(&stop));
    cudaMemcpyToSymbol(dipkeys, &sipkeys, sizeof(sipkeys));
  
    cudaDeviceSynchronize();
    float durationA;
    cudaEventRecord(start, NULL);
  
    cudaMemset(indexesA, 0, indexesSizeNTLB);
    for (u32 i = 0; i < NTLB; i++) {
      Seed<EDGES_A/NTLB><<<tp.seed.blocks, SEED_TPB, BITMAPBYTES>>>((u32*)(bufferA+i*(sizeA/NMEMTLB)), indexesA+i*NB, i*(NEDGES/NTLB));
    cudaDeviceSynchronize();
      if (abort) return false;
    }
  
    checkCudaErrors(cudaDeviceSynchronize()); cudaEventRecord(stop, NULL);
    cudaEventSynchronize(stop); cudaEventElapsedTime(&durationA, start, stop);
    cudaEventRecord(start, NULL);
  
    // checkCudaErrors(cudaEventDestroy(start)); checkCudaErrors(cudaEventDestroy(stop));
    print_log("Seeding completed in %.0f ms\n", durationA);
    indexcount(0, indexesA);
    if (abort) return false;
  
    cudaMemset(indexesB, 0, indexesSizeNMEM);

    const size_t qB = sizeB / NMEM;
    for (u32 i = 0; i < NMEM; i++) {
      Round0<EDGES_A/NTLB, EDGES_B/NMEM><<<NB_NMEM<<PART_BITS, TRIM0_TPB, BITMAPBYTES>>>((u32*)bufferA, (u32*)(bufferB+i*qB), indexesA, indexesB, i*NB_NMEM); // to .632
      if (abort) return false;
    }
    indexcount(1, indexesB);

    cudaMemset(indexesA, 0, indexesSize);

    Round1<EDGES_B/NMEM, EDGES_B/2><<<NB<<PART_BITS, TRIM1_TPB, BITMAPBYTES>>>((u32*)bufferB, (u32*)bufferA1, indexesB, indexesA); // to .296
    if (abort) return false;
    indexcount(2, indexesA);

    cudaMemset(indexesB, 0, indexesSize);

    Round<EDGES_B/2, u32, EDGES_A/4><<<NB<<PART_BITS, TRIM_TPB, BITMAPBYTES>>>(2, (u32 *)bufferA1, (uint2 *)bufferB, indexesA, indexesB); // to .176
    if (abort) return false;
    indexcount(3, indexesB);

    cudaMemset(indexesA, 0, indexesSize);

    Round<EDGES_A/4, uint2, EDGES_B/4><<<NB<<PART_BITS, TRIM_TPB, BITMAPBYTES>>>(3, (uint2 *)bufferB, (uint2 *)bufferA1, indexesB, indexesA); // to .116
    if (abort) return false;
    indexcount(4, indexesA);
  
    for (u32 round = 5; round < tp.ntrims + PROOFSIZE/2-1; round += 2) {
      cudaMemset(indexesB, 0, indexesSize);
      if (round >= tp.ntrims)
        Relay<EDGES_B/4, EDGES_B/4><<<NB, RELAY_TPB>>>(round-1, (uint2 *)bufferA1, (uint2 *)bufferB, indexesA, indexesB, round > tp.ntrims);
      else Round<EDGES_B/4, uint2, EDGES_B/4><<<NB<<PART_BITS, TRIM_TPB, BITMAPBYTES>>>(round-1, (uint2 *)bufferA1, (uint2 *)bufferB, indexesA, indexesB);
      indexcount(round, indexesB);
      if (abort) return false;
      cudaMemset(indexesA, 0, indexesSize);
      if (round+1 >= tp.ntrims)
        Relay<EDGES_B/4, EDGES_B/4><<<NB, RELAY_TPB>>>(round, (uint2 *)bufferB, (uint2 *)bufferA1, indexesB, indexesA, round+1 > tp.ntrims);
      else Round<EDGES_B/4, uint2, EDGES_B/4><<<NB<<PART_BITS, TRIM_TPB, BITMAPBYTES>>>(round, (uint2 *)bufferB, (uint2 *)bufferA1, indexesB, indexesA);
      indexcount(round+1, indexesA);
      if (abort) return false;
    }
    
    cudaMemset(indexesB, 0, indexesSize);
    cudaDeviceSynchronize();
  
    Tail<TAIL_TPB, EDGES_B/4><<<NB, TAIL_TPB>>>((const uint2 *)bufferA1, (uint4 *)bufferB, indexesA, indexesB);
    cudaMemcpy(&nedges, indexesB, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    return nedges;
  }
};

struct solver_ctx {
  edgetrimmer trimmer;
  bool mutatenonce;
  uint2 *edges;
  graph<word_t> cg;
  uint2 soledges[PROOFSIZE];
  std::vector<u32> sols; // concatenation of all proof's indices

  solver_ctx(const trimparams tp, bool mutate_nonce) : trimmer(tp), cg(MAXEDGES, MAXEDGES, MAXSOLS, IDXSHIFT) {
    edges   = new uint2[MAXEDGES];
    mutatenonce = mutate_nonce;
  }

  void setheadernonce(char * const headernonce, const u32 len, const u32 nonce) {
    if (mutatenonce) {
      ((u32 *)headernonce)[len/sizeof(u32)-1] = htole32(nonce); // place nonce at end
    }
    setheader(headernonce, len, &trimmer.sipkeys);
    sols.clear();
  }
  ~solver_ctx() {
    delete[] edges;
  }

  u32 findcycles(uint2 *edges, u32 nedges) {
    u32 ndupes = 0;
    cg.reset();
    for (u32 i = 0; i < nedges; i++)
      ndupes += !cg.add_compress_edge(edges[i].x, edges[i].y);
    for (u32 s = 0 ;s < cg.nsols; s++) {
#ifdef VERBOSE
      print_log("Solution");
#endif
      for (u32 j = 0; j < PROOFSIZE; j++) {
        soledges[j] = edges[cg.sols[s][j]];
#ifdef VERBOSE
	print_log(" (%x, %x)", soledges[j].x, soledges[j].y);
#endif
      }
#ifdef VERBOSE
      print_log("\n");
#endif
      sols.resize(sols.size() + PROOFSIZE);
      cudaMemcpyToSymbol(recoveredges, soledges, sizeof(soledges));
      cudaMemset(trimmer.indexesB, 0, trimmer.indexesSize);
      Recovery<<<trimmer.tp.recover.blocks, trimmer.tp.recover.tpb>>>((u32 *)trimmer.bufferA1);
      cudaMemcpy(&sols[sols.size()-PROOFSIZE], trimmer.bufferA1, PROOFSIZE * sizeof(u32), cudaMemcpyDeviceToHost);
      checkCudaErrors(cudaDeviceSynchronize());
      qsort(&sols[sols.size()-PROOFSIZE], PROOFSIZE, sizeof(u32), cg.nonce_cmp);
    }
    return ndupes;
  }

  u32 solve() {
    u64 time0, time1;
    u32 timems,timems2;

    trimmer.abort = false;
    time0 = timestamp();
    u32 nedges = trimmer.trim();
    // if (!nedges)
      // return 0;
    if (nedges > MAXEDGES) {
      print_log("OOPS; losing %d edges beyond MAXEDGES=%d\n", nedges-MAXEDGES, MAXEDGES);
      nedges = MAXEDGES;
      return 0;
    }
    cudaMemcpy(edges, trimmer.bufferB, nedges * 8, cudaMemcpyDeviceToHost);
    time1 = timestamp(); timems  = (time1 - time0) / 1000000;
    time0 = timestamp();
    u32 ndupes = findcycles(edges, nedges);
    time1 = timestamp(); timems2 = (time1 - time0) / 1000000;
    print_log("%d trims %d ms %d edges %d dupes %d ms total %d ms\n", trimmer.tp.ntrims, timems, nedges, ndupes, timems2, timems+timems2);
    return sols.size() / PROOFSIZE;
  }

  void abort() {
    trimmer.abort = true;
  }

};

#include <unistd.h>

// arbitrary length of header hashed into siphash key
#define HEADERLEN 80

typedef solver_ctx SolverCtx;

CALL_CONVENTION int run_solver(SolverCtx* ctx,
                               char* header,
                               int header_length,
                               u32 nonce,
                               u32 range,
                               SolverSolutions *solutions,
                               SolverStats *stats
                               )
{
  u64 time0, time1;
  u32 timems;
  u32 sumnsols = 0;
  int device_id;
  if (stats != NULL) {
    cudaGetDevice(&device_id);
    cudaDeviceProp props;
    cudaGetDeviceProperties(&props, stats->device_id);
    stats->device_id = device_id;
    stats->edge_bits = EDGEBITS;
    strncpy(stats->device_name, props.name, MAX_NAME_LEN);
  }

  if (ctx == NULL || !ctx->trimmer.initsuccess){
    print_log("Error initialising trimmer. Aborting.\n");
    print_log("Reason: %s\n", LAST_ERROR_REASON);
    if (stats != NULL) {
       stats->has_errored = true;
       strncpy(stats->error_reason, LAST_ERROR_REASON, MAX_NAME_LEN);
    }
    return 0;
  }

  for (u32 r = 0; r < range; r++) {
    time0 = timestamp();
    ctx->setheadernonce(header, header_length, nonce + r);
    print_log("nonce %d k0 k1 k2 k3 %llx %llx %llx %llx\n", nonce+r, ctx->trimmer.sipkeys.k0, ctx->trimmer.sipkeys.k1, ctx->trimmer.sipkeys.k2, ctx->trimmer.sipkeys.k3);
    u32 nsols = ctx->solve();
    time1 = timestamp();
    timems = (time1 - time0) / 1000000;
    print_log("Time: %d ms\n", timems);
    for (unsigned s = 0; s < nsols; s++) {
      print_log("Solution");
      u32* prf = &ctx->sols[s * PROOFSIZE];
      for (u32 i = 0; i < PROOFSIZE; i++)
        print_log(" %jx", (uintmax_t)prf[i]);
      print_log("\n");
      if (solutions != NULL){
        solutions->edge_bits = EDGEBITS;
        solutions->num_sols++;
        solutions->sols[sumnsols+s].nonce = nonce + r;
        for (u32 i = 0; i < PROOFSIZE; i++) 
          solutions->sols[sumnsols+s].proof[i] = (u64) prf[i];
      }
      u32 pow_rc = verify(prf, &ctx->trimmer.sipkeys);
      if (pow_rc == POW_OK) {
        print_log("Verified with cyclehash ");
        unsigned char cyclehash[32];
        blake2b((void *)cyclehash, sizeof(cyclehash), (const void *)prf, sizeof(proof), 0, 0);
        for (u32 i=0; i<32; i++)
          print_log("%02x", cyclehash[i]);
        print_log("\n");
      } else {
        print_log("FAILED due to %s\n", errstr[pow_rc]);
      }
    }
    sumnsols += nsols;
    if (stats != NULL) {
      stats->last_start_time = time0;
      stats->last_end_time = time1;
      stats->last_solution_time = time1 - time0;
    }
  }
  print_log("%d total solutions\n", sumnsols);
  return sumnsols > 0;
}

CALL_CONVENTION SolverCtx* create_solver_ctx(SolverParams* params) {
  trimparams tp;
  tp.ntrims = params->ntrims;
  tp.seed.blocks = params->genablocks;
  tp.seed.tpb = params->genatpb;
  tp.trim0.tpb = params->genbtpb;
  tp.trim.tpb = params->trimtpb;
  tp.tail.tpb = params->tailtpb;
  tp.recover.blocks = params->recoverblocks;
  tp.recover.tpb = params->recovertpb;

  cudaDeviceProp prop;
  checkCudaErrors_N(cudaGetDeviceProperties(&prop, params->device));

  assert(tp.seed.tpb <= prop.maxThreadsPerBlock);
  assert(tp.trim0.tpb <= prop.maxThreadsPerBlock);
  assert(tp.trim.tpb <= prop.maxThreadsPerBlock);
  // assert(tp.tailblocks <= prop.threadDims[0]);
  assert(tp.tail.tpb <= prop.maxThreadsPerBlock);
  assert(tp.recover.tpb <= prop.maxThreadsPerBlock);

  cudaSetDevice(params->device);
  if (!params->cpuload)
    checkCudaErrors_N(cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync));

  SolverCtx* ctx = new SolverCtx(tp, params->mutate_nonce);

  return ctx;
}

CALL_CONVENTION void destroy_solver_ctx(SolverCtx* ctx) {
  delete ctx;
}

CALL_CONVENTION void stop_solver(SolverCtx* ctx) {
  ctx->abort();
}

CALL_CONVENTION void fill_default_params(SolverParams* params) {
  trimparams tp;
  params->device = 0;
  params->ntrims = tp.ntrims;
  params->genablocks = tp.seed.blocks;
  params->genatpb = tp.seed.tpb;
  params->genbtpb = tp.trim0.tpb;
  params->trimtpb = tp.trim.tpb;
  params->tailtpb = tp.tail.tpb;
  params->recoverblocks = min(tp.recover.blocks, (u32)(NEDGES/tp.recover.tpb));
  params->recovertpb = tp.recover.tpb;
  params->cpuload = false;
}

int main(int argc, char **argv) {
  trimparams tp;
  u32 nonce = 0;
  u32 range = 1;
  u32 device = 0;
  char header[HEADERLEN];
  u32 len;
  int c;

  // set defaults
  SolverParams params;
  fill_default_params(&params);

  memset(header, 0, sizeof(header));
  while ((c = getopt(argc, argv, "scd:h:m:n:r:U:Z:z:")) != -1) {
    switch (c) {
      case 's':
        print_log("SYNOPSIS\n  cuda%d [-s] [-c] [-d device] [-h hexheader] [-m trims] [-n nonce] [-r range] [-U seedblocks] [-Z recoverblocks] [-z recoverthreads]\n", EDGEBITS);
        print_log("DEFAULTS\n  cuda%d -d %d -h \"\" -m %d -n %d -r %d -U %d -Z %d -z %d\n", EDGEBITS, device, tp.ntrims, nonce, range, tp.seed.blocks, tp.recover.blocks, tp.recover.tpb);
        exit(0);
      case 'c':
        params.cpuload = false;
        break;
      case 'd':
        device = params.device = atoi(optarg);
        break;
      case 'h':
        len = strlen(optarg)/2;
        assert(len <= sizeof(header));
        for (u32 i=0; i<len; i++)
          sscanf(optarg+2*i, "%2hhx", header+i); // hh specifies storage of a single byte
        break;
      case 'm':
        params.ntrims = atoi(optarg);
        break;
      case 'n':
        nonce = atoi(optarg);
        break;
      case 'r':
        range = atoi(optarg);
        break;
      case 'U':
        params.genablocks = atoi(optarg);
        break;
      case 'Z':
        params.recoverblocks = atoi(optarg);
        break;
      case 'z':
        params.recovertpb = atoi(optarg);
        break;
    }
  }

  assert((params.ntrims & 1) == (PROOFSIZE/2 & 1)); // number of trims must match half cycle length in parity
  int nDevices;
  checkCudaErrors(cudaGetDeviceCount(&nDevices));
  assert(device < nDevices);
  cudaDeviceProp prop;
  checkCudaErrors(cudaGetDeviceProperties(&prop, device));
  u64 dbytes = prop.totalGlobalMem;
  u32 dunit;
  for (dunit=0; dbytes >= 102400; dbytes>>=10,dunit++) ;
  print_log("%s with %d%cB @ %d bits x %dMHz\n", prop.name, (u32)dbytes, " KMGT"[dunit], prop.memoryBusWidth, prop.memoryClockRate/1000);

  print_log("Looking for %d-cycle on cuckatoo%d(\"%s\",%d", PROOFSIZE, EDGEBITS, header, nonce);
  if (range > 1)
    print_log("-%d", nonce+range-1);
  print_log(") with 50%% edges, %d buckets, and %d trims.\n", NB, params.ntrims);

  SolverCtx* ctx = create_solver_ctx(&params);

  u64 bytes = ctx->trimmer.globalbytes();
  u32 unit;
  for (unit=0; bytes >= 102400; bytes>>=10,unit++) ;
  print_log("Using %d%cB of global memory.\n", (u32)bytes, " KMGT"[unit]);

  run_solver(ctx, header, sizeof(header), nonce, range, NULL, NULL);

  return 0;
}
