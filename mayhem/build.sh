#!/usr/bin/env bash
#
# mayhem/build.sh — builds git's libFuzzer harnesses (oss-fuzz/fuzz-*.c) sanitized, their
# -standalone reproducers, and then the normal (unsanitized) git binaries + test helpers that
# mayhem/test.sh runs t/ scripts against. Re-runnable and offline: it only uses the apt packages
# already in the base image and the tree.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

OUT_DIR="$SRC/mayhem/out"   # gitignored (mayhem/.gitignore)
mkdir -p "$OUT_DIR"
HARNESSES="commit-graph config credential-from-url-gently date pack-headers pack-idx parse-attr-line reftable url-decode-mem"

# No optional external deps: keeps the build hermetic (nothing to fetch, nothing machine-specific).
GIT_OPTS=(NO_CURL=1 NO_EXPAT=1 NO_TCLTK=1 NO_GETTEXT=1 NO_PYTHON=1 NO_PERL=1 NO_OPENSSL=1 NO_RUST=1)

mk() { make -j"$MAYHEM_JOBS" "${GIT_OPTS[@]}" "$@"; }

# Two harnesses are built from corrected copies in mayhem/harnesses/ (see the comment at the top of
# each); the other seven are upstream's, unmodified:
#   commit-graph  upstream's BUG()s on every input that gets past header parsing.
#   date          upstream's lets show_date() die() on out-of-range timestamps (not a defect).
# Overriding FUZZ_OBJS makes the Makefile's own fuzz rules (same flags, same link line) build them
# as mayhem/harnesses/fuzz-<name>.
PATCHED="commit-graph date"
is_patched() { case " $PATCHED " in *" $1 "*) return 0;; esac; return 1; }
FUZZ_OBJS_ARG="oss-fuzz/dummy-cmd-main.o"
for h in $HARNESSES; do
  if is_patched "$h"; then FUZZ_OBJS_ARG="$FUZZ_OBJS_ARG mayhem/harnesses/fuzz-$h.o"
  else FUZZ_OBJS_ARG="$FUZZ_OBJS_ARG oss-fuzz/fuzz-$h.o"; fi
done
harness_bin() { if is_patched "$1"; then echo "mayhem/harnesses/fuzz-$1"; else echo "oss-fuzz/fuzz-$1"; fi; }

# Start from a clean in-tree state so a re-run (or a rebuild after a source edit) never mixes
# sanitized and normal objects.
mk clean >/dev/null 2>&1 || true
rm_harness_bins() { for h in $HARNESSES; do rm -f "$(harness_bin "$h")"; done; }
rm_harness_bins
rm -f "$SRC"/mayhem/harnesses/*.o

# lsan_off.o is linked into every fuzz and standalone binary.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o "$SRC/mayhem/lsan_off.o"
# Run-once driver compiled as C (the harnesses are C, but keep the driver an object of its own).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/mayhem/standalone_main.o"

# 1) Sanitized libFuzzer binaries. -fsanitize=fuzzer-no-link puts SanCov instrumentation into the
#    whole project (libgit.a etc.), not just the harness TU, so Mayhem sees coverage.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"
mk CC="$CC" FUZZ_CXX="$CC" CFLAGS="$FUZZ_CFLAGS" \
   FUZZ_OBJS="$FUZZ_OBJS_ARG" LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $SRC/mayhem/lsan_off.o" fuzz-all
for h in $HARNESSES; do cp "$(harness_bin "$h")" "$OUT_DIR/fuzz-$h"; done

# 2) Standalone reproducers: same objects, relinked against the run-once driver. The driver's main()
#    must come before common-main.o (whose main() calls the dummy cmd_main), so it rides in LDFLAGS,
#    which the Makefile puts ahead of the object files.
rm_harness_bins
mk CC="$CC" FUZZ_CXX="$CC" CFLAGS="$FUZZ_CFLAGS" \
   FUZZ_OBJS="$FUZZ_OBJS_ARG" LIB_FUZZING_ENGINE= \
   LDFLAGS="$SRC/mayhem/standalone_main.o $SRC/mayhem/lsan_off.o" fuzz-all
for h in $HARNESSES; do cp "$(harness_bin "$h")" "$OUT_DIR/fuzz-$h-standalone"; done

# 3) The test build: the project's NORMAL flags, left in-tree where t/ expects it.
mk clean >/dev/null
rm_harness_bins
rm -f "$SRC"/mayhem/*.o "$SRC"/mayhem/harnesses/*.o
mk LINK_FUZZ_PROGRAMS= CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" all
