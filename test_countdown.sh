#!/usr/bin/env bash
# Comprehensive test suite for countdown.sh.
# - Runs automated checks where outcomes can be validated programmatically.
# - Offers interactive checks for visual/sensory behaviours.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SCRIPT="./countdown.sh"
if [[ ! -f "$SCRIPT" ]]; then
  echo "Cannot find countdown.sh next to this test harness." >&2
  exit 1
fi

show_help() {
  cat <<'EOF'
Usage: test_countdown.sh [OPTIONS]

Options:
  --manual-only    Run only the manual (interactive) checks.
  --show-output    Stream automated test output to the terminal.
  --manual-font FONT
                   Override the font used in manual checks (default: script default).
  --manual-duration SECONDS
                   Countdown length for manual checks (default: 3).
  -h, --help       Show this help message and exit.
EOF
}

MANUAL_ONLY=false
SHOW_OUTPUT=false
MANUAL_FONT=""
MANUAL_DURATION=3
ORIGINAL_LC_ALL="${LC_ALL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manual-only) MANUAL_ONLY=true ;;
    --show-output) SHOW_OUTPUT=true ;;
    --manual-font)
      MANUAL_FONT="${2:-}"
      if [[ -z "$MANUAL_FONT" || "$MANUAL_FONT" == -* ]]; then
        echo "Error: --manual-font requires a value." >&2
        exit 2
      fi
      shift
      ;;
    --manual-font=*)
      MANUAL_FONT="${1#*=}"
      ;;
    --manual-duration)
      MANUAL_DURATION="${2:-}"
      if [[ -z "$MANUAL_DURATION" || "$MANUAL_DURATION" == -* ]]; then
        echo "Error: --manual-duration requires a value." >&2
        exit 2
      fi
      shift
      ;;
    --manual-duration=*)
      MANUAL_DURATION="${1#*=}"
      ;;
    -h|--help) show_help; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      show_help >&2
      exit 2
      ;;
  esac
  shift
done

export LC_ALL=C
: "${TERM:=xterm-256color}"
export TERM
ORIGINAL_PATH="$PATH"
AVAILABLE_LOCALES="$(locale -a 2>/dev/null || true)"

choose_manual_locale() {
  local candidate
  if [[ -n "$ORIGINAL_LC_ALL" && "$ORIGINAL_LC_ALL" != "C" ]]; then
    echo "$ORIGINAL_LC_ALL"
    return
  fi
  for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if [[ -n "$AVAILABLE_LOCALES" ]] && grep -Fxq "$candidate" <<<"$AVAILABLE_LOCALES"; then
      echo "$candidate"
      return
    fi
  done
  echo "${ORIGINAL_LC_ALL:-C}"
}
MANUAL_LOCALE="$(choose_manual_locale)"

# Resolve timeout binary (GNU coreutils uses timeout, macOS coreutils uses gtimeout)
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="$(command -v gtimeout)"
else
  echo "Missing dependency: timeout (or gtimeout). Install coreutils." >&2
  exit 1
fi

TIMEOUT_CMD=("$TIMEOUT_BIN")
if "$TIMEOUT_BIN" --help 2>&1 | grep -q -- '--foreground'; then
  TIMEOUT_CMD+=("--foreground")
fi

