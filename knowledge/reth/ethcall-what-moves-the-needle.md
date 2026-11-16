# reth `eth_call`: what moved the needle, and what didn't

All figures from the 200k light + 2k heavy `eth_call` benchmark, measured against
a **same-boot control** (the discipline matters: several apparent wins turned out
to be host drift or first-boot noise). Confirmed = disjoint run ranges, and
bracketed by a control before *and* after.

## Confirmed wins

| Change | Kind | Gain |
|---|---|--:|
| Reuse one storage dup cursor per provider | code | part of the −14…−29% stack |
| Read storage layout from the provider's `is_v2` flag, not a per-read RwLock | code | ″ |
| Hash an account address once per run of slot reads | code | ″ |
| Run `eth_call` on the rayon RPC pool, not tokio's blocking pool | code | ″ (largest single) |
| PGO (two-pass, see `pgo-on-reth.md`) | build | **−6.1%** |
| THP=always, on top of PGO | system | **−2.7%** |

The four code changes are worth −14.2% (Zen 5) to −28.9% (Graviton5); the gain
scales with how expensive the CPU's synchronization is. PGO + THP adds −8.7% on
Graviton5 on top of that.

## Does not stack on PGO

- **fat LTO + codegen-units=1** (4.47 vs 4.43): the hot cross-crate calls are
  already inlined, and cgu=1 removes parallel-codegen diversity.
- **nightly / evm2 tail-call dispatch** (4.36 vs 4.31): PGO's profile already
  lays out the opcode-dispatch loop. Nightly alone was only −1.9%.
- **`--db.disable-metrics`** (4.33 vs 4.31): looked like −2.1% in isolation, but
  that was drift — it does not reproduce on the stack.
- **THP `defrag=always`** (4.34 vs 4.31): the THP win comes from 2 MiB pages being
  *used*, not from how hard the kernel hunts for them. Freshly booted boxes are
  barely fragmented, so allocations already succeed with the default
  `defrag=madvise`. Worth re-testing on a node that has been up for days.
- **BOLT**: blocked after 4 attempts on 5 distinct toolchain walls — see
  `pgo-on-reth.md`.

## Neutral everywhere (don't re-test without a reason)

