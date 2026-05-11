# HASH256 Colab Miner Scaffold

Repo ini dibuat untuk workflow: upload source ke GitHub, lalu clone dari Google Colab.

> Penting: cek Terms of Service Google Colab. Banyak layanan notebook/cloud melarang crypto mining. Gunakan ini minimal untuk status/dry-run/testing.

## Isi aman untuk GitHub

- Source code dan script boleh di-commit.
- Jangan commit `.env`, private key, `wallet.json`, log, atau API key.

## Quick start di Colab/server

```bash
git clone https://github.com/USERNAME/hash256-colab-miner.git
cd hash256-colab-miner
bash scripts/setup_colab.sh
cp .env.example .env
nano .env
chmod 600 .env
npm run verify
npm run status
npm run dry
```

Default `DRY_RUN=true`, jadi tidak submit transaksi. Untuk live submit, ubah `.env` ke `DRY_RUN=false` setelah yakin.

## Catatan implementasi

- `orchestrator.mjs` sudah bisa `status`, `verify`, dan `mine` mode `cpu-js` portable.
- `miner.c` dan `miner_cuda.cu` sekarang placeholder agar struktur repo siap. Masukkan kernel C/CUDA optimized sebelum berharap hashrate kompetitif.
- CPU JS sangat lambat dan hanya cocok untuk dry-run/dev.

## Security

Gunakan wallet baru khusus mining, isi ETH secukupnya saja, dan sweep HASH ke wallet aman secara berkala.
