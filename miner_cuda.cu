// Minimal CUDA Keccak-256 miner for HASH256-style proof:
//   keccak256(abi.encode(bytes32 challenge, uint256 nonce)) < target
// Usage:
//   ./miner_cuda <challengeHex32> <targetHex32> [startNonceHex] [loopsPerThread]
// Prints:
//   NONCE_FOUND <nonce_hex_without_0x>
// Notes:
// - Uses Ethereum Keccak padding (0x01 ... 0x80), not NIST SHA3 padding.
// - Nonce is limited to uint64 search space in this minimal version, encoded as uint256 big-endian.

#include <cuda_runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <chrono>
#include <random>

#define KECCAK_ROUNDS 24
#define THREADS_PER_BLOCK 256
#define BLOCKS 256

__device__ __constant__ uint8_t d_challenge[32];
__device__ __constant__ uint8_t d_target[32];

__device__ __forceinline__ uint64_t rotl64(uint64_t x, int s) {
    return (x << s) | (x >> (64 - s));
}

__device__ __constant__ uint64_t keccakf_rndc[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

__device__ __constant__ int keccakf_rotc[24] = {
    1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
    27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
};

__device__ __constant__ int keccakf_piln[24] = {
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
};

__device__ void keccakf(uint64_t st[25]) {
    uint64_t bc[5];
    for (int round = 0; round < KECCAK_ROUNDS; round++) {
        // Theta
        for (int i = 0; i < 5; i++) bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
        for (int i = 0; i < 5; i++) {
            uint64_t t = bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1);
            for (int j = 0; j < 25; j += 5) st[j + i] ^= t;
        }
        // Rho Pi
        uint64_t t = st[1];
        for (int i = 0; i < 24; i++) {
            int j = keccakf_piln[i];
            uint64_t tmp = st[j];
            st[j] = rotl64(t, keccakf_rotc[i]);
            t = tmp;
        }
        // Chi
        for (int j = 0; j < 25; j += 5) {
            for (int i = 0; i < 5; i++) bc[i] = st[j + i];
            for (int i = 0; i < 5; i++) st[j + i] ^= ((~bc[(i + 1) % 5]) & bc[(i + 2) % 5]);
        }
        // Iota
        st[0] ^= keccakf_rndc[round];
    }
}

__device__ __forceinline__ void store64le(uint8_t *p, uint64_t v) {
    #pragma unroll
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

__device__ __forceinline__ bool hash_lt_target(const uint8_t h[32]) {
    // bytes32 cast to uint256 = big-endian numeric compare
    #pragma unroll
    for (int i = 0; i < 32; i++) {
        uint8_t a = h[i];
        uint8_t b = d_target[i];
        if (a < b) return true;
        if (a > b) return false;
    }
    return false;
}

__device__ void keccak256_64bytes(uint64_t nonce, uint8_t out[32]) {
    uint8_t block[136];
    #pragma unroll
    for (int i = 0; i < 136; i++) block[i] = 0;

    // abi.encode(bytes32 challenge, uint256 nonce)
    #pragma unroll
    for (int i = 0; i < 32; i++) block[i] = d_challenge[i];

    // uint256 nonce big-endian in bytes 32..63. Minimal version searches uint64 only.
    #pragma unroll
    for (int i = 0; i < 24; i++) block[32 + i] = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) block[56 + i] = (uint8_t)(nonce >> (8 * (7 - i)));

    // Keccak padding for exactly 64-byte input, rate 136.
    block[64] = 0x01;
    block[135] |= 0x80;

    uint64_t st[25];
    #pragma unroll
    for (int i = 0; i < 25; i++) st[i] = 0;

    #pragma unroll
    for (int lane = 0; lane < 17; lane++) {
        uint64_t v = 0;
        #pragma unroll
        for (int b = 0; b < 8; b++) v |= ((uint64_t)block[lane * 8 + b]) << (8 * b);
        st[lane] ^= v;
    }
    keccakf(st);

    #pragma unroll
    for (int lane = 0; lane < 4; lane++) store64le(out + lane * 8, st[lane]);
}

