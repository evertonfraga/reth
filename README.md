# eth_call benchmark harness

The measurement scaffolding behind the `perf/*` branches on this fork. It is
published separately **on purpose**: none of it belongs in a reth pull request,
because reth already has a maintained benchmark in
`.github/workflows/bench.yml`. This exists only so the numbers quoted in those
branches can be reproduced and criticised.

It was produced by AutoPerf, an EC2 benchmarking harness, and is not affiliated
with reth.

## Read this before trusting any number here

**The workload runs against a synthetic dev genesis, not mainnet state.** The
genesis holds ~22 accounts and two hand-written contracts, so the
`HashedStorages` main tree is 1-2 levels deep where mainnet is 5-6. Anything
whose gain comes from avoiding B-tree descent is therefore *understated* here,
and anything that only appears at mainnet depth is invisible. This is the single
biggest limitation and it cannot be fixed by rerunning; it needs a mainnet-sized
dataset.

**reth's own `bench.yml mode=call` is the better evidence** and could not be
run: it requires `runs-on: [self-hosted, …]` plus snapshot secrets, and its
`issue_comment` path checks that *both* the commenter and the PR author are
`paradigmxyz` org members. An outside contributor cannot trigger it.

**The latest `blocking_task.rs` revision is unmeasured.** Every result in
`results/` with `local_ref: d7c8d5c1c6` measured an earlier prototype that
dispatched to the tracing pool. See `experiments/exp-rayon-v2.yaml` for the
pending re-measurement.

## The workload

Two contracts in the dev genesis (`build.sh` generates it):

| address | behaviour | cost |
|---|---|---|
| `0x..1000` | `return sload(calldataload(4))` | 1 SLOAD |
| `0x..2000` | `acc = keccak(acc + sload(i))` for `i < n` | 10k cold SLOADs, ~22M gas |

Two timed phases, driven by a pinned `oha` v1.16.0:

- **light** — 200k `eth_call`s at 64 connections against `0x..1000`. Dominated by
  RPC dispatch and per-request overhead.
- **heavy** — 2k `eth_call`s at 8 connections against `0x..2000`. Dominated by
  storage reads and EVM execution.

Only the request phases are timed. The node is started, warmed and gated on a
correctness check first, and the measured value is the sum of the two phases
(`BENCH_RESULT`), not wall clock.

## Why the results are shaped the way they are

Several things had to be corrected before the numbers meant anything, and each
is worth knowing if you reuse this:

- **Fixed node-startup cost was 1.42-1.57s of every measurement** and uniform
  across all eight instance families. It is now subtracted (`fixed_overhead` in
  each `result.json`). Earlier deltas understated gains by roughly 1/7.
- **A profiler inflated timings 3.7x**, so timing runs and profiling runs are
  separate; every result records `profiling: false`.
- **Host drift is real.** The same unchanged build measured ~4% faster after a
  stop/start on a different host, and ~9% slower within minutes of first boot.
  Comparisons are therefore bracketed control -> change -> control on one host
  and boot; an unbracketed "vs parent" delta across suites is not trustworthy.
- **The first run after a box boots is inflated** by AL2023 first-boot work.
- **Warmup was once counted as a sample**, which showed up as 5.7% spread on a
  box that normally runs at ~1%.
- **Gas does not prove a DB read happened** — SLOAD is charged per opcode
  regardless of caching — so the correctness gate checks a gas *band*, not an
  exact figure, because reth's estimator differs from anvil's.

## Layout

```
bench.sh              timed light+heavy phases, client co-located with the node
bench-node.sh         node side when the client runs off-box (binds a private VPC IP)
bench-load.sh         client side when the client runs off-box
build.sh              deps, LLVM 23.1.4, plain release build, genesis generation
build-pgo.sh          two-pass PGO (the champion build)
build-pgo-lld.sh      PGO linking with lld (works around aarch64 R_AARCH64_CALL26)
build-bolt.sh         BOLT on top of PGO — does NOT complete, kept for the record
build-nightly*.sh     nightly toolchain variants (TCO dispatch)
experiments/*.yaml    one file per experiment: hypothesis, pinned code, build, families
results/<suite>/<family>.json   one measurement: median, phases, spread, cost, flags
knowledge/reth/*.md   what did and did not move the needle, and why
```

Each `result.json` records `median_time`, per-phase times, `run_times`,
`spread_pct`, `noisy`, the pinned `local_ref`, `rustflags`, instance type and
processor, so a result can be traced back to exactly what produced it.

## Reproducing

The scripts expect an EC2 instance with Amazon Linux 2023 and assume the engine
has already cloned reth to `~/repo`. Standalone, the useful parts are `build.sh`
(which generates the genesis and fetches the pinned load generator) and
`bench.sh` (which runs the two phases and prints `BENCH_PHASE:` / `BENCH_RESULT:`
lines). Both are plain bash and read top to bottom.

## Not included

Engine state, logs and per-family instance records are omitted: they carry EC2
instance identifiers and nothing needed to reproduce a measurement. The 227 raw
`perf`/profile outputs (108 MB) are omitted for size.
