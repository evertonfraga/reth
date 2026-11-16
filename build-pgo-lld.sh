#!/usr/bin/env bash
# build.sh + a PGO two-pass build. Deps + release build of the reth node, plus the eth_call workload assets:
# a pinned oha load generator and a dev genesis with two pre-deployed contracts.
set -euo pipefail

if command -v apt-get >/dev/null; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential clang libclang-dev pkg-config libssl-dev git curl python3 perl patch m4 diffutils xz-utils zlib1g-dev libzstd-dev libxml2-dev libffi-dev
elif command -v dnf >/dev/null; then
  # AL2023 ships curl-minimal; requesting curl conflicts with it.
  sudo dnf install -y gcc gcc-c++ make clang clang-devel pkgconf-pkg-config openssl-devel git python3 perl patch m4 diffutils xz zlib-devel libzstd-devel libxml2-devel libffi-devel libzstd-static
fi

if ! command -v cargo >/dev/null; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
fi
source "$HOME/.cargo/env"
rustup update stable  # workspace needs rust-version >= 1.96
rustup default stable

# THP is system-wide and persists on a reused box: pin it every build so one
# experiment can't leak into the next (AL2023 default: madvise).
echo "${AUTOPERF_THP:-madvise}" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
echo "${AUTOPERF_THP_DEFRAG:-madvise}" | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null
# CPU idle states are system-wide too: re-enable all, then disable those whose exit latency
# exceeds AUTOPERF_MAX_IDLE_LATENCY_US (unset = all enabled, the default).
for state in /sys/devices/system/cpu/cpu*/cpuidle/state*; do
  [ -d "$state" ] || continue
  disable=0
  [ -n "${AUTOPERF_MAX_IDLE_LATENCY_US:-}" ] && [ "$(cat "$state/latency")" -gt "$AUTOPERF_MAX_IDLE_LATENCY_US" ] && disable=1
  echo "$disable" | sudo tee "$state/disable" >/dev/null
done

# The default `jit` feature links llvm-sys 231 (LLVM 23.1); distro LLVMs are older,
# so use the pinned upstream prebuilt (mirrors .github/scripts/install_llvm.sh).
LLVM_VERSION=23.1.4
LLVM_DIR=/opt/llvm-$LLVM_VERSION
case "$(uname -m)" in x86_64) LLVM_ARCH=X64 ;; aarch64) LLVM_ARCH=ARM64 ;; *) echo "unsupported arch"; exit 1 ;; esac
# Validate the whole tree, not just llvm-config: a box that rebooted mid-extract
# (AL2023 reboots once a few minutes after first boot) left a working llvm-config
# next to a missing libLLVM-23.so and missing headers, and a version-only check
# happily accepted it — llvm-sys then failed with "libLLVM-23.so is missing" /
# "llvm-c/Target.h: No such file". Extract to a temp dir and move it into place so
# the final path only ever exists complete.
llvm_ok() {
  [ "$("$LLVM_DIR/bin/llvm-config" --version 2>/dev/null)" = "$LLVM_VERSION" ] &&
  # The upstream tarball is a STATIC build (llvm-config --shared-mode = static,
  # no libLLVM*.so at all), so check a representative archive, not a shared lib.
  [ -f "$LLVM_DIR/lib/libLLVMCore.a" -o -e "$LLVM_DIR/lib/libLLVM.so" ] &&
  [ -f "$LLVM_DIR/include/llvm-c/Target.h" ]
}
if ! llvm_ok; then
  echo "installing LLVM $LLVM_VERSION (tree missing or incomplete)"
  sudo rm -rf "$LLVM_DIR" "$LLVM_DIR.part"
  sudo mkdir -p "$LLVM_DIR.part"
  curl -sSfL "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/LLVM-$LLVM_VERSION-Linux-$LLVM_ARCH.tar.xz" \
    | sudo tar -xJ -C "$LLVM_DIR.part" --strip-components=1
  sudo mv "$LLVM_DIR.part" "$LLVM_DIR"
  llvm_ok || { echo "LLVM install still incomplete at $LLVM_DIR"; exit 1; }
