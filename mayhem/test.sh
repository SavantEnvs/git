#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS a curated subset of git's own t/ suite against the unsanitized binaries
# that mayhem/build.sh left in-tree. Each script asserts command output (test_cmp, test_expect_*),
# so a program that exits 0 without doing the work fails it. The subset covers the code the
# harnesses fuzz (config, attributes, date, credential URLs, reftable, commit-graph, pack index)
# plus core plumbing/porcelain. Counts come from each script's TAP output.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
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

TESTS="t0001-init t0002-gitfile t0003-attributes t0006-date t0012-help t0070-fundamental
t0090-cache-tree t0300-credentials t0610-reftable-basics t0613-reftable-write-options
t1006-cat-file t1300-config t1400-update-ref t1450-fsck t1500-rev-parse t2200-add-update
t3200-branch t3600-rm t3700-add t4013-diff-various t4015-diff-whitespace t4202-log
t5300-pack-object t5302-pack-index t5318-commit-graph t6300-for-each-ref t7001-mv t7810-grep"

# The runner is a build product: fail loudly if build.sh did not leave it.
for f in git t/helper/test-tool bin-wrappers/git; do
  [ -x "$f" ] || { echo "test.sh: $f missing — run mayhem/build.sh first" >&2; emit_ctrf git-t 0 1; exit 1; }
done

passed=0 failed=0 skipped=0 pending=0
cd t
for t in $TESTS; do
  log="$(mktemp)"
  sh "./$t.sh" >"$log" 2>&1
  rc=$?
  p=$(grep -cE '^ok [0-9]+' "$log" || true)
  s=$(grep -cE '^ok [0-9]+ .*# skip' "$log" || true)
  k=$(grep -cE '^not ok [0-9]+ .*# TODO known breakage$' "$log" || true)
  f=$(grep -cE '^not ok [0-9]+' "$log" || true)
  f=$(( f - k ))
  p=$(( p - s ))
  # A script that died without reporting a failing assertion still counts as one failure.
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi
  # A script that ran no assertions at all proves nothing.
  if [ $(( p + s + k + f )) -eq 0 ]; then f=1; fi
  echo "== $t: passed=$p failed=$f skipped=$s known-breakage=$k (exit $rc)"
  [ "$f" -gt 0 ] && grep -E '^not ok' "$log" | grep -v 'TODO known breakage$' | head -5
  passed=$(( passed + p )); failed=$(( failed + f )); skipped=$(( skipped + s )); pending=$(( pending + k ))
  rm -f "$log"
done
emit_ctrf git-t "$passed" "$failed" "$skipped" "$pending"
