#!/bin/sh
# Build the release myc-llvm with LLVM and the other C/C++ libraries linked
# statically (Avant D146), so the binary loads only glibc's libraries and
# libgcc_s. The release workflow runs this script; run it locally the same way.
#
#   sh release-build.sh [OUT]      (default OUT: ./myc-llvm)
#
# Needs Crystal, `llvm-config-20` (or LLVM_CONFIG) with the static LLVM
# component archives (Ubuntu: llvm-20-dev), and the static libstdc++,
# pcre2-8, zlib, and zstd archives (Ubuntu: libstdc++-dev, libpcre2-dev,
# zlib1g-dev, libzstd-dev).
set -eu
out=${1:-myc-llvm}
LLVM_CONFIG=${LLVM_CONFIG:-llvm-config-20}
export LLVM_CONFIG

# Every LLVM component archive. Static linking takes only the members the
# program references, so the list costs nothing; Polly is not installed as
# a static archive and is never referenced. Crystal adds -lstdc++ and
# -lpcre2-8 after these flags; the static copies named here resolve first,
# and --as-needed drops the dynamic ones.
llvm_libs=$("$LLVM_CONFIG" --link-static --libs | tr ' ' '\n' | grep -v -i polly | tr '\n' ' ')
LLVM_LDFLAGS="-L$("$LLVM_CONFIG" --libdir) $llvm_libs -Wl,-Bstatic -lstdc++ -lpcre2-8 -lz -lzstd -Wl,-Bdynamic -lrt -ldl -lm"
export LLVM_LDFLAGS

crystal build src/cli.cr --release -o "$out"

# Refuse a binary that loads anything beyond glibc's libraries and libgcc_s.
extra=$(ldd "$out" | awk '{print $1}' | grep -v -E '^(linux-vdso\.so\.1|libc\.so\.6|libm\.so\.6|libgcc_s\.so\.1|/lib64/ld-linux-x86-64\.so\.2)$' || true)
if [ -n "$extra" ]; then
  echo "release-build: $out loads libraries beyond glibc and libgcc_s:" >&2
  echo "$extra" >&2
  exit 1
fi
case "$out" in
  */*) "$out" version ;;
  *) "./$out" version ;;
esac
