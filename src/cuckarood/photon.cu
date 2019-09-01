// Cuckarood Cycle, a memory-hard proof-of-work by John Tromp
// Copyright (c) 2018-2019 Jiri Vadura (photon) and John Tromp
// This software is covered by the FAIR MINING license

#include <stdio.h>
#include <string.h>
#include <vector>
#include <assert.h>
#include "cuckarood.hpp"
#include "graph.hpp"
#include "../crypto/siphash.cuh"
#include "../crypto/blake2.h"

// Number of Parts of BufferB, all but one of which will overlap BufferA
#ifndef NA
#define NA 4
#endif
#define NA2 (NA * NA)

#include "kernel.cu"

typedef uint8_t u8;
typedef uint16_t u16;

#ifndef IDXSHIFT
// number of bits of compression of surviving edge endpoints
// reduces space used in cycle finding, but too high a value
// results in NODE OVERFLOW warnings and fake cycles
#define IDXSHIFT 12
#endif

const u32 MAXEDGES = NEDGES2 >> IDXSHIFT;

#ifndef NEPS_A
#define NEPS_A 134 // to match Photon's kernel.cu
#endif
#ifndef NEPS_B
#define NEPS_B 85 // to match Photon's kernel.cu
#endif
#define NEPS 128

const u32 EDGES_A = NZ * NEPS_A / NEPS;
const u32 EDGES_B = NZ * NEPS_B / NEPS;

const u32 ROW_EDGES_A = EDGES_A * NY;
const u32 ROW_EDGES_B = EDGES_B * NY;

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

struct blockstpb {
  u16 blocks;
  u16 tpb;
};

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
#ifndef TAIL_TPB
#define TAIL_TPB SEED_TPB
#endif

struct trimparams {
  u16 ntrims;
  blockstpb seed;
  blockstpb trim0;
  blockstpb trim1;
  blockstpb trim;
  blockstpb tail;
  blockstpb recover;

