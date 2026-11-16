#!/usr/bin/env bash
# eth_call throughput against the unmodified release reth node (--dev, genesis
# from build.sh). Two phases, timed SEPARATELY and reported to the engine:
#   light: ETHCALL_LIGHT_N calls of a 1-SLOAD view       (RPC/dispatch overhead dominates)
#   heavy: ETHCALL_HEAVY_N calls of a 10k-SLOAD+keccak loop (EVM + state reads dominate)
#
# The node is started and warmed BEFORE timing begins, and the timed region covers
# only the request phases. The engine's own wall-clock also contained node startup,
# genesis init and teardown — a steady 1.4-1.5s of an 8.6s run (17%) that diluted
# every delta. `BENCH_RESULT:` is the workload time the engine records instead;
# `BENCH_PHASE:` gives it the per-phase split so one run can attribute a change.
#
# The node binds loopback only (RPC, authrpc, p2p) with discovery off.
set -euo pipefail

W="$HOME/ethcall"
RETH="$HOME/repo/target/release/reth"
URL=http://127.0.0.1:8545
LIGHT_N="${ETHCALL_LIGHT_N:-200000}"
HEAVY_N="${ETHCALL_HEAVY_N:-2000}"
# Extra node flags for config experiments (experiment `runtime_env`); unset = stock node.
read -r -a EXTRA_ARGS <<< "${RETH_EXTRA_ARGS:-}"
# Optional CPU pinning (taskset lists) for the node and the load generator; unset = no pinning.
RETH_PIN=(); [ -n "${RETH_CPUS:-}" ] && RETH_PIN=(taskset -c "$RETH_CPUS")
OHA_PIN=(); [ -n "${OHA_CPUS:-}" ] && OHA_PIN=(taskset -c "$OHA_CPUS")

pkill -x reth 2>/dev/null && sleep 2 || true  # stale node from an aborted run
DATADIR="$(mktemp -d -p "${ETHCALL_DATADIR_BASE:-/tmp}")"  # /tmp is tmpfs on AL2023
${RETH_PIN[@]+"${RETH_PIN[@]}"} "$RETH" node --dev --chain "$W/genesis.json" --datadir "$DATADIR" \
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth \
  --authrpc.addr 127.0.0.1 --addr 127.0.0.1 --disable-discovery --ipcdisable \
  --log.stdout.filter warn ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} > "$W/node.log" 2>&1 &
NODE=$!
trap 'kill $NODE 2>/dev/null; wait $NODE 2>/dev/null; rm -rf "$DATADIR"' EXIT

call() { printf '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"0x00000000%064x"},"latest"]}' "$1" "$2"; }
gas()  { printf '{"jsonrpc":"2.0","id":1,"method":"eth_estimateGas","params":[{"to":"%s","data":"0x00000000%064x"}]}' "$1" "$2"; }
LIGHT="$(call 0x0000000000000000000000000000000000001000 1)"
HEAVY="$(call 0x0000000000000000000000000000000000002000 10000)"
rpc() { curl -sf -H 'Content-Type: application/json' -d "$1" "$URL"; }
jget() { python3 -I -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1"; }

for _ in $(seq 180); do rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null && break; kill -0 $NODE || break; sleep 1; done
rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null || { echo "node not ready"; tail -50 "$W/node.log"; exit 1; }

# ── correctness + work-done gate, BEFORE timing ──────────────────────────────
# oha only sees HTTP status and JSON-RPC errors are 200s, so prove both calls
# return the right value first.
#
# The gas check then proves the heavy call really ran its 10k iterations rather
# than short-circuiting: ~2100 gas per cold SLOAD plus the keccak and loop puts a
# full run above 20M, while a loop that exited early costs orders of magnitude
# less. It is a BAND, not an equality, because estimators differ — reth reports
# 22,227,399 where anvil reports 22,051,222 for the same call.
#
# Note what this does NOT prove: gas is charged per SLOAD *opcode* whether or not
# the read was served from a cache, so this is not a guard against a build that
# memoises state reads. Proving the database was actually touched needs reth's own
# read counters (--metrics); see .autoperf/plans/.
for body in "$LIGHT" "$HEAVY"; do
  rpc "$body" | grep -q '"result":"0x' || { echo "eth_call failed: $(rpc "$body")"; exit 1; }
done
HEAVY_GAS=$(rpc "$(gas 0x0000000000000000000000000000000000002000 10000)" | jget result)
HEAVY_GAS_DEC=$(python3 -I -c "print(int('$HEAVY_GAS', 16))")
GAS_MIN="${ETHCALL_HEAVY_GAS_MIN:-20000000}"; GAS_MAX="${ETHCALL_HEAVY_GAS_MAX:-25000000}"
[ "$HEAVY_GAS_DEC" -ge "$GAS_MIN" ] && [ "$HEAVY_GAS_DEC" -le "$GAS_MAX" ] || {
  echo "heavy call did not do the expected work: gas=$HEAVY_GAS_DEC outside [$GAS_MIN, $GAS_MAX]"; exit 1; }
echo "work-done gate ok: heavy gas=$HEAVY_GAS_DEC"

# Warm the server's caches/JIT-free paths so phase 1 isn't paying first-touch costs.
"$W/oha" --no-tui -n 2000 -c 16 -m POST -H 'Content-Type: application/json' -d "$LIGHT" "$URL" > /dev/null

# ── timed region: the requests only ──────────────────────────────────────────
oha_run() { ${OHA_PIN[@]+"${OHA_PIN[@]}"} "$W/oha" --no-tui -n "$1" -c "$2" -m POST -H 'Content-Type: application/json' -d "$3" "$URL"; }
now() { python3 -I -c 'import time; print(time.monotonic())'; }

echo "=== eth_call light: $LIGHT_N calls, c=64 ==="
L0=$(now); oha_run "$LIGHT_N" 64 "$LIGHT"; L1=$(now)
echo "=== eth_call heavy: $HEAVY_N calls, c=8 ==="
H0=$(now); oha_run "$HEAVY_N" 8 "$HEAVY"; H1=$(now)

python3 -I - "$L0" "$L1" "$H0" "$H1" <<'PY'
import sys
l0, l1, h0, h1 = map(float, sys.argv[1:5])
light, heavy = l1 - l0, h1 - h0
print(f"BENCH_PHASE:light:{light:.3f}")
print(f"BENCH_PHASE:heavy:{heavy:.3f}")
print(f"BENCH_RESULT:{light + heavy:.3f}")
PY
