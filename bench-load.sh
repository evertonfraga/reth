#!/usr/bin/env bash
# LOAD-GENERATOR side of the off-box benchmark. Drives the eth_call mix against a
# reth node running on a DIFFERENT instance in the same subnet, so the client's own
# CPU is not competing with the server for cores.
#
# Why this exists: with the client co-located, the light phase reached ~200k req/s
# on the fastest boxes and stopped improving — at that point it measured the load
# generator, not the node. The cost is real network RTT (~0.1-0.25ms same-AZ, vs
# ~0.01ms loopback), so absolute light-phase latency rises while finally becoming a
# property of the server.
set -euo pipefail

W="$HOME/ethcall"
URL="${ETHCALL_NODE_URL:?engine must pass the node URL}"
LIGHT_N="${ETHCALL_LIGHT_N:-200000}"
HEAVY_N="${ETHCALL_HEAVY_N:-2000}"
LIGHT_C="${ETHCALL_LIGHT_C:-64}"
HEAVY_C="${ETHCALL_HEAVY_C:-8}"
mkdir -p "$W"

# Pinned load generator, fetched here because this box never runs build.sh.
OHA_VERSION=v1.16.0
case "$(uname -m)" in x86_64) OHA_ARCH=amd64 ;; aarch64) OHA_ARCH=arm64 ;; *) echo "unsupported arch"; exit 1 ;; esac
if [ "$("$W/oha" --version 2>/dev/null | awk '{print "v"$2}')" != "$OHA_VERSION" ]; then
  curl -sSfL -o "$W/oha" "https://github.com/hatoo/oha/releases/download/$OHA_VERSION/oha-linux-$OHA_ARCH"
  chmod +x "$W/oha"
fi

call() { printf '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"0x00000000%064x"},"latest"]}' "$1" "$2"; }
LIGHT="$(call 0x0000000000000000000000000000000000001000 1)"
HEAVY="$(call 0x0000000000000000000000000000000000002000 10000)"
rpc() { curl -sf -H 'Content-Type: application/json' -d "$1" "$URL"; }

# Reachability + correctness over the network before timing, so a security-group or
# bind problem fails here instead of surfacing as a slow run.
for _ in $(seq 60); do rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null && break; sleep 1; done
rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null || { echo "cannot reach node at $URL"; exit 1; }
for body in "$LIGHT" "$HEAVY"; do
  rpc "$body" | grep -q '"result":"0x' || { echo "eth_call failed over the network: $(rpc "$body")"; exit 1; }
done

"$W/oha" --no-tui -n 2000 -c 16 -m POST -H 'Content-Type: application/json' -d "$LIGHT" "$URL" > /dev/null

oha_run() { "$W/oha" --no-tui -n "$1" -c "$2" -m POST -H 'Content-Type: application/json' -d "$3" "$URL"; }
now() { python3 -I -c 'import time; print(time.monotonic())'; }

echo "=== eth_call light: $LIGHT_N calls, c=$LIGHT_C (off-box client) ==="
L0=$(now); oha_run "$LIGHT_N" "$LIGHT_C" "$LIGHT"; L1=$(now)
echo "=== eth_call heavy: $HEAVY_N calls, c=$HEAVY_C (off-box client) ==="
H0=$(now); oha_run "$HEAVY_N" "$HEAVY_C" "$HEAVY"; H1=$(now)

python3 -I - "$L0" "$L1" "$H0" "$H1" <<'PY'
import sys
l0, l1, h0, h1 = map(float, sys.argv[1:5])
light, heavy = l1 - l0, h1 - h0
print(f"BENCH_PHASE:light:{light:.3f}")
print(f"BENCH_PHASE:heavy:{heavy:.3f}")
print(f"BENCH_RESULT:{light + heavy:.3f}")
PY
