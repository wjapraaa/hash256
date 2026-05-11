import 'dotenv/config';
import { createPublicClient, createWalletClient, http, parseGwei, formatEther, encodeFunctionData, encodeAbiParameters, keccak256, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';

const CONTRACT = getAddress(process.env.CONTRACT_ADDRESS || '0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc');
const RPC_URL = process.env.RPC_URL;
const CHAIN_ID = BigInt(process.env.CHAIN_ID || '1');
const DRY_RUN = String(process.env.DRY_RUN || 'true').toLowerCase() !== 'false';
const BATCH_SIZE = BigInt(process.env.BATCH_SIZE || '20000');
const MAX_BATCHES = Number(process.env.MAX_BATCHES_PER_EPOCH || '999999');

const abi = [
  { type:'function', name:'mine', stateMutability:'nonpayable', inputs:[{name:'nonce',type:'uint256'}], outputs:[] },
  { type:'function', name:'currentDifficulty', stateMutability:'view', inputs:[], outputs:[{type:'uint256'}] },
  { type:'function', name:'balanceOf', stateMutability:'view', inputs:[{name:'account',type:'address'}], outputs:[{type:'uint256'}] },
  { type:'function', name:'currentReward', stateMutability:'view', inputs:[], outputs:[{type:'uint256'}] },
  { type:'function', name:'getChallenge', stateMutability:'view', inputs:[{name:'miner',type:'address'}], outputs:[{type:'bytes32'}] },
];

function needEnv() {
  if (!RPC_URL) throw new Error('RPC_URL missing. Create .env first.');
  if (!process.env.PRIVATE_KEY) throw new Error('PRIVATE_KEY missing. Use a fresh wallet only.');
}

function targetHex(target) { return '0x' + target.toString(16).padStart(64, '0'); }
function nonceHex(n) { return '0x' + n.toString(16).padStart(64, '0'); }
function hashProof(challenge, nonce) {
  return keccak256(encodeAbiParameters([{type:'bytes32'}, {type:'uint256'}], [challenge, nonce]));
}
function computeChallenge(miner, blockNumber) {
  const epoch = blockNumber / 100n;
  return keccak256(encodeAbiParameters(
    [{type:'uint256'}, {type:'address'}, {type:'address'}, {type:'uint256'}],
    [CHAIN_ID, CONTRACT, miner, epoch]
  ));
}

async function clients() {
  needEnv();
  const account = privateKeyToAccount(process.env.PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: mainnet, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account, chain: mainnet, transport: http(RPC_URL) });
  return { account, publicClient, walletClient };
}

async function readChallenge(publicClient, miner) {
  try {
    return await publicClient.readContract({ address: CONTRACT, abi, functionName: 'getChallenge', args: [miner] });
  } catch (_) {
    const block = await publicClient.getBlockNumber();
    return computeChallenge(miner, block);
  }
}

async function status() {
  const { account, publicClient } = await clients();
  const [ethBal, target, reward, hashBal, challenge, block] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.readContract({ address: CONTRACT, abi, functionName: 'currentDifficulty' }),
    publicClient.readContract({ address: CONTRACT, abi, functionName: 'currentReward' }).catch(() => 0n),
    publicClient.readContract({ address: CONTRACT, abi, functionName: 'balanceOf', args:[account.address] }).catch(() => 0n),
    readChallenge(publicClient, account.address),
    publicClient.getBlockNumber(),
  ]);
  console.log('Wallet:', account.address);
  console.log('Block:', block.toString(), 'Epoch:', (block/100n).toString());
  console.log('ETH balance:', formatEther(ethBal));
  console.log('HASH balance raw:', hashBal.toString());
  console.log('Current reward raw:', reward.toString());
  console.log('Difficulty target:', targetHex(target));
  console.log('Challenge:', challenge);
  console.log('DRY_RUN:', DRY_RUN);
}

function verify() {
  // Ethereum keccak256 of 64 zero bytes, matches guide vector.
  const zero64 = '0x' + '00'.repeat(64);
  const h = keccak256(zero64);
  console.log('keccak256(64 zero bytes) =', h.slice(2));
  console.log(h.slice(2) === 'ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5' ? 'OK' : 'NOTE: compare with guide vector manually');
}