  trimparams() {
    ntrims         =       458;
    seed.blocks    =      1024;
    seed.tpb       =  SEED_TPB;
    trim0.blocks   =    NX2/NA;
    trim0.tpb      = TRIM0_TPB;
    trim1.blocks   =    NX2/NA;
    trim1.tpb      = TRIM1_TPB;
    trim.blocks    =       NX2;
    trim.tpb       =  TRIM_TPB;
    tail.blocks    =       NX2;
    tail.tpb       =  TAIL_TPB;;
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
  const size_t indexesSize = NX2 * sizeof(u32);
  const size_t indexesSizeNA = NA * indexesSize;
  u8 *bufferA;
  u8 *bufferB;
  u8 *bufferA1;
  u32 *indexesA;
  u32 *indexesB;
  u32 nedges;
  siphash_keys sipkeys;
  bool abort;
  bool initsuccess = false;

  edgetrimmer(const trimparams _tp) : tp(_tp) {
    checkCudaErrors_V(cudaMalloc((void**)&dt, sizeof(edgetrimmer)));
    checkCudaErrors_V(cudaMalloc((void**)&indexesA, indexesSizeNA));
    checkCudaErrors_V(cudaMalloc((void**)&indexesB, indexesSizeNA));
    sizeA = ROW_EDGES_A * NX * sizeof(uint2);
    sizeB = ROW_EDGES_B * NX * sizeof(uint2);
    const size_t bufferSize = sizeA + sizeB / NA;
    checkCudaErrors_V(cudaMalloc((void**)&bufferB, bufferSize));
    bufferA = bufferB + sizeB / NA;
    bufferA1 = bufferB + sizeB;
    cudaMemcpy(dt, this, sizeof(edgetrimmer), cudaMemcpyHostToDevice);
    initsuccess = true;
  }
  u64 globalbytes() const {
    return sizeA + sizeB/NA + 2 * indexesSizeNA + sizeof(siphash_keys) + sizeof(edgetrimmer);
  }
  ~edgetrimmer() {
    checkCudaErrors_V(cudaFree(bufferB));
    checkCudaErrors_V(cudaFree(indexesA));
    checkCudaErrors_V(cudaFree(indexesB));
    checkCudaErrors_V(cudaFree(dt));
    cudaDeviceReset();
  }
  u32 trim() {
    cudaEvent_t start, stop;
    checkCudaErrors(cudaEventCreate(&start)); checkCudaErrors(cudaEventCreate(&stop));
    cudaMemcpyToSymbol(dipkeys, &sipkeys, sizeof(sipkeys));

    cudaDeviceSynchronize();
    float durationA, durationB;
    cudaEventRecord(start, NULL);
  

    cudaMemset(indexesA, 0, indexesSizeNA);
    for (u32 i=0; i < NA; i++) {
      FluffySeed<SEED_TPB, EDGES_A/NA><<<tp.seed.blocks, SEED_TPB>>>((uint4*)(bufferA+i*(sizeA/NA2)), indexesA+i*NX2, i*(NEDGES2/NA));
      if (abort) return false;
    }
  
#ifdef VERBOSE
    print_log("%d x Seed<<<%d,%d>>>\n", NA, tp.seed.blocks, tp.seed.tpb); // 1024x512
    cudaMemcpy(&nedges, indexesA, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 0, nedges);
#endif

    checkCudaErrors(cudaDeviceSynchronize()); cudaEventRecord(stop, NULL);
    cudaEventSynchronize(stop); cudaEventElapsedTime(&durationA, start, stop);
    cudaEventRecord(start, NULL);
  
#ifdef VERBOSE
    print_log("Seeding completed in %.0f ms\n", durationA);
    print_log("Round_A1<<<%d,%d>>>\n", NX2/NA, TRIM0_TPB); // 1024x1024
#endif

    cudaMemset(indexesB, 0, indexesSizeNA);
    const u32 qB = sizeB/NA;
    const u32 qI = NX2 / NA;
    for (u32 i=0; i < NA; i++) {
      FluffyRound_A1<TRIM0_TPB, EDGES_A/NA, EDGES_B/NA><<<NX2/NA, TRIM0_TPB>>>((uint2*)bufferA, (uint4*)(bufferB+i*qB), indexesA, indexesB, i*qI);
      if (abort) return false;
    }

#ifdef VERBOSE
    cudaMemcpy(&nedges, indexesB, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 1, nedges);
    print_log("Round_A3<<<%d,%d>>>\n", NX2/NA, TRIM1_TPB); // 4096x1024
#endif

    checkCudaErrors(cudaDeviceSynchronize()); cudaEventRecord(stop, NULL);
    cudaEventSynchronize(stop); cudaEventElapsedTime(&durationB, start, stop);
    checkCudaErrors(cudaEventDestroy(start)); checkCudaErrors(cudaEventDestroy(stop));
    // print_log("Round 0 completed in %.0f ms\n", durationB);
  
    cudaMemset(indexesA, 0, indexesSize);
    FluffyRound_A3<TRIM1_TPB, EDGES_B/NA, EDGES_B/2><<<NX2, TRIM1_TPB>>>((uint2*)bufferB, (uint2*)bufferA1, indexesB, indexesA);
    if (abort) return false;

#ifdef VERBOSE
    cudaMemcpy(&nedges, indexesA, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 1, nedges);
    print_log("Round_A2<><<<%d,%d>>>\n", NX2, TRIM_TPB); // 4096x512
#endif

    cudaMemset(indexesB, 0, indexesSize);
    FluffyRound_A2<TRIM_TPB, EDGES_B/2, EDGES_B/2><<<NX2, TRIM_TPB>>>((uint2*)bufferA1, (uint2*)bufferB, indexesA, indexesB, 2, 0);
    if (abort) return false;

#ifdef VERBOSE
    cudaMemcpy(&nedges, indexesB, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 2, nedges);
#endif

    cudaMemset(indexesA, 0, indexesSize);
    FluffyRound_A2<TRIM_TPB, EDGES_B/2, EDGES_B/2><<<NX2, TRIM_TPB>>>((uint2*)bufferB, (uint2*)bufferA1, indexesB, indexesA, 3, 0);
    if (abort) return false;

#ifdef VERBOSE
    cudaMemcpy(&nedges, indexesA, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 3, nedges);
#endif

    cudaMemset(indexesB, 0, indexesSize);
    FluffyRound_A2<TRIM_TPB, EDGES_B/2, EDGES_B/2><<<NX2, TRIM_TPB>>>((uint2*)bufferA1, (uint2*)bufferB, indexesA, indexesB, 4, 0);
    if (abort) return false;

#ifdef VERBOSE
    cudaMemcpy(&nedges, indexesB, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 4, nedges);
#endif

    cudaMemset(indexesA, 0, indexesSize);
    FluffyRound_A2<TRIM_TPB, EDGES_B/2, EDGES_B/4><<<NX2, TRIM_TPB>>>((uint2*)bufferB, (uint2*)bufferA1, indexesB, indexesA, 5, 0);
    if (abort) return false;

#ifdef VERBOSE
    cudaMemcpy(&nedges, indexesA, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("round %d edges %d\n", 5, nedges);
#endif

    cudaDeviceSynchronize();
  
    for (int round = 6; round < tp.ntrims; round += 2) {
      cudaMemset(indexesB, 0, indexesSize);
      FluffyRound_A2<TRIM_TPB, EDGES_B/4, EDGES_B/4><<<NX2, TRIM_TPB>>>((uint2*)bufferA1, (uint2*)bufferB, indexesA, indexesB, round, 0);
      if (abort) return false;

      cudaMemset(indexesA, 0, indexesSize);
      FluffyRound_A2<TRIM_TPB, EDGES_B/4, EDGES_B/4><<<NX2, TRIM_TPB>>>((uint2*)bufferB, (uint2*)bufferA1, indexesB, indexesA, round+1, 0);
      if (abort) return false;
    }
    
    cudaMemset(indexesB, 0, indexesSize);
#ifdef VERBOSE
    print_log("Tail<><<<%d,%d>>>\n", NX2, TAIL_TPB);
#endif
    FluffyTail<TAIL_TPB, EDGES_B/4><<<NX2, TAIL_TPB>>>((uint2*)bufferA1, (uint2*)bufferB, indexesA, indexesB);

    cudaMemcpy(&nedges, indexesB, sizeof(u32), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    print_log("%d rounds %d edges\n", tp.ntrims, nedges);
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

  solver_ctx(const trimparams tp, bool mutate_nonce) : trimmer(tp), cg(MAXEDGES, MAXEDGES, MAX_SOLS, IDXSHIFT) {
    edges   = new uint2[MAXEDGES];
    mutatenonce = mutate_nonce;
  }

  void setheadernonce(char * const headernonce, const u32 len, const u32 nonce) {
    if (mutatenonce)
      ((u32 *)headernonce)[len/sizeof(u32)-1] = htole32(nonce); // place nonce at end
    setheader(headernonce, len, &trimmer.sipkeys);
    sols.clear();
  }
  ~solver_ctx() {
    delete[] edges;
  }

  int findcycles(uint2 *edges, u32 nedges) {
    cg.reset();
    for (u32 i = 0; i < nedges; i++)
      cg.add_compress_edge(edges[i].x, edges[i].y);
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
      cudaMemcpyToSymbol(recovery, soledges, sizeof(soledges));
      cudaMemset(trimmer.indexesA, 0, trimmer.indexesSize);
#ifdef VERBOSE
    print_log("Recovery<><<<%d,%d>>>\n", trimmer.tp.recover.blocks, trimmer.tp.recover.tpb);
#endif
      FluffyRecovery<<<trimmer.tp.recover.blocks, trimmer.tp.recover.tpb>>>((u32 *)trimmer.bufferA1);
      cudaMemcpy(&sols[sols.size()-PROOFSIZE], trimmer.bufferA1, PROOFSIZE * sizeof(u32), cudaMemcpyDeviceToHost);
      checkCudaErrors(cudaDeviceSynchronize());
      qsort(&sols[sols.size()-PROOFSIZE], PROOFSIZE, sizeof(u32), cg.nonce_cmp);
    }
    return 0;
  }

  int solve() {
    u64 time0, time1;
    u32 timems,timems2;

    trimmer.abort = false;
    time0 = timestamp();
    u32 nedges = trimmer.trim();
    if (!nedges)
      return 0;
    if (nedges > MAXEDGES) {
      print_log("OOPS; losing %d edges beyond MAXEDGES=%d\n", nedges-MAXEDGES, MAXEDGES);
      nedges = MAXEDGES;
    }
    cudaMemcpy(edges, trimmer.bufferB, sizeof(uint2[nedges]), cudaMemcpyDeviceToHost);
    time1 = timestamp(); timems  = (time1 - time0) / 1000000;
    time0 = timestamp();
    findcycles(edges, nedges);
    time1 = timestamp(); timems2 = (time1 - time0) / 1000000;
    print_log("trim time %d ms findcycles edges %d time %d ms total %d ms\n", timems, nedges, timems2, timems+timems2);
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
      int pow_rc = verify(prf, ctx->trimmer.sipkeys);
      if (pow_rc == POW_OK) {
        print_log("Verified with cyclehash ");
        unsigned char cyclehash[32];
        blake2b((void *)cyclehash, sizeof(cyclehash), (const void *)prf, sizeof(proof), 0, 0);
        for (int i=0; i<32; i++)
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
  print_log("create_solver_ctx %d = %d\n", tp.recover.tpb, params->recovertpb);
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

  return new SolverCtx(tp, params->mutate_nonce);
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
  params->recoverblocks = tp.recover.blocks;
  params->recovertpb = tp.recover.tpb;
  params->cpuload = false;
}


static_assert(NZ % (32 * TRIM0_TPB) == 0); // for Round_A1 ecounters init
static_assert(NZ % (32 * TRIM1_TPB) == 0); // for Round_A3 ecounters init
static_assert(NZ % (32 *  TRIM_TPB) == 0); // for Round_A2 ecounters init

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
      case 'm': // ntrims         =       458;
        params.ntrims = atoi(optarg) & -2; // odd number of trimming rounds is treated same as 1 less anyway
        break;
      case 'n':
        nonce = atoi(optarg);
        break;
      case 'r':
        range = atoi(optarg);
        break;
      case 'U': // seed.blocks    =      1024;
        params.genablocks = atoi(optarg);
        break;
      case 'Z': // recover.blocks =      2048;
        params.recoverblocks = atoi(optarg);
        break;
      case 'z': // recover.tpb    =       256;
        params.recovertpb = atoi(optarg);
        break;
    }
  }

  int nDevices;
  checkCudaErrors(cudaGetDeviceCount(&nDevices));
  assert(device < nDevices);
  cudaDeviceProp prop;
  checkCudaErrors(cudaGetDeviceProperties(&prop, device));
  u64 dbytes = prop.totalGlobalMem;
  int dunit;
  for (dunit=0; dbytes >= 102040; dbytes>>=10,dunit++) ;
  print_log("%s with %d%cB @ %d bits x %dMHz\n", prop.name, (u32)dbytes, " KMGT"[dunit], prop.memoryBusWidth, prop.memoryClockRate/1000);
  // cudaSetDevice(device);

  print_log("Looking for %d-cycle on cuckarood%d(\"%s\",%d", PROOFSIZE, EDGEBITS, header, nonce);
  if (range > 1)
    print_log("-%d", nonce+range-1);
  print_log(") with 50%% edges, %d*%d buckets, %d trims, and %d thread blocks.\n", NX, NY, params.ntrims, NX);

  assert(params.recovertpb >= PROOFSIZE);
  SolverCtx* ctx = create_solver_ctx(&params);

  u64 bytes = ctx->trimmer.globalbytes();
  int unit;
  for (unit=0; bytes >= 102400; bytes>>=10,unit++) ;
  print_log("Using %d%cB of global memory.\n", (u32)bytes, " KMGT"[unit]);

  run_solver(ctx, header, sizeof(header), nonce, range, NULL, NULL);

  return 0;
}
