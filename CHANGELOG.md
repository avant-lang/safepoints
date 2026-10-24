# myc_llvm_safepoints changelog

## 0.4.0 - 2026-10-24

### Changed

* A `--gc-leaf` function no longer gets safepoint lowering. Calls inside it do not plant `avant_gc_root`, a statepoint, a reload, or a register clobber. The function does not collect, and its callees do not, so those roots were recording pointers that cannot move. A function that is not a leaf still roots every pointer result, including the result of a leaf callee.
* A `--gc-leaf` function whose body is in this module fails the build if it calls a non-leaf. The non-allocating string and buffer helpers may be called from a leaf frame. They are not leaves for any other caller, so a non-leaf still statepoints them.
* An indirect call of a known `--gc-leaf` function is not a statepoint. An unknown function pointer still is.
* A spill slot that is not also a local, a parameter, or a live stack value is left out of that statepoint's `gc-live` bundle.
* A `--gc-leaf` callee is marked `nounwind` and `willreturn`. `nosync` is added as well, except on libc leaves and on names that take a lock or allocate.

### Added

* `.github/workflows/release.yml` builds `myc-llvm` (`crystal build --release`) on a `v*` tag and attaches `myc-llvm-linux-x86_64.tar.gz` to a draft GitHub Release. `crystal spec` runs before the release exists.

## 0.3.0 - 2026-10-17

### Changed

* Updated `myc` to tag `v0.11.0` and version string of `v0.12.0-dev`. All tests passing.

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
