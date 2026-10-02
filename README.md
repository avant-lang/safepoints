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
| `--gc-reload=NAME` / `MYC_GC_RELOAD` | Opaque post-CALL pointer reload (default `gc_reload`) |
| `--gc-enter=NAME` / `MYC_GC_ENTER` | Optional enter hook (root the return slot after it) |
| `--gc-leave=NAME` / `MYC_GC_LEAVE` | Optional leave hook (keep rooted allocas live) |
| `--gc-leaf=A,B` / `MYC_GC_LEAF` | Extra CALLs that never collect (libc is already leaf) |
| `--no-gc-safepoints` / `MYC_GC_SAFEPOINTS=0` | Force the old CALL lowering even if the root hook is declared |

**Non-collecting CALL:** `printf`, `memset`, `memcpy`, `memmove`, `malloc`, `calloc`, `free`, the hook names, and `--gc-leaf`. Everything else collects.

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

## What this is not

- Not a myc fork. myc stays unmodified.
- Not QBE/C safepoints.
- After each `gc.statepoint`, `gc.relocate` results are stored back into the rooted allocas (volatile) so default / `--final` passes cannot keep a pre-CALL pointer SSA. Avant’s copying nursery is the proof case; `--debug` remains the emergency belt.
