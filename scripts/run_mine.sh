#!/usr/bin/env bash
set -euo pipefail
if grep -q '^DRY_RUN=true' .env 2>/dev/null; then
  echo "Refusing to run live: .env has DRY_RUN=true"
  exit 1
fi
if grep -q '^MINER_MODE=cuda-native' .env 2>/dev/null; then
  if [ ! -x ./miner_cuda ]; then
    echo "miner_cuda not found; building CUDA miner..."
    bash scripts/build_cuda.sh
  fi
fi
node orchestrator.mjs mine
