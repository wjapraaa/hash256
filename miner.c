// Placeholder native CPU miner entrypoint.
// The included orchestrator uses cpu-js mode by default for portability.
// Replace this file with an optimized pthread Keccak miner when ready.
#include <stdio.h>
int main(int argc, char **argv) {
  fprintf(stderr, "miner.c placeholder: use MINER_MODE=cpu-js or replace with optimized source.\n");
  return 2;
}
