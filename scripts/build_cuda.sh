#!/usr/bin/env bash
set -euo pipefail
if ! command -v nvcc >/dev/null 2>&1; then echo "nvcc not found"; exit 1; fi
nvcc -O3 -std=c++17 -gencode arch=compute_75,code=compute_75 -o miner_cuda miner_cuda.cu
echo "Built ./miner_cuda"
