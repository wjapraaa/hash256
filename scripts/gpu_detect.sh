#!/usr/bin/env bash
set -e
echo "== GPU detector =="
if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi; else echo "nvidia-smi not found / GPU runtime not enabled"; fi
echo
echo "== CUDA compiler =="
if command -v nvcc >/dev/null 2>&1; then nvcc --version; else echo "nvcc not found"; fi
echo
echo "== CPU/RAM =="
python3 - <<'PY'
import os, platform
print('platform:', platform.platform())
print('cpu_count:', os.cpu_count())
try:
    import psutil
    print('ram_gb:', round(psutil.virtual_memory().total/1e9,2))
except Exception: pass
PY