fi
# The prebuilt's `llvm-config --system-libs` names its build host's absolute paths
# (e.g. /usr/lib/x86_64-linux-gnu/libzstd.a); llvm-sys only accepts them if they
# exist, so point any missing one at this box's copy of the same library.
for lib in $("$LLVM_DIR/bin/llvm-config" --system-libs --link-static); do
  case "$lib" in /*) ;; *) continue ;; esac
  [ -e "$lib" ] && continue
  local_lib="$(ls /usr/lib64/"$(basename "$lib")" /usr/lib/"$(uname -m)"-linux-gnu/"$(basename "$lib")" 2>/dev/null | head -1 || true)"
  [ -n "$local_lib" ] || { echo "missing system lib for LLVM: $lib"; exit 1; }
  sudo mkdir -p "$(dirname "$lib")" && sudo ln -sf "$local_lib" "$lib"
done
export LLVM_SYS_231_PREFIX="$LLVM_DIR" LLVM_CONFIG_PATH="$LLVM_DIR/bin/llvm-config" PATH="$LLVM_DIR/bin:$PATH"

cd ~/repo

# ── PGO: a two-pass build. Pass 1 builds an instrumented binary, trains it on the
# same eth_call mix bench.sh runs (smaller counts: the profile only needs coverage
# of the hot paths, not a timed measurement), merges the raw profiles, then pass 2
# rebuilds with -Cprofile-use. The engine's RUSTFLAGS (target-cpu) must stay in
# both passes, or the comparison would also measure a codegen change.
rustup component add llvm-tools-preview
PROFDATA="$(find "$(rustc --print sysroot)" -name llvm-profdata -type f | head -1)"
[ -x "$PROFDATA" ] || { echo "llvm-profdata not found in sysroot"; exit 1; }
PGO_RAW=/tmp/pgo-raw
PGO_MERGED=/tmp/pgo.profdata
rm -rf "$PGO_RAW" "$PGO_MERGED"

# Build with an EXPLICIT --target (equal to the host) so RUSTFLAGS reach only the
# runtime binary. Without it cargo also instruments build scripts and proc macros
# and then RUNS them during the build: that crashed rustc with SIGILL on x86_64
# and, with everything instrumented, overflowed aarch64's +-128MB branch range
# (R_AARCH64_CALL26 "relocation truncated to fit"). Codegen for the measured
# binary is unchanged, so the comparison against the control stays fair.
TRIPLE="$(rustc -vV | awk '/^host: /{print $2}')"
TARGET_DIR="target/$TRIPLE/release"
# Instrumented code is far bigger than aarch64's +-128MB branch range, and GNU ld
# fails it ("relocation truncated to fit", R_AARCH64_CALL26). lld inserts
# range-extension thunks instead; LLVM 23's ld.lld is already on PATH from the
# LLVM install above. (-Ccode-model=large is NOT usable here: on aarch64 it
# rejects ELF TLS, which foldhash and others use.) Pass 1 only has to run the
# training workload, so its linker never affects the measured binary.
case "$(uname -m)" in aarch64) GEN_EXTRA="-Clink-arg=-fuse-ld=lld" ;; *) GEN_EXTRA="" ;; esac

echo "=== PGO pass 1: instrumented build ($TRIPLE) ==="
RUSTFLAGS="$RUSTFLAGS -Cprofile-generate=$PGO_RAW $GEN_EXTRA" \
  cargo build --release --target "$TRIPLE" --bin reth

echo "=== PGO training run ==="
W="$HOME/ethcall"
TRAIN_DATADIR="$(mktemp -d)"
"$TARGET_DIR/reth" node --dev --chain "$W/genesis.json" --datadir "$TRAIN_DATADIR" \
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth \
  --authrpc.addr 127.0.0.1 --addr 127.0.0.1 --disable-discovery --ipcdisable \
  --log.stdout.filter warn > "$W/pgo-node.log" 2>&1 &
TRAIN_NODE=$!
trap 'kill $TRAIN_NODE 2>/dev/null; wait $TRAIN_NODE 2>/dev/null; rm -rf "$TRAIN_DATADIR"' EXIT
call() { printf '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"0x00000000%064x"},"latest"]}' "$1" "$2"; }
rpc() { curl -sf -H 'Content-Type: application/json' -d "$1" http://127.0.0.1:8545; }
for _ in $(seq 180); do rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null && break; kill -0 $TRAIN_NODE || break; sleep 1; done
rpc '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null || { echo "PGO training node not ready"; tail -30 "$W/pgo-node.log"; exit 1; }
"$W/oha" --no-tui -n 20000 -c 64 -m POST -H 'Content-Type: application/json' \
  -d "$(call 0x0000000000000000000000000000000000001000 1)" http://127.0.0.1:8545 > /dev/null
"$W/oha" --no-tui -n 300 -c 8 -m POST -H 'Content-Type: application/json' \
  -d "$(call 0x0000000000000000000000000000000000002000 10000)" http://127.0.0.1:8545 > /dev/null
kill $TRAIN_NODE 2>/dev/null; wait $TRAIN_NODE 2>/dev/null; trap - EXIT; rm -rf "$TRAIN_DATADIR"

ls "$PGO_RAW"/*.profraw >/dev/null 2>&1 || { echo "no .profraw written by the training run"; exit 1; }
"$PROFDATA" merge -o "$PGO_MERGED" "$PGO_RAW"
echo "=== PGO pass 2: optimized build ($(du -h "$PGO_MERGED" | cut -f1) of profile data) ==="
# Same linker as build-bolt.sh pass 2, so a BOLT comparison isolates BOLT.
CARGO_PROFILE_RELEASE_STRIP=none \
RUSTFLAGS="$RUSTFLAGS -Cprofile-use=$PGO_MERGED -Clink-arg=-fuse-ld=lld" \
  cargo build --release --target "$TRIPLE" --bin reth

# bench.sh and test.sh run target/release/reth; --target put it one level deeper.
mkdir -p target/release && cp -f "$TARGET_DIR/reth" target/release/reth

W="$HOME/ethcall"
mkdir -p "$W"

# Prebuilt, pinned load generator: built outside this repo's RUSTFLAGS/profile so
# experiments never change the client side of the measurement.
OHA_VERSION=v1.16.0
case "$(uname -m)" in x86_64) OHA_ARCH=amd64 ;; aarch64) OHA_ARCH=arm64 ;; *) echo "unsupported arch"; exit 1 ;; esac
if [ "$("$W/oha" --version 2>/dev/null | awk '{print "v"$2}')" != "$OHA_VERSION" ]; then
  curl -sSfL -o "$W/oha" "https://github.com/hatoo/oha/releases/download/$OHA_VERSION/oha-linux-$OHA_ARCH"
  chmod +x "$W/oha"
fi

# Genesis = reth's dev allocs + two contracts (rewritten every build: idempotent).
#   0x..1000 LIGHT: return sload(calldataload(4))                         (1 SLOAD)
#   0x..2000 HEAVY: acc = keccak(acc + sload(i)) for i < calldataload(4)  (10k cold SLOADs, ~22M gas)
python3 -I - crates/chainspec/res/genesis/dev.json "$W/genesis.json" 10000 <<'EOF'
import json, sys
dev = json.load(open(sys.argv[1]))
nslots = int(sys.argv[3])
alloc = dict(dev["alloc"])
alloc["0x0000000000000000000000000000000000001000"] = {
    "balance": "0x0", "code": "0x6004355460005260206000f3",
    "storage": {"0x%064x" % 1: "0x%064x" % 0x2a}}
alloc["0x0000000000000000000000000000000000002000"] = {
    "balance": "0x0",
    "code": "0x600435600060005b82821015602257815401600052602060002090600101906007565b60005260206000f3",
    "storage": {"0x%064x" % i: "0x%064x" % (i + 1) for i in range(nslots)}}
g = {k: dev[k] for k in ("nonce", "timestamp", "extraData", "gasLimit", "difficulty", "mixHash", "coinbase")}
g["config"] = {"chainId": 1337, "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0, "istanbulBlock": 0,
    "berlinBlock": 0, "londonBlock": 0, "terminalTotalDifficulty": 0, "terminalTotalDifficultyPassed": True,
    "shanghaiTime": 0, "cancunTime": 0}
g["alloc"] = alloc
json.dump(g, open(sys.argv[2], "w"))
EOF
