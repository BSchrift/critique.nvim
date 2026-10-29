#!/bin/sh
# Runs every test file. All offline: temp git repos, no GitHub. Usage: tests/run.sh [name ...]  (e.g. tests/run.sh cli)
# A file only passes if it exits 0 *and* reaches its "N passed, 0 failed" summary (so an early exit can't hide tests).
cd "$(dirname "$0")/.." || exit 1
status=0
for name in ${@:-$(ls tests | sed -n "s/_test\.lua$//p")}; do
  printf '== %s\n' "$name"
  out=$(nvim --headless -l "tests/${name}_test.lua" 2>&1)
  code=$?
  printf '%s\n' "$out"
  if [ $code -ne 0 ] || ! printf '%s\n' "$out" | grep -q '^[0-9]* passed, 0 failed$'; then
    printf '!! %s did not finish cleanly (exit %s)\n' "$name" "$code"
    status=1
  fi
done
exit $status
