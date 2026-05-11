#!/usr/bin/env bash
set -euo pipefail
gcc -O3 -pthread -o miner miner.c
echo "Built ./miner"
