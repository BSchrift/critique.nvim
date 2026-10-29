#!/bin/sh
# Runs every test file. All offline: temp git repos, no GitHub. Usage: tests/run.sh [name ...]  (e.g. tests/run.sh cli)
# A file only passes if it exits 0 *and* reaches its "N passed, 0 failed" summary (so an early exit can't hide tests).
cd "$(dirname "$0")/.." || exit 1
status=0
for name in ${@:-$(ls tests | sed -n "s/_test\.lua$//p")}; do
  printf '== %s\n' "$name"
  # A stuck test would run into CI's time limit, which keeps no log: stop it here instead, so the log shows the
  # last test that passed (the next one is stuck).
  log=$(mktemp)
  nvim --headless -l "tests/${name}_test.lua" >"$log" 2>&1 &
  pid=$!
  (sleep 300 && kill $pid) 2>/dev/null &
  watchdog=$!
  wait $pid
  code=$?
  out=$(cat "$log")
  rm -f "$log"
  pkill -P $watchdog || out=$(printf '%s\n!! %s: stopped after 5 minutes' "$out" "$name") # its sleep was over
  printf '%s\n' "$out"
  if [ $code -ne 0 ] || ! printf '%s\n' "$out" | grep -q '^[0-9]* passed, 0 failed$'; then
    printf '!! %s did not finish cleanly (exit %s)\n' "$name" "$code"
    status=1
  fi
done
exit $status
