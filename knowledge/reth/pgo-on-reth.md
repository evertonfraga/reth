# PGO on reth: what breaks, and the flags that work

Measured on 2026-11-05 against the `eth_call` workload (reth 2.8.1-dev, stable
rustc 1.99.1 / LLVM 23.1, AL2023). Three failures, in the order they appear:

## 1. Instrumenting build scripts and proc macros

`RUSTFLAGS="-Cprofile-generate=..." cargo build` applies the flag to **host**
artifacts too, so cargo builds instrumented build scripts and proc macros and
then *runs* them during the build.

Fix: pass an explicit `--target "$(rustc -vV | awk '/^host: /{print $2}')"`.
Cargo then keeps host artifacts un-instrumented. Codegen for the measured binary
is unchanged, so a comparison against a non-PGO control stays fair. Remember the
binary lands in `target/<triple>/release/`, not `target/release/`.

## 2. aarch64: `relocation truncated to fit: R_AARCH64_CALL26`

The instrumented binary outgrows aarch64's ±128 MB branch range and GNU `ld`
fails rather than inserting thunks.

- **Works:** `-Clink-arg=-fuse-ld=lld` on the instrumented pass only (lld inserts
  range-extension thunks). reth's `jit` feature already installs LLVM, so
  `ld.lld` is on PATH.
- **Does NOT work:** `-Ccode-model=large` — on aarch64 it rejects ELF TLS
  (`rustc-LLVM ERROR: ELF TLS only supported in small memory model or in local
  exec TLS model`), and `foldhash`, a transitive dependency, uses TLS.

Keep the instrumented pass's linker off the *measured* build: pass 1 only has to
run the training workload.

## 3. x86_64: rustc `SIGILL` inside LLVM — FIXED by a newer toolchain

**Resolved 2026-11-16.** All five x86 families build instrumented reth on stable
**rustc 1.100.0** with no workaround. PGO therefore needs no unstable toolchain on
any architecture. The history below is kept because the failure is specific to
1.99.1 and may recur on a pinned older toolchain.

### Original (stable rustc 1.99.1)

Instrumenting the `reth` bin crate crashes rustc's own LLVM:

```
error: rustc interrupted by SIGILL, printing backtrace
  libLLVM.so.23.1-rust-1.99.1-stable(+0xa4deeb5)
```

It reproduces with the `--target` fix applied, so it is not flag misuse. No
workaround found; PGO was measured on aarch64 only. Worth retrying on a newer
toolchain, or with `codegen-units=1` on the instrumented pass.

## Training

The profile only needs coverage of the hot paths, not a timed measurement, so the
training run uses the same light+heavy `eth_call` mix at ~10% of the benchmark's
request counts. `llvm-profdata` ships in the toolchain via
`rustup component add llvm-tools-preview`; find it under `$(rustc --print
sysroot)` rather than assuming a path.

See `.autoperf/build-pgo.sh` for the working two-pass script.

## BOLT on top of PGO: blocked (4 attempts, 2026-11-05)

The instrument → train → profile stages all work on aarch64 (BOLT's
instrumentation mode, since Graviton has no LBR). Only the final rewrite is
blocked, and each fix exposed the next wall:

1. `BOLT-ERROR: binary contains Cortex-A53 erratum 843419 workaround veneers` —
   rustc passes `-Wl,--fix-cortex-a53-843419` for this target.
2. `-Clink-arg=-Wl,--no-fix-cortex-a53-843419` → `/usr/bin/ld: unrecognized
   option` (AL2023 binutils has no counterpart flag). BOLT's own
   `--drop-cortex-a53-843419-veneers` is the right lever instead; it is safe here
   because Neoverse is never Cortex-A53.
3. With `--emit-relocs` (BOLT needs it), GNU ld fails the final link outright:
   `final link failed: invalid operation` across 6137 object files.
4. Linking pass 2 with lld instead: `ld.lld: error: --strip-all and
   --emit-relocs may not be used together` — the release profile's
   `strip = "symbols"` becomes `--strip-all`, and `CARGO_PROFILE_RELEASE_STRIP=none`
   does not reach every crate that invokes the linker.

**If picking this up again:** keep `--emit-relocs` out of global `RUSTFLAGS`.
Build dependencies normally, then relink only the `reth` binary with
`cargo rustc --bin reth -- -Clink-arg=-Wl,--emit-relocs` plus `strip=none`, so
the flag never reaches a dependency's link. Budget a couple of hours; the
expected payoff (2-5% on top of PGO) did not justify more time in a 3.5h window
that had already produced two confirmed wins.
