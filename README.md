# myc_llvm_safepoints

Crystal shard: optional LLVM pointer safepoints for a **moving** garbage collector on top of [kostya/myc](https://github.com/kostya/myc)’s `myc-llvm`. Conservative / non-moving collectors do not need this.

It delivers a shard with open classes, required from `src/cli/llvm.cr`.

## Optimization levels

Safepoints and LLVM optimization levels are independent. Declaring a root hook (or passing `--gc-root`) does **not** force `--debug`, does **not** add `optnone`, and does **not** replace myc’s pass pipeline. Daily compiles use myc-llvm **default**. Release compiles use **`--final`**. Both emit `gc.statepoint` when safepoints are on.

| Flag | IR passes | Codegen | myc inliner | extra LLVM `noinline` |
| --- | --- | --- | --- | --- |
| **default** | `mem2reg,sccp,dce,simplifycfg` | `Default` | on | yes |
| **`--final`** | `default<O3>` (or `lto-pre-link<O3>` with `--llvm-bitcode-obj`) | `Aggressive` | on | no |
| **`--debug`** | `default<O0>` | `None` | off | yes |

`--debug` is the emergency / unoptimized path, not a safepoint requirement. This shard’s `--debug` uses `CodeGenOptLevel::None`; stock myc-llvm `--debug` still uses `Default` codegen. That difference exists only for `--debug`.

Safepoints add these LLVM constraints under **every** flag, including default and `--final`. They are not “no optimizations”:

- FastISel off (it SIGSEGVs on `gc.statepoint`)
- `gc "statepoint-example"` and `frame-pointer=all`
- writable `.llvm_stackmaps` (`SHF_WRITE`) so a PIE has no `DT_TEXTREL`

`MYC_LLVM_PASSES` still overrides the pass pipeline, as in myc.

## Consume

**Library** - in a stock myc tree:

```yaml
# myc/shard.yml
dependencies:
  myc_llvm_safepoints:
    github: avant-lang/safepoints
```

```crystal
# myc/src/cli/llvm.cr - after require "../backend/llvm/all"
require "myc_llvm_safepoints"
```

`require "myc_llvm_safepoints"` loads myc’s LLVM backend and then reopens those classes. It does not vendor myc. Overrides use Crystal `previous_def` and extra instance variables so myc can change its methods without this shard copying them (kostya/myc#10).

Then `crystal build src/cli/llvm.cr -o myc-llvm` as usual.

**Binary (this repo)** - does not edit myc:

```
shards install
crystal build src/cli.cr -o myc-llvm
```

Needs Crystal ≥ 1.19 and LLVM ≥ 15 (`llvm-config` on `PATH`, or `LLVM_CONFIG`).

## How it turns on

Off unless the module (or header) declares the root hook (`FUNC :gc_root` by default, or `--gc-root=NAME`).

```
./myc-llvm c prog.myc out --gc-root=gc_root --gc-reload=gc_reload --gc-enter=gc_enter --gc-leave=gc_leave
```

`--key=value` is enough; myc’s CLI already stores unknown flags. `--gc-root NAME` (space form) is not registered in stock myc; use `=`.

| Flag / env | Role |
| --- | --- |
| `--gc-root=NAME` / `MYC_GC_ROOT` | Root hook (default `gc_root`). Presence enables safepoints. |
| *(no flag)* `GcConfig#begin` | Batch registration entry (default `gc_root_begin`). Named in shard config, not on the command line; see Batched root registration below. |
| `--gc-reload=NAME` / `MYC_GC_RELOAD` | Opaque post-CALL pointer reload (default `gc_reload`) |
| `--gc-enter=NAME` / `MYC_GC_ENTER` | Optional enter hook (root the return slot after it) |
| `--gc-leave=NAME` / `MYC_GC_LEAVE` | Optional leave hook (keep rooted allocas live) |
| `--gc-leaf=A,B` / `MYC_GC_LEAF` | Extra CALLs that never collect (libc is already leaf) |
| `--no-gc-safepoints` / `MYC_GC_SAFEPOINTS=0` | Force the old CALL lowering even if the root hook is declared |

**Non-collecting CALL:** `printf`, `memset`, `memcpy`, `memmove`, `malloc`, `calloc`, `free`, the hook names, and `--gc-leaf`. Everything else collects.

## Generated-code fast paths

Safepoints alone leave three per-operation calls in generated code: one root registration call per pointer local, one reload call per live slot after a collecting call, and one runtime call per allocation and per pointer store. On allocation-heavy programs those calls, not the collector, dominated the profile (on Avant's binary-trees workload, `avant_gc_root` alone was about a third of all cycles). The passes below remove the common case of each call while keeping the runtime call as the exact fallback. Each pass is independent, each has an environment switch that restores the call for A/B measurement, and none changes when safepoints turn on or what a statepoint means.

### Batched root registration

Codegen already knows every pointer local a frame will root, so registration does not need a call per slot. Registration is deferred to function finish, where the shard emits one batch-entry call at frame entry and then a plain store of each slot address at its fixed index in the array that call returns.

- The batch entry is named by `GcConfig#begin` (default `gc_root_begin`; Avant's runtime symbol is `avant_gc_root_begin`). It takes the root count and returns the frame's slot array, which the runtime sizes from that count.
- The batch call lands immediately after the frame-enter call (`avant_gc_enter` in Avant), before any collecting call in the entry block, and is emitted on a dedicated LLVM builder positioned after the entry block's first instruction. Emitting it on the block's own builder moves the position `Func#finish` later uses to append the return jump and corrupts the terminator of functions without an explicit return.
- A module that does not declare the batch entry keeps the per-slot root calls, emitted at the same entry position. Nothing else about the program changes.
- `MYC_GC_ROOT_BATCH=0` restores the per-slot calls even when the batch entry is declared.

### Inline reload

After a collecting call, only the slots the statepoint liveness still names can be read again, and only those are reloaded. The reload is an inline volatile load and store of the slot, with no call.

- `MYC_GC_INLINE_RELOAD=0` restores the reload call per slot.

### Inline allocation

A nursery allocation whose fast-path conditions the runtime has published becomes a bump of a shared cursor in generated code: check the published flag and the single-thread flag, check the cursor plus the aligned total against the published limit, then store the header, zero the payload, set the block's start bit, and add the total to the allocation counters. Anything else falls through to the ordinary statepoint-wrapped allocation call, which is also where every condition the inline form declines is decided.

The inline form declines, and takes the call, when any of these holds: the return type needs a blit, the total is over the large-object limit (8192 bytes in Avant), or the allocation is a scalar byte buffer at or over the runtime's scalar large-object threshold (6144 bytes in Avant, which the runtime keeps at a stable address instead of copying).

#### The runtime contract

Inline allocation is an ABI between this shard and the consumer's runtime, not a shard-local trick. The runtime publishes the fast-path state, and only the runtime publishes or clears it:

| Symbol | Kind | Meaning |
| --- | --- | --- |
| `avant_gc_fast_ok` | thread-local `uint32_t` | 1 only while every runtime fast-path condition holds on a fresh nursery block |
| `avant_gc_bump` | thread-local pointer | the shared nursery cursor; generated code and the C allocator bump the same storage |
| `avant_gc_limit` | thread-local pointer | the block limit, capped by the young threshold |
| `avant_gc_base` | thread-local pointer | the current block's base, for the start-bit offset |
| `avant_gc_starts` | thread-local `uint64_t*` | the current block's object-start words |
| `avant_gc_block` | thread-local pointer | the current block; generated code also stores the new cursor into its bump field so the block and the C cursor never disagree |
| `g_avant_shared` | `int32_t` | nonzero once a second thread has registered; the inline form requires it to be 0 |
| `avant_g_stats` | stats struct | generated code adds the total to `allocated_bytes` (offset 24; the struct's field order is part of the ABI) |
| `avant_since_gc`, `avant_nursery_held`, `avant_inline_allocs` | `uint64_t` | the counters the C allocation path would have updated |

Two invariants keep the inline arithmetic identical to the runtime's: the total size is aligned exactly the way the C allocator aligns it (8-byte alignment in Avant; an earlier 16-byte rounding under-allocated every 16-byte-multiple payload by 8 bytes), and the header word the inline form writes is the runtime's header layout (size, type id, and the `HEAP|YOUNG` flags at their documented offsets). A runtime that cannot publish this state, or that clears it on collection, defer, and mature-allocation transitions as Avant's does, simply never sets the flag, and every allocation takes the call.

- `MYC_GC_INLINE_ALLOC=0` restores the allocation call.

### Inline write barrier

A pointer store into a heap object that is young or already remembered cannot create a new mature-to-young edge the collector does not already know about, so the barrier's common case is a flag test on the target's header: null goes straight through, a heap target with the young or remembered flag set skips the call, and everything else (a mature, unremembered target, or a non-heap value) takes the ordinary barrier call, which decides remembered-set membership.

- `MYC_GC_INLINE_BARRIER=0` restores the barrier call for every store.

### Switches at a glance

| Env | Restores |
| --- | --- |
| `MYC_GC_ROOT_BATCH=0` | per-slot root registration calls |
| `MYC_GC_INLINE_RELOAD=0` | the reload call after collecting calls |
| `MYC_GC_INLINE_ALLOC=0` | the allocation call |
| `MYC_GC_INLINE_BARRIER=0` | the barrier call on every pointer store |

The switches are read when `myc-llvm` runs, not when the consumer's program runs. They exist so a regression can be bisected to one pass by recompiling, the same role the runtime's own `AVANT_GC_*` switches play on the other side of the ABI.

### Measured effect

Measured on Avant against the shard and runtime before these passes: binary trees at depth 16 went from 1.92s to 1.35s with batched registration and inline reload, and to 1.19s with inline allocation and the inline barrier, with identical collector statistics and checksums; `Binarytrees::Obj` went from 0.93s to 0.65s; a JSON churn workload that allocates its document pool in mature space took no inline allocations and was neutral, as expected. These numbers are Avant's, reached through this shard; a different consumer should expect the same shape (call volume removed) at its own scale, not the same seconds.

### What the fast paths do not change

- Safepoints still turn on exactly as described above; with no root hook declared, none of these passes emits anything.
- Every fast path falls back to the same runtime call it replaces, statepoint-wrapped where the call was. A collecting call is never made non-collecting by inlining the operations around it.
- The passes are specific to the hooks and runtime symbols named here (`avant_alloc`, `avant_bump_alloc`, `avant_barrier`, and the published cursor state). A consumer whose runtime uses different names gets the statepoint behavior and none of the inlining, which is the correct degradation: the fast paths are an optimization a runtime opts into by publishing the contract, not a requirement this shard imposes.

IR `ATTRIBUTES ATTR :leaf` is **not** part of this shard (it would need a myc core enum member). Use `--gc-leaf`.

QBE and C backends are not loaded by this CLI; they stay stock myc.

## Tests

```
crystal spec
```

GitHub Actions (`.github/workflows/spec.yml`) runs that plus `crystal build src/cli.cr -o myc-llvm` on push and PR (Ubuntu 24.04, Crystal 1.21, LLVM 20).

- `gc.statepoint` when `gc_root` is declared, and not without it
- `--gc-root` and `--no-gc-safepoints`
- `--gc-leaf` skips the statepoint
- object files have writable `.llvm_stackmaps`
- **opt levels:** default and `--final` are not forced to `optnone` / `default<O0>` when `gc_root` is present; `--debug` may be O0; `--no-gc-safepoints --final` matches stock `--final`

The fast paths above are verified on the consumer side, where the runtime contract lives: Avant's native suite (38/38 on both self-hosted compilers) and its GC behavior fixture exercise batched registration, inline reload, and inline allocation under small and default nursery sizes, and a GC probe dump (`myc-llvm dump --gc-root=...` on a pointer-carrying program) must still show `gc.statepoint` lines after any shard change. A shard change that only passes `crystal spec` here has not yet proven the generated code still roots, reloads, and allocates correctly against a real runtime.

## What this is not

- Not a myc fork. myc stays unmodified.
- Not QBE/C safepoints.
- After each `gc.statepoint`, `gc.relocate` results are stored back into the rooted allocas (volatile) so default / `--final` passes cannot keep a pre-CALL pointer SSA. Avant’s copying nursery is the proof case; `--debug` remains the emergency belt.
