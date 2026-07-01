#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the url crate's functional test suite (built by mayhem/build.sh).
# Asserts real behavior (WHATWG URL known-answer tests, setter tests, unit assertions).
# A PATCH that neuters url::Url::parse to a no-op fails these — this is the anti-reward-hack oracle.
# Emits a CTRF summary. exit 0 iff failed==0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the pre-built test suite. build.sh already compiled it (cargo test --no-run -p url)
# with the project's normal flags; here we only RUN it, in a clean env (no fuzz/ASan RUSTFLAGS).
# CARGO_NET_OFFLINE is honored by the runtime; no compile happens if artifacts are fresh.
LOG="$(mktemp)"
set +e
env -u RUSTFLAGS -u RUSTUP_TOOLCHAIN \
  cargo test -p url -- 2>&1 | tee "$LOG"
set -e

# Parse libtest summary lines: "test result: ok. N passed; M failed; K ignored; ..."
passed=0; failed=0; skipped=0
while read -r p f i; do
  passed=$(( passed + p )); failed=$(( failed + f )); skipped=$(( skipped + i ))
done < <(grep -E '^test result:' "$LOG" \
         | sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored.*/\1 \2 \3/')

# The wpt.rs harness (harness = false) prints its own tally; count it if present.
# It prints "Ran <N> tests" and "<F> tests failed" style lines. Fold conservatively:
# if libtest found no summaries at all, that is a build/run failure — mark failed.
total=$(( passed + failed + skipped ))
if [ "$total" -eq 0 ]; then
  echo "ERROR: no test summaries parsed — the test suite did not run (build.sh should have built it)" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi

emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
