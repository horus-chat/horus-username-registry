#!/usr/bin/env bash
# Deploy username_registry with icp-cli.
# Usage:
#   ./deploy.sh           # local network (free)
#   ./deploy.sh mainnet   # YOU MUST TOP UP CYCLES FIRST — will prompt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
TARGET="${1:-local}"

if ! command -v icp >/dev/null 2>&1; then
  echo "Install: npm i -g @icp-sdk/icp-cli @icp-sdk/ic-wasm ic-mops" >&2
  exit 1
fi

canister_id() {
  local env="$1"
  icp canister status username_registry --id-only -e "$env" | tr -d '[:space:]'
}

if [[ "$TARGET" == "local" ]]; then
  icp network start -d 2>/dev/null || true
  icp deploy -y
  ID="$(canister_id local)"
  echo "$ID" >.canister_id
  echo "canister_id=$ID"
  echo "registry_url=http://$ID.raw.localhost:8000"
  echo "Point clients at registry_url (local replica / simulator only)."
  exit 0
fi

if [[ "$TARGET" != "mainnet" && "$TARGET" != "ic" ]]; then
  echo "Usage: $0 [local|mainnet]" >&2
  exit 1
fi

echo ""
echo "=== MAINNET DEPLOY — TOP UP YOUR WALLET/CYCLES FIRST ==="
echo "This spends cycles. Identity principal:"
icp identity principal || true
if [[ "$(icp identity default 2>/dev/null || true)" == "anonymous" ]]; then
  echo "Stop: default identity is anonymous (2vxsx-fae). Create one first:" >&2
  echo "  icp identity new horus" >&2
  echo "  icp identity default horus" >&2
  exit 1
fi
echo "ICP balance (mainnet):"
icp token balance -n ic || true
echo "Cycles balance (mainnet):"
icp cycles balance -n ic || true
echo ""
echo "This will run: icp deploy -y -e mainnet"
echo "Continue? (yes/no)"
read -r ans
[[ "$ans" == "yes" ]] || exit 1

# Explicit mainnet env in icp.yaml (network: ic). Never bare `icp deploy` — that is local.
icp deploy -y -e mainnet
ID="$(canister_id mainnet)"
echo "$ID" >.canister_id
echo "canister_id=$ID"
echo "registry_url=https://$ID.raw.icp0.io"
echo "Configure clients with registry_url. Do not commit identities or cycle wallets."
