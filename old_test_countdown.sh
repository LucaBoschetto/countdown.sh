#!/usr/bin/env bash
# Save as: test_countdown_live.sh
# Run: bash test_countdown_live.sh
set -u

PASS=0; FAIL=0

hr() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '─'; }

assert_grep() {  # file pattern label
  local f="$1" pat="$2" label="$3"
  if grep -Eq "$pat" "$f"; then
    echo "  ✅ $label"; PASS=$((PASS+1))
  else
    echo "  ❌ $label (pattern not found: $pat)"; FAIL=$((FAIL+1))
  fi
}

assert_notgrep() {  # file pattern label
  local f="$1" pat="$2" label="$3"
  if grep -Eq "$pat" "$f"; then
    echo "  ❌ $label (unexpected pattern: $pat)"; FAIL=$((FAIL+1))
  else
    echo "  ✅ $label"; PASS=$((PASS+1))
  fi
}

run() {  # secs desc cmd...
  local secs="$1"; shift
  local desc="$1"; shift
  echo
  hr
  echo "🔹 $desc"
  printf '  cmd: '; printf '%q ' "$@"; echo
  local OUT ERR RC
  OUT="$(mktemp)"; ERR="$(mktemp)"
  # Show output live (preserving ANSI colors) AND capture to files
  timeout "${secs}s" "$@" > >(tee "$OUT") 2> >(tee "$ERR" >&2)
  RC=$?
  echo "  rc: $RC"
  # export for assertions
  LAST_OUT="$OUT"; LAST_ERR="$ERR"; LAST_RC="$RC"
}

# ---- Tests ------------------------------------------------------------------

# 1) ISO-8601 PT2S
run 5 "ISO-8601: PT2S" ./countdown.sh PT2S --throttle 0.02

# 2) SS + --message + --done-cmd (stderr should show FINISHED)
run 6 "SS + message + done-cmd (stderr visible)" \
  ./countdown.sh 2 --message "BREAK" --done-cmd 'bash -lc "echo FINISHED >&2"'
assert_grep "$LAST_ERR" "FINISHED" "done-cmd stderr surfaced before exit"

# 3) MM:SS
run 5 "MM:SS" ./countdown.sh 0:02 --nosound --no-title

# 4) HH:MM:SS
run 5 "HH:MM:SS" ./countdown.sh 0:0:2 --nosound --no-title

# 5) Unit-suffixed (Xs)
run 5 "Unit-suffixed (Xs)" ./countdown.sh 2s --nosound --no-title

# 6) Combined units (1m2s)
run 5 "Combined units (1m2s)" ./countdown.sh 1m2s --nosound --no-title

# 7) ISO-8601 PT1M1S (smoke)
run 5 "ISO-8601: PT1M1S" ./countdown.sh PT1M1S --nosound --no-title

# 8) --until two hours ago (rolls to tomorrow; no spurious note)
TWO_HOURS_AGO="$(date -d 'now - 2 hours' +%H:%M:%S)"
run 4 "--until two hours ago (rolls, -y)" ./countdown.sh --until="$TWO_HOURS_AGO" -y --nosound --no-title
assert_notgrep "$LAST_ERR" "both duration" "no spurious 'both duration and --until' note"

# 9) --until full datetime (no prompt, no note)
FULL_DT="$(date -d 'now + 2 hours' +%Y-%m-%dT%H:%M:%S)"
run 5 "--until full datetime (no prompt)" ./countdown.sh --until="$FULL_DT" --nosound --no-title
assert_notgrep "$LAST_ERR" "both duration" "no 'both duration' note for full datetime"

# 10) Throttle cap warning (force a large throttle)
run 5 "Throttle cap warning" ./countdown.sh 2 --throttle 1 --nosound --no-title
assert_grep "$LAST_ERR" "Warning: --throttle=" "warns when throttle exceeds frame cap"

# 11) --clear (smoke)
run 5 "--clear smoke" ./countdown.sh 2 --clear --nosound --no-title

# 12) --left (smoke)
run 5 "--left alignment" ./countdown.sh 2 --left --nosound --no-title

# 13) >24h display (day-aware) smoke
run 4 ">24h (day-aware) smoke" ./countdown.sh 90061 --nosound --no-title

# 14) ISO-8601 hours only (smoke)
run 4 "ISO-8601 PT2H (smoke)" ./countdown.sh PT2H --nosound --no-title

# 15) Past time-of-day ~22h long roll triggers Notice in non-interactive mode (no -y)
PAST_LONG="$(date -d 'now - 2 hours' +%H:%M:%S)"
run 4 "Past time-of-day ~22h (non-interactive emits Notice)" ./countdown.sh --until="$PAST_LONG" --nosound --no-title
assert_grep "$LAST_ERR" "^Notice: Target time is in .+proceeding" "non-interactive long roll emits Notice"

hr
echo "✅ PASSED: $PASS   ❌ FAILED: $FAIL"
exit $(( FAIL > 0 ))
