#!/usr/bin/env bash
#
# mayhem/build.sh — build rust-url's cargo-fuzz targets as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), and build the
# workspace test suite (clean, non-sanitized) for mayhem/test.sh to RUN.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# The first (online) build populates the cargo registry under $CARGO_HOME; the
# rlenv runtime sets CARGO_NET_OFFLINE=true for the re-run. Do NOT hard-code
# --offline here (it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# --- Sanitizer contract (SPEC §6.1) ------------------------------------------
# For Rust the fuzzed code is instrumented via RUSTFLAGS (rustc ignores the clang
# $CFLAGS/$SANITIZER_FLAGS). We still HONOR $SANITIZER_FLAGS: cargo-fuzz builds ASan
# by default; if the image's $SANITIZER_FLAGS opts out ("empty" build), skip ASan.
# ASan halts on first error (libFuzzer aborts) — matching -fno-sanitize-recover.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all}"
RUST_SAN="-Zsanitizer=address"
if [ -z "${SANITIZER_FLAGS}" ]; then
  echo "SANITIZER_FLAGS empty — building WITHOUT sanitizers"
  RUST_SAN=""
fi

# --- Debug-info contract (SPEC §6.2 item 10): DWARF < 4 -----------------------
# Mayhem's triage can't read DWARF >= 4; rustc defaults to DWARF-5. Thread
# $RUST_DEBUG_FLAGS (default -Cdebuginfo=1 -Zdwarf-version=3) through RUSTFLAGS so
# OUR code carries DWARF-3. The precompiled std/ASan runtime archives ship DWARF-5;
# strip their debug info below so the target binary's own debug info is DWARF < 4.
: "${RUST_DEBUG_FLAGS=-Cdebuginfo=1 -Zdwarf-version=3}"

SYSROOT="$(rustc --print sysroot)"
LIBDIR="$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib"
echo "=== stripping DWARF-5 debug info from precompiled std/runtime archives ==="
for a in "$LIBDIR"/librustc-*_rt.asan.a \
         "$LIBDIR"/lib{std,core,alloc,panic_unwind,panic_abort,compiler_builtins,test,proc_macro,unwind}-*.rlib; do
  [ -e "$a" ] || continue
  objcopy --strip-debug "$a" 2>/dev/null || echo "warn: could not strip $a"
done

export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SAN} -Cforce-frame-pointers ${RUST_DEBUG_FLAGS}"

# Upstream ships a working cargo-fuzz crate at url/fuzz that builds on the pinned
# nightly — use it as-is (do NOT add an additive crate).
FUZZ_DIR="url/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Clean the fuzz target tree so every crate is recompiled with our DWARF-3 flags
# (a cached artifact would keep DWARF-5); harmless & fast on the offline re-run.
rm -rf "$FUZZ_DIR/target"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the workspace TEST suite with the project's NORMAL flags (a clean,
# non-sanitized build) so mayhem/test.sh only RUNS it. RUSTFLAGS above carry
# fuzz/ASan flags, so run the test build in a clean env.
echo "=== building test suite (cargo test --no-run, url crate) ==="
env -u RUSTFLAGS -u RUSTUP_TOOLCHAIN \
  cargo test --no-run -p url 2>&1 | tail -20

echo "build.sh complete"