__global__ void mine_kernel(uint64_t start, uint64_t stride, uint32_t loops, unsigned long long *found, int *flag) {
    uint64_t tid = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t nonce = start + tid;
    uint8_t h[32];

    for (uint32_t i = 0; i < loops; i++) {
        if (atomicAdd(flag, 0) != 0) return;
        keccak256_64bytes(nonce, h);
        if (hash_lt_target(h)) {
            if (atomicCAS(flag, 0, 1) == 0) *found = (unsigned long long)nonce;
            return;
        }
        nonce += stride;
    }
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + c - 'a';
    if (c >= 'A' && c <= 'F') return 10 + c - 'A';
    return -1;
}

static bool parse_hex32(const char *s, uint8_t out[32]) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    if (strlen(s) != 64) return false;
    for (int i = 0; i < 32; i++) {
        int hi = hexval(s[i * 2]);
        int lo = hexval(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

static uint64_t parse_u64_hex(const char *s) {
    if (!s || !*s) return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    uint64_t v = 0;
    while (*s) {
        int x = hexval(*s++);
        if (x < 0) break;
        v = (v << 4) | (uint64_t)x;
    }
    return v;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <challengeHex32> <targetHex32> [startNonceHex] [loopsPerThread]\n", argv[0]);
        return 2;
    }

    uint8_t h_challenge[32], h_target[32];
    if (!parse_hex32(argv[1], h_challenge)) { fprintf(stderr, "bad challenge hex\n"); return 2; }
    if (!parse_hex32(argv[2], h_target)) { fprintf(stderr, "bad target hex\n"); return 2; }

    uint64_t start;
    if (argc >= 4) start = parse_u64_hex(argv[3]);
    else {
        std::random_device rd;
        start = ((uint64_t)rd() << 32) ^ (uint64_t)rd();
    }
    uint32_t loops = (argc >= 5) ? (uint32_t)strtoul(argv[4], NULL, 10) : 4096;
    if (loops == 0) loops = 4096;

    cudaMemcpyToSymbol(d_challenge, h_challenge, 32);
    cudaMemcpyToSymbol(d_target, h_target, 32);

    unsigned long long *d_found;
    int *d_flag;
    cudaMalloc(&d_found, sizeof(unsigned long long));
    cudaMalloc(&d_flag, sizeof(int));
    cudaMemset(d_found, 0, sizeof(unsigned long long));
    cudaMemset(d_flag, 0, sizeof(int));

    const uint64_t stride = (uint64_t)THREADS_PER_BLOCK * BLOCKS;
    uint64_t batchHashes = stride * (uint64_t)loops;
    auto t0 = std::chrono::steady_clock::now();
    uint64_t total = 0;

    while (true) {
        mine_kernel<<<BLOCKS, THREADS_PER_BLOCK>>>(start, stride, loops, d_found, d_flag);
        cudaError_t err = cudaDeviceSynchronize();
        if (err != cudaSuccess) {
            fprintf(stderr, "cuda error: %s\n", cudaGetErrorString(err));
            return 1;
        }
        int flag = 0;
        cudaMemcpy(&flag, d_flag, sizeof(int), cudaMemcpyDeviceToHost);
        total += batchHashes;
        if (flag) {
            unsigned long long found;
            cudaMemcpy(&found, d_found, sizeof(unsigned long long), cudaMemcpyDeviceToHost);
            printf("NONCE_FOUND %016llx\n", found);
            fflush(stdout);
            return 0;
        }
        start += batchHashes;
        auto now = std::chrono::steady_clock::now();
        double sec = std::chrono::duration<double>(now - t0).count();
        if (sec >= 1.0) {
            double rate = (double)total / sec;
            fprintf(stderr, "rate=%.2f MH/s searched=%llu last=%016llx\n", rate / 1e6, (unsigned long long)total, (unsigned long long)start);
            t0 = now;
            total = 0;
        }
    }
}
