#!/usr/bin/env bash
# NODE side of the off-box benchmark. Starts the reth node, waits until it serves
# requests, runs the correctness + work-done gates, then EXITS leaving the node
# running for a load generator on another instance to drive.
#
# Binding: the node binds the address in NODE_BIND_ADDR, which the engine sets to
# this instance's PRIVATE VPC address — never 0.0.0.0, and these instances carry no
# public IP. Reachability comes from a security-group rule that allows tcp/8545
# from the benchmark group to itself, so only other benchmark instances in this VPC
# can connect. authrpc and p2p stay on loopback.
set -euo pipefail

W="$HOME/ethcall"
RETH="$HOME/repo/target/release/reth"
BIND="${NODE_BIND_ADDR:?engine must pass the private bind address}"
URL="http://$BIND:8545"
PIDFILE="$HOME/.ethcall-node.pid"
read -r -a EXTRA_ARGS <<< "${RETH_EXTRA_ARGS:-}"

# Any node from an earlier run, plus its datadir.
if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
pkill -x reth 2>/dev/null && sleep 2 || true
rm -rf "$HOME/.ethcall-datadir" && DATADIR="$HOME/.ethcall-datadir" && mkdir -p "$DATADIR"

nohup "$RETH" node --dev --chain "$W/genesis.json" --datadir "$DATADIR" \
  --http --http.addr "$BIND" --http.port 8545 --http.api eth \
  --authrpc.addr 127.0.0.1 --addr 127.0.0.1 --disable-discovery --ipcdisable \
  --log.stdout.filter warn ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} > "$W/node.log" 2>&1 &
echo $! > "$PIDFILE"
NODE=$(cat "$PIDFILE")

call() { printf '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"0x00000000%064x"},"latest"]}' "$1" "$2"; }
gas()  { printf '{"jsonrpc":"2.0","id":1,"method":"eth_estimateGas","params":[{"to":"%s","data":"0x00000000%064x"}]}' "$1" "$2"; }
rpc()  { curl -sf -H 'Content-Type: application/json' -d "$1" "$URL"; }
jget() { python3 -I -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1"; }

for _ in $(seq 180); do rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null && break; kill -0 $NODE || break; sleep 1; done
rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null || { echo "node not ready"; tail -40 "$W/node.log"; exit 1; }

# Same gates as the single-box harness, run here because they need the node's RPC.
LIGHT="$(call 0x0000000000000000000000000000000000001000 1)"
HEAVY="$(call 0x0000000000000000000000000000000000002000 10000)"
for body in "$LIGHT" "$HEAVY"; do
  rpc "$body" | grep -q '"result":"0x' || { echo "eth_call failed: $(rpc "$body")"; exit 1; }
done
HEAVY_GAS_DEC=$(python3 -I -c "print(int('$(rpc "$(gas 0x0000000000000000000000000000000000002000 10000)" | jget result)', 16))")
GAS_MIN="${ETHCALL_HEAVY_GAS_MIN:-20000000}"; GAS_MAX="${ETHCALL_HEAVY_GAS_MAX:-25000000}"
[ "$HEAVY_GAS_DEC" -ge "$GAS_MIN" ] && [ "$HEAVY_GAS_DEC" -le "$GAS_MAX" ] || {
  echo "heavy call did not do the expected work: gas=$HEAVY_GAS_DEC outside [$GAS_MIN, $GAS_MAX]"; exit 1; }

echo "NODE_READY pid=$NODE bind=$BIND gas=$HEAVY_GAS_DEC"