async function findNonceCpuJs(challenge, target, startNonce=0n) {
  let nonce = startNonce;
  for (let batch=0; batch<MAX_BATCHES; batch++) {
    const end = nonce + BATCH_SIZE;
    for (; nonce < end; nonce++) {
      const h = hashProof(challenge, nonce);
      if (BigInt(h) < target) return { nonce, hash: h };
    }
    if (batch % 10 === 0) console.error(`searched=${nonce} last=${nonceHex(nonce)}`);
  }
  return null;
}

function randomStartHex64() {
  const a = crypto.getRandomValues(new Uint32Array(2));
  return '0x' + Array.from(a).map(x => x.toString(16).padStart(8, '0')).join('');
}

async function findNonceCudaNative(challenge, target) {
  if (!existsSync('./miner_cuda')) {
    throw new Error('./miner_cuda not found. Run: bash scripts/build_cuda.sh');
  }
  const startHex = randomStartHex64();
  const loops = process.env.CUDA_LOOPS_PER_THREAD || '4096';
  const args = [challenge, targetHex(target), startHex, loops];
  console.log('spawning ./miner_cuda', args.join(' '));

  return await new Promise((resolve, reject) => {
    const child = spawn('./miner_cuda', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let settled = false;
    child.stdout.on('data', (buf) => {
      const text = buf.toString();
      process.stdout.write(text);
      const m = text.match(/NONCE_FOUND\s+([0-9a-fA-F]+)/);
      if (m && !settled) {
        settled = true;
        const nonce = BigInt('0x' + m[1]);
        child.kill('SIGTERM');
        resolve({ nonce, hash: hashProof(challenge, nonce) });
      }
    });
    child.stderr.on('data', (buf) => process.stderr.write(buf));
    child.on('error', (err) => { if (!settled) { settled = true; reject(err); } });
    child.on('exit', (code) => {
      if (!settled) {
        settled = true;
        reject(new Error(`miner_cuda exited before finding nonce, code=${code}`));
      }
    });
  });
}

async function findNonce(challenge, target) {
  const mode = process.env.MINER_MODE || 'cpu-js';
  if (mode === 'cuda-native') return await findNonceCudaNative(challenge, target);
  const start = BigInt(randomStartHex64());
  return await findNonceCpuJs(challenge, target, start);
}

async function fees(publicClient, revertStreak=0) {
  const block = await publicClient.getBlock({ blockTag: 'pending' }).catch(() => null);
  const base = block?.baseFeePerGas || parseGwei('1');
  const bump = BigInt(Math.min(revertStreak, 5));
  const prioGwei = Math.min(Number(process.env.MAX_PRIORITY_GWEI || '8'), Math.max(Number(base / parseGwei('1')), 1) + Number(bump) * Number(process.env.REVERT_BUMP_GWEI || '1'));
  const priority = parseGwei(String(prioGwei));
  return { maxFeePerGas: base * 2n + priority, maxPriorityFeePerGas: priority };
}

async function mineLoop() {
  const { account, publicClient, walletClient } = await clients();
  console.log('Starting miner for', account.address, 'mode=', process.env.MINER_MODE || 'cpu-js', 'dry=', DRY_RUN);
  let revertStreak = 0;
  while (true) {
    const chainTarget = await publicClient.readContract({ address: CONTRACT, abi, functionName: 'currentDifficulty' });
    const target = process.env.TEST_TARGET ? BigInt(process.env.TEST_TARGET) : chainTarget;
    const challenge = await readChallenge(publicClient, account.address);
    console.log('challenge=', challenge, 'target=', targetHex(target));
    const found = await findNonce(challenge, target);
    if (!found) { console.log('No nonce found before batch limit; restarting.'); continue; }
    console.log('NONCE_FOUND', found.nonce.toString(16), 'hash=', found.hash);
    if (DRY_RUN) { console.log('DRY_RUN=true, not submitting tx. Set DRY_RUN=false only after verifying costs/ToS.'); return; }
    const data = encodeFunctionData({ abi, functionName:'mine', args:[found.nonce] });
    const fee = await fees(publicClient, revertStreak);
    const gas = 160000n;
    const hash = await walletClient.sendTransaction({ to: CONTRACT, data, gas, ...fee });
    console.log('tx=', hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log('receipt status=', receipt.status, 'gasUsed=', receipt.gasUsed.toString());
    if (receipt.status === 'success') revertStreak = 0; else revertStreak++;
  }
}

const cmd = process.argv[2] || 'status';
if (cmd === 'status') await status();
else if (cmd === 'verify') verify();
else if (cmd === 'mine') await mineLoop();
else { console.error('Usage: node orchestrator.mjs [status|verify|mine]'); process.exit(1); }
