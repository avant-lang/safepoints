# myc_llvm_safepoints changelog

## 0.2.0 - 2026-10-02

### Fixed

* A load of the global `g_avant_shared` is volatile. That global is an integer, so the GC-pointer rule did not cover it. A plain load was lifted out of a loop that never stored the flag. Another thread can set the flag, and a moving collection can relocate a buffer the loop still uses. The volatile load keeps the check in the loop.

## 0.1.0 - 2026-10-02

First release. Crystal shard that adds LLVM pointer safepoints to [myc](https://github.com/kostya/myc) for a moving collector. myc is not forked. Avant builds `myc-llvm` from this shard.

### Added

* Safepoints turn on when the module declares the root hook, or when `--gc-root=NAME` is passed (default name `gc_root`). A collecting call is `llvm.experimental.gc.statepoint`. Each `gc.relocate` result is stored back into its rooted alloca.
* `--gc-reload`, `--gc-enter`, `--gc-leave`, and `--gc-leaf`. `--no-gc-safepoints` keeps myc's call lowering. `printf`, `memset`, `memcpy`, `memmove`, `malloc`, `calloc`, `free`, and the hook names do not collect.
* Default and `--final` stay available. A root hook does not force `--debug` or `optnone`. FastISel is off, frame pointers stay, and `.llvm_stackmaps` is writable (`SHF_WRITE`), so a PIE has no `DT_TEXTREL`.
* Loads and stores of GC pointer slots are volatile, so a pass cannot keep a pointer SSA across a collecting call.
* Overlays use Crystal `previous_def`. A stock myc tree can `require "myc_llvm_safepoints"`.