- Compiler/target: `znver5` on Zen 5 c8a, `+sha3` on Graviton4 (verified 1039
  SHA3 instructions in the binary — the flag worked, the time didn't move),
  native `CFLAGS` for the C deps, full `-Ctarget-cpu=native`.
- MDBX: 16KB page size, `--db.read-transaction-timeout=0`, relaxing the two
  transaction latches from `SeqCst` to `Acquire`/`Release`.
- Runtime: jemalloc `percpu_arena`+`background_thread`, datadir on XFS/EBS vs
  tmpfs, `--rpc.max-blocking-io-requests` (8/16/32).
- Harmful: static CPU pinning (node 0-5 / client 6-7) — +6.6% on c8i, +10% on c8g.

## Known dead ends

- The per-operation MDBX transaction mutex is ~7.4% of heavy-phase CPU, but
  `TransactionPtr` and `Cursor` are both `Sync`, so that mutex is what serialises
  concurrent calls on one transaction. It cannot be removed without breaking the
  library's contract.
- The remaining heavy-phase cost is largely intrinsic (MDBX B-tree descent,
  keccak permutation) or inside `evm2` (per-call storage map rehashing, ~9%).

## Measurement notes

- Graviton5 drifts ±3% between runs; treat smaller deltas as noise.
- A host can change speed across an idle stop/start (Graviton4 moved ~4%), so
  never compare across restarts.
- The first measurement after a box boots is inflated (~9% on one c8a boot) by
  first-boot activity; discard it or settle first.

## The `simd` rung: nothing to do (analysis, 2026-11-05)

Checked without spending, by mapping the champion profile's heavy-phase frames
onto whether they already vectorise:

| Hot frame | % | Vectorised already? |
|---|--:|---|
| `keccak_cache::compute` → keccak-asm | 19.4 | **yes** — AVX-512VL on x86, NEON (+SHA3 with the flag) on arm, chosen at build time |
| `mdbx_cursor_get` B-tree descent | 16.1 | n/a — pointer chasing |
| hashbrown `reserve_rehash` (evm2 maps) | 9.2 | **yes** — SSE2 group-of-16 / NEON group-of-8 |
| `TransactionPtr::lock` | 7.4 | n/a — atomic CAS, and the mutex can't be removed (`Sync`) |
| `memcmp` / `cmp_lexical` key compare | 7.4 | **yes** — glibc ifunc selects an AVX-512/NEON memcmp |
| evm2 interpreter dispatch | 2.7 | n/a — branchy; PGO already fixes its layout |
| `FbHasher`/foldhash | 2.4 | **yes** — 64-bit multiply (mulx/umulh) |

~38% of heavy-phase time is in code that is **already** SIMD, via dependencies
that dispatch on target features. Everything else is pointer-chasing, atomics or
branchy dispatch — none of it a vectorisation candidate. There is no hand-written
SIMD worth adding in reth for this workload; the only lever was making sure the
right backend gets *selected* (`+sha3` on Graviton, `target-cpu`), which was
tested and is neutral-to-small. Rung closed on evidence, not on a measurement.

## Harness rebuild + re-baseline (2026-11-06)

The harness now times the request phases, not the whole script. Node startup,
genesis init and teardown were a steady **1.42–1.48s inside every measurement**
(17% of an 8.6s run), so **all figures above this section understate the workload
gain by roughly a seventh** and are not comparable with anything measured after.

Re-baseline on m9g, same boot:

| | workload | wall | light | heavy | spread |
|---|--:|--:|--:|--:|--:|
| stock `main` | 5.02s | 6.50s | 1.71s | 3.34s | 3.4% (noisy) |
| champion (PGO+THP) | **3.19s** | 4.61s | 1.39s | 1.78s | 2.1% |

**Workload gain −36.5%** (the old wall-clock metric said −33.3%), and the phase
split now comes from a single run:

- **heavy −46.6%** — the three storage commits plus PGO
- **light −18.3%** — the rayon handoff plus PGO

Harness changes (engine commits `7fbafb1`, `a4dac38`, `4d17ca8`):
- `bench.sh` emits `BENCH_RESULT:` / `BENCH_PHASE:`; the engine prefers the
  workload's own time and records `fixed_overhead` so the dilution stays visible.
- A work-done gate before timing: heavy-call gas must land in 20–25M, which
  rejects a short-circuited loop. It does **not** prove the database was read —
  gas is charged per SLOAD opcode regardless of caching. (reth's estimator
  reports 22,227,399; anvil 22,051,222 — hence a band, not an equality.)
- Results carry median/IQR/spread and a `noisy` flag above 3%.

**Open:** the 3% noise threshold wants revisiting. Removing a constant 1.4s makes
the same absolute variance a larger fraction, so stock trips the flag at 3.4%
while the champion sits at 2.1%.

## Full re-baseline on the workload metric (2026-11-16, 8 instances)

Stock `main` vs the full stack (4 code commits + PGO + THP), same-boot pairs,
workload metric (node startup excluded). **These supersede every figure above.**

| Box | CPU | stock | full stack | gain | light | heavy | $/run |
|---|---|--:|--:|--:|---|---|--:|
| m8azn-3xl | EPYC 9R05, 12 vCPU | 4.10 | **2.98** | −27.3% | 1.16→1.34 | 2.93→1.64 | $0.00103 |
| c8a | EPYC 9R45 | 3.89 | **3.04** | −21.9% | 0.94→0.99 | 2.96→2.05 | **$0.00036** |
| m9g | Graviton5 | 5.02 | 3.19 | −36.5% | 1.71→1.39 | 3.34→1.78 | $0.00035 |
| c8i | Granite Rapids | 5.51 | 3.61 | −34.5% | 1.90→1.63 | 3.61→1.96 | $0.00038 |
| m8azn | EPYC 9R05, 4 vCPU | 4.84 | 3.74 | −22.7% | 1.36→1.22 | 3.49→2.53 | $0.00043 |
| i7i | Emerald Rapids | 5.90 | 4.00 | −32.2% | 2.00→1.82 | 3.88→2.19 | — |
| i8g | Graviton4 | 7.11 | **4.21** | **−40.8%** | 2.41→1.77 | 4.69→2.42 | — |
| c8g | Graviton4 | 7.11 | 4.25 | −40.2% | 2.43→1.76 | 4.68→2.48 | $0.00038 |

- **Fastest: m8azn-3xl 2.98s. Best price/performance: c8a 3.04s at $0.00036/run**
  — a third of m8azn-3xl's cost for 2% more time.
- **The heavy phase carries the win** (−30% to −48% everywhere). Light barely moves
  on fast Zen 5 and most on the slower cores.
- **x86 PGO no longer needs nightly**: the 1.99.1 LLVM `SIGILL` is gone on stable
  1.100.0. See `pgo-on-reth.md`.
- Fixed startup overhead was 1.48–1.57s on every box — uniform, so it was node
  startup, not anything CPU-dependent.

### Light-phase numbers are now client-limited on fast boxes

On c8a the light phase is ~1s for 200k calls and got slightly **worse**
(0.94→0.99s). That is close to what the co-located `oha` client can generate, so
on the fastest hardware this phase measures the load generator, not the server.
**Light-phase results on c8a/m8azn-3xl should not be trusted** until the client
moves to its own instance.