REQUIRED_CMDS=(bash awk date sed grep toilet lolcat tee "$TIMEOUT_BIN")
MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done
if ((${#MISSING[@]})); then
  printf 'Missing required commands for tests: %s\n' "${MISSING[*]}" >&2
  printf 'Install the missing dependencies before running this test suite.\n' >&2
  exit 1
fi

if ! toilet -f smblock TEST >/dev/null 2>&1; then
  echo "Required toilet font 'smblock' is not available. Install toilet-fonts or choose another default font." >&2
  exit 1
fi
if [[ -n "$MANUAL_FONT" ]] && ! toilet -f "$MANUAL_FONT" TEST >/dev/null 2>&1; then
  echo "Requested manual font '$MANUAL_FONT' is not available." >&2
  exit 1
fi
if ! [[ "$MANUAL_DURATION" =~ ^[0-9]+$ ]] || (( MANUAL_DURATION <= 0 )); then
  echo "Manual duration must be a positive integer (seconds)." >&2
  exit 2
fi

MANUAL_FONT_ARG=""
if [[ -n "$MANUAL_FONT" ]]; then
  MANUAL_FONT_ARG=" --font $(printf '%q' "$MANUAL_FONT")"
fi

STUB_DIR="$(mktemp -d)"
cat >"$STUB_DIR/lolcat" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${LOLCAT_LOG_FILE:-} ]]; then
  echo "lolcat invoked" >>"$LOLCAT_LOG_FILE"
fi
exec cat "$@"
EOF
chmod +x "$STUB_DIR/lolcat"
STUB_PATH="$STUB_DIR:$ORIGINAL_PATH"

declare -i AUTO_PASS=0 AUTO_FAIL=0
declare -i MANUAL_PASS=0 MANUAL_FAIL=0 MANUAL_SKIP=0
INTERRUPTED=0

TMP_PATHS=("$STUB_DIR")
cleanup() {
  for p in "${TMP_PATHS[@]}"; do
    [[ -e "$p" ]] && rm -rf "$p"
  done
}
trap cleanup EXIT

handle_interrupt() {
  local sig="${1:-INT}"
  if (( INTERRUPTED == 0 )); then
    INTERRUPTED=1
    echo >&2
    echo "Interrupted by user ($sig)." >&2
  fi
  exit 130
}
trap 'handle_interrupt INT' INT
trap 'handle_interrupt TERM' TERM

strip_ansi_file() {
  sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g; s/\x1B]0;[^\\x07]*\x07//g' "$1"
}

LAST_CMD=()
LAST_EXIT=0
LAST_STDOUT_FILE=""
LAST_STDERR_FILE=""
LAST_STDOUT=""
LAST_STDERR=""
LAST_STDOUT_STRIPPED=""
LAST_STDERR_STRIPPED=""

run_case() {
  local timeout_secs="$1"
  shift
  LAST_CMD=("$@")

  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  TMP_PATHS+=("$out" "$err")

  if $SHOW_OUTPUT; then
    if "${TIMEOUT_CMD[@]}" "$timeout_secs" env PATH="$STUB_PATH" "${LAST_CMD[@]}" \
      > >(tee "$out") 2> >(tee "$err" >&2) < /dev/null; then
      LAST_EXIT=0
    else
      LAST_EXIT=$?
    fi
  else
    if "${TIMEOUT_CMD[@]}" "$timeout_secs" env PATH="$STUB_PATH" "${LAST_CMD[@]}" >"$out" 2>"$err" < /dev/null; then
      LAST_EXIT=0
    else
      LAST_EXIT=$?
    fi
  fi

  LAST_STDOUT_FILE="$out"
  LAST_STDERR_FILE="$err"
  LAST_STDOUT="$(cat "$out")"
  LAST_STDERR="$(cat "$err")"
  LAST_STDOUT_STRIPPED="$(strip_ansi_file "$out")"
  LAST_STDERR_STRIPPED="$(strip_ansi_file "$err")"
}

print_last_cmd() {
  printf '  💻 Command:'
  for tok in "${LAST_CMD[@]}"; do
    printf ' %q' "$tok"
  done
  printf '\n'
}

