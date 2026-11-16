#!/usr/bin/env bash
# build.sh on a NIGHTLY toolchain (for evm2's tco dispatch). Deps + release build of the reth node, plus the eth_call workload assets:
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
# Nightly: evm2's build.rs selects its tail-call interpreter dispatch only on a
# nightly rustc (crates/evm2/build.rs). Everything else matches build.sh.
rustup toolchain install nightly --profile minimal
rustup default nightly

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
cargo build --release --bin reth

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
