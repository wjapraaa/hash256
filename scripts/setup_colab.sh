#!/usr/bin/env bash
set -euo pipefail
echo "Installing Node dependencies..."
node -v || true
npm -v || true
npm install
bash scripts/gpu_detect.sh