print_last_cmd_stdout() {
  if ((${#LAST_CMD[@]} == 0)); then
    return
  fi
  printf '  💻 Command:'
  for tok in "${LAST_CMD[@]}"; do
    printf ' %q' "$tok"
  done
  printf '\n'
}

drain_tty() {
  local dummy
  while IFS= read -r -t 0 -n 1 dummy < /dev/tty; do
    IFS= read -r dummy < /dev/tty || break
  done
}

assert_exit_in() {
  local expected rc
  rc="$LAST_EXIT"
  for expected in "$@"; do
    if [[ "$rc" -eq "$expected" ]]; then
      return 0
    fi
  done
  echo "    Expected exit in { $* }, got $rc" >&2
  print_last_cmd >&2
  echo "    stderr (stripped):" >&2
  echo "$LAST_STDERR_STRIPPED" >&2
  return 1
}

assert_stdout_contains() {
  local needle="$1"
  if [[ "$LAST_STDOUT_STRIPPED" == *"$needle"* ]]; then
    return 0
  fi
  echo "    Expected stdout to contain: $needle" >&2
  print_last_cmd >&2
  echo "    stdout (stripped):" >&2
  echo "$LAST_STDOUT_STRIPPED" >&2
  return 1
}

assert_stderr_contains() {
  local needle="$1"
  if [[ "$LAST_STDERR_STRIPPED" == *"$needle"* ]]; then
    return 0
  fi
  echo "    Expected stderr to contain: $needle" >&2
  print_last_cmd >&2
  echo "    stderr (stripped):" >&2
  echo "$LAST_STDERR_STRIPPED" >&2
  return 1
}

assert_stderr_not_contains() {
  local needle="$1"
  if [[ "$LAST_STDERR_STRIPPED" == *"$needle"* ]]; then
    echo "    Unexpected stderr content: $needle" >&2
    print_last_cmd >&2
    echo "    stderr (stripped):" >&2
    echo "$LAST_STDERR_STRIPPED" >&2
    return 1
  fi
  return 0
}

assert_file_contains() {
  local file="$1" needle="$2"
  if [[ ! -f "$file" ]]; then
    echo "    Expected file to exist: $file" >&2
    return 1
  fi
  if ! grep -Fq -- "$needle" "$file"; then
    echo "    Expected $file to contain: $needle" >&2
    echo "    Actual content:" >&2
    cat "$file" >&2
    return 1
  fi
  return 0
}

assert_file_empty() {
  local file="$1"
  if [[ -s "$file" ]]; then
    echo "    Expected $file to be empty" >&2
    echo "    Actual content:" >&2
    cat "$file" >&2
    return 1
  fi
  return 0
}

auto_test() {
  local name="$1"
  shift
  printf '▶ %s\n' "$name"
  LAST_CMD=()
  if "$@"; then
    print_last_cmd_stdout
    printf '  ✅ %s\n' "$name"
    AUTO_PASS+=1
    return 0
  else
    print_last_cmd_stdout
    printf '  ❌ %s\n' "$name"
    AUTO_FAIL+=1
    return 1
  fi
}

test_help_flag() {
  run_case 5 "$SCRIPT" --help
  assert_exit_in 0 || return 1
  assert_stdout_contains "Usage: countdown.sh [DURATION] [OPTIONS]" || return 1
}

test_no_args_usage() {
  run_case 5 "$SCRIPT"
  assert_exit_in 1 || return 1
  assert_stderr_contains "Usage: ./countdown.sh [DURATION] [OPTIONS]" || return 1
}

test_invalid_duration() {
  run_case 5 "$SCRIPT" "not-a-duration"
  assert_exit_in 1 || return 1
  assert_stderr_contains "Invalid time." || return 1
}

test_too_many_positionals() {
  run_case 5 "$SCRIPT" 5 extra
  assert_exit_in 2 || return 1
  assert_stderr_contains "Too many positional arguments" || return 1
}

test_font_flag_allows_plain_text() {
  run_case 5 "$SCRIPT" 0 --nosound --no-title --throttle=0 --font term
  assert_exit_in 0 || return 1
  assert_stdout_contains "TIME'S UP!" || return 1
}

test_invalid_until_format() {
  run_case 5 "$SCRIPT" --until=notatime
  assert_exit_in 1 || return 1
  assert_stderr_contains "Invalid --until value" || return 1
}

test_until_short_duration() {
  local future
  future="$(date -d 'now + 2 seconds' +%H:%M:%S)"
  run_case 10 "$SCRIPT" --until="$future" --nosound --no-title --throttle=0 --font term
  assert_exit_in 0 || return 1
  assert_stdout_contains "TIME'S UP!" || return 1
}

test_duration_and_until_note() {
  local future
  future="$(date -d 'now + 2 seconds' +%H:%M:%S)"
  run_case 10 "$SCRIPT" 1 --until="$future" --nosound --no-title --throttle=0 --font term
  assert_exit_in 0 || return 1
  assert_stderr_contains "Note: both duration" || return 1
}

test_done_cmd_runs() {
  local tmpfile
  tmpfile="$(mktemp)"
  TMP_PATHS+=("$tmpfile")
  run_case 5 "$SCRIPT" 0 --nosound --no-title --throttle=0 --font term \
    --done-cmd="printf done >$tmpfile"
  assert_exit_in 0 || return 1
  assert_file_contains "$tmpfile" "done" || return 1
}

test_throttle_warning() {
  run_case 5 "$SCRIPT" 0 --throttle=1 --nosound --no-title --font term
  assert_exit_in 0 || return 1
  assert_stderr_contains "Warning: --throttle=1" || return 1
}

test_non_interactive_long_roll_no_prompt() {
  local past
  past="$(date -d 'now - 2 hours' +%H:%M:%S)"
  run_case 3 "$SCRIPT" --until="$past" --nosound --no-title --throttle=0 --font term
  assert_exit_in 0 124 || return 1
  assert_stderr_contains "Notice: Target time is" || return 1
  assert_stderr_contains "non-interactive; proceeding" || return 1
}

test_iso_duration_pt_s() {
  run_case 5 "$SCRIPT" PT2S --nosound --no-title --throttle=0 --font term
  assert_exit_in 0 || return 1
  assert_stdout_contains "TIME'S UP!" || return 1
}

test_combined_units_duration() {
  run_case 5 "$SCRIPT" 0h0m2s --nosound --no-title --throttle=0 --font term
  assert_exit_in 0 || return 1
  assert_stdout_contains "TIME'S UP!" || return 1
}

test_custom_message_shown() {
  run_case 5 "$SCRIPT" 0 --nosound --no-title --throttle=0 --font term --message="All done"
  assert_exit_in 0 || return 1
  assert_stdout_contains "All done" || return 1
}

test_throttle_off_has_no_warning() {
  run_case 5 "$SCRIPT" 0 --throttle=off --nosound --no-title --font term
  assert_exit_in 0 || return 1
  assert_stderr_not_contains "Warning: --throttle" || return 1
}

test_lolcat_runs_by_default() {
  local log
  log="$(mktemp)"
  TMP_PATHS+=("$log")
  local base_cmd
  base_cmd="TERM=xterm-256color ./countdown.sh 0 --nosound --no-title --throttle=0 --font term"
  run_case 5 env LOLCAT_LOG_FILE="$log" script -q -c "$base_cmd" /dev/null
  assert_exit_in 0 || return 1
  assert_file_contains "$log" "lolcat invoked" || return 1
}

test_no_color_disables_lolcat() {
  local log
  log="$(mktemp)"
  TMP_PATHS+=("$log")
  local base_cmd
  base_cmd="TERM=xterm-256color ./countdown.sh 0 --nosound --no-title --throttle=0 --font term --no-color"
  run_case 5 env LOLCAT_LOG_FILE="$log" script -q -c "$base_cmd" /dev/null
  assert_exit_in 0 || return 1
  assert_file_empty "$log" || return 1
}

if ! $MANUAL_ONLY; then
  echo "Running automated countdown.sh tests ..."
  auto_test "help flag prints usage" test_help_flag
  auto_test "no args shows usage error" test_no_args_usage
  auto_test "invalid duration rejected" test_invalid_duration
  auto_test "too many positionals rejected" test_too_many_positionals
  auto_test "font flag allows plain text output" test_font_flag_allows_plain_text
  auto_test "invalid --until format rejected" test_invalid_until_format
  auto_test "--until for near future completes" test_until_short_duration
  auto_test "duration plus --until emits note" test_duration_and_until_note
  auto_test "--done-cmd executes command" test_done_cmd_runs
  auto_test "throttle over cap warns" test_throttle_warning
  auto_test "non-interactive long roll avoids prompt" test_non_interactive_long_roll_no_prompt
  auto_test "ISO 8601 PT#S duration counts down" test_iso_duration_pt_s
  auto_test "combined-unit duration (0h0m2s) counts down" test_combined_units_duration
  auto_test "custom message appears in output" test_custom_message_shown
  auto_test "--throttle=off skips warning" test_throttle_off_has_no_warning
  auto_test "lolcat runs by default when available" test_lolcat_runs_by_default
  auto_test "--no-color skips lolcat" test_no_color_disables_lolcat

  echo
  printf 'Automated: %d passed, %d failed\n' "$AUTO_PASS" "$AUTO_FAIL"
else
  echo "Skipping automated countdown.sh tests (--manual-only)."
fi

declare -a MANUAL_DESC=() MANUAL_LIMIT=() MANUAL_CMD=()
add_manual() {
  MANUAL_DESC+=("$1")
  MANUAL_LIMIT+=("$2")
  MANUAL_CMD+=("$3")
}

add_manual "Visual: default centered output + gradient" 6 "./countdown.sh $MANUAL_DURATION --nosound --throttle=0.15"
add_manual "Visual: left alignment" 6 "./countdown.sh $MANUAL_DURATION --left --nosound --throttle=0.15"
add_manual "Visual: --clear screen wipe" 6 "./countdown.sh $MANUAL_DURATION --clear --nosound --throttle=0.15"
add_manual "Sound: verify completion chime/bell" 5 "./countdown.sh $MANUAL_DURATION --throttle=0 --no-title"
add_manual "Long-roll warning or prompt" 8 "./countdown.sh --until=\"\$(date -d 'now - 2 hours' +%H:%M:%S)\" --nosound --no-title --throttle=0.1"

run_manual_tests() {
  local idx desc limit cmd answer result prompt
  if ((${#MANUAL_DESC[@]} == 0)); then
    return
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    echo
    echo "Manual checks skipped (non-interactive session)."
    (( MANUAL_SKIP += ${#MANUAL_DESC[@]} ))
    return
  fi

  echo
  echo "Manual checks (please review visually / audibly):"
  for idx in "${!MANUAL_DESC[@]}"; do
    desc="${MANUAL_DESC[idx]}"
    limit="${MANUAL_LIMIT[idx]}"
    cmd="${MANUAL_CMD[idx]}"
    echo
    echo "● $desc"
    printf '  💻 Command: %s\n' "$cmd"
    printf "  Press Enter to run, or type s to skip: "
    drain_tty
    read -r answer < /dev/tty || answer=""
    if [[ "$answer" == "s" || "$answer" == "S" ]]; then
      MANUAL_SKIP+=1
      echo "  ↪ skipped"
      continue
    fi
    drain_tty
    local cmd_status=0
    trap - INT
    if ! LC_ALL="$MANUAL_LOCALE" TERM=xterm-256color PATH="$ORIGINAL_PATH" "${TIMEOUT_CMD[@]}" "$limit" bash -lc "cd '$SCRIPT_DIR' && $cmd$MANUAL_FONT_ARG"; then
      cmd_status=$?
      echo "  (Command exited with status $cmd_status)"
    fi
    trap 'handle_interrupt INT' INT
    drain_tty
    sleep 0.3
    printf '\n'
    while true; do
      printf "  Did this look/sound correct? [y/n]: "
      read -r result < /dev/tty || result=""
      case "$result" in
        [yY])
          MANUAL_PASS+=1
          echo "  ✅ marked as PASS"
          break
          ;;
        [nN])
          MANUAL_FAIL+=1
          echo "  ❌ marked as FAIL"
          break
          ;;
        *)
          echo "  ↪ please answer y or n"
          ;;
      esac
    done
  done
}

run_manual_tests

echo
printf 'Manual: %d passed, %d failed, %d skipped\n' "$MANUAL_PASS" "$MANUAL_FAIL" "$MANUAL_SKIP"

exit $(( AUTO_FAIL > 0 || MANUAL_FAIL > 0 ))
