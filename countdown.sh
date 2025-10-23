#!/usr/bin/env bash
# --- portable sleepenh shim (Linux) ------------------------------------------
# Emulates:
#   sleepenh 0            -> prints a monotonic "now" timestamp
#   sleepenh PREV STEP    -> sleeps until PREV+STEP, prints that target
# Notes:
# - Uses /proc/uptime (monotonic since boot). No external deps.
# - On SIGINT, `sleep` returns non-zero; we propagate that exit code.
# - Always prints the target timestamp on success.
sleepenh() {
  case "$#" in
    1)
      if [[ "$1" == "0" ]]; then
        # monotonic "now"
        awk '{printf "%.9f\n",$1}' /proc/uptime
      else
        echo "sleepenh: invalid usage (expected: 0)" >&2
        return 2
      fi
      ;;
    2)
      local prev="$1" step="$2"
      # basic numeric validation
      awk -v p="$prev" -v s="$step" 'BEGIN{exit (p==p+0 && s==s+0)?0:1}' \
        || { echo "sleepenh: non-numeric args" >&2; return 2; }

      local target now rem
      target=$(awk -v p="$prev" -v s="$step" 'BEGIN{printf "%.9f", p+s}')
      now=$(awk '{printf "%.9f",$1}' /proc/uptime)
      rem=$(awk -v t="$target" -v n="$now" 'BEGIN{r=t-n; if (r<0) r=0; printf "%.9f", r}')

      # sleep remaining time (if any). If interrupted, propagate.
      if awk -v r="$rem" 'BEGIN{exit (r>0)?0:1}'; then
        sleep "$rem" || return $?
      fi

      printf '%s\n' "$target"
      ;;
    *)
      echo "sleepenh: usage: sleepenh 0 | sleepenh <prev_ts> <step>" >&2
      return 2
      ;;
  esac
}
# Countdown with toilet + global lolcat gradient and cinematic throttling
# - Computes end timestamp once; each frame shows end-now (always in sync)
# - One frame per second; per-line throttle capped so a frame <~ 0.9s
# - Resilient to suspend/lag; next frame snaps to correct remaining time
# - Supports durations (SS | MM:SS | HH:MM:SS | Xm | Xh | Xs | 1h30m20s | ISO8601 PT1H30M20S)
# - Supports end time via --until=HH:MM[:SS] or --until=YYYY-MM-DDTHH:MM[:SS]
# - Centered output by default (use --left to disable centering)
# - Custom finish message (--message), optional finish command (--done-cmd),
#   optional mute (--nosound), terminal title progress (disable with --no-title)

set -u

# --- help message ------------------------------------------------------------
show_help() {
  cat <<'EOF'
Usage: countdown.sh TIME|DURATION [FONT] [OPTIONS]

DURATION formats:
  SS                  seconds (e.g., 45)
  MM:SS               minutes:seconds (e.g., 3:15)
  HH:MM:SS            hours:minutes:seconds (e.g., 1:02:30)
  Xm | Xh | Xs        unit-suffixed minutes/hours/seconds (e.g., 45m, 2h, 90s)
  1h30m20s            combined units (H/M/S in any order; case-insensitive)
  PT1H30M20S          ISO 8601 duration (P=period, T=time part, H/M/S units)

TIME (end time):
  --until=HH:MM[:SS]              today at that time (tomorrow if already past)
  --until=YYYY-MM-DDTHH:MM[:SS]   explicit date/time (ISO-ish)

Options:
  --clear                Clear screen each second instead of scrolling
  --left                 Left-align output (default is centered)
  --throttle=SECONDS     Delay between lines for cinematic output (default: 0.05)
  --message="text"       Custom final message (default: TIME'S UP!)
  --done-cmd='cmd'       Run a command when the timer finishes (async)
  --nosound              Disable finish sound
  --no-title             Do not update the terminal/tab title
  --yes                  Auto-confirm prompts (e.g., very long --until)
  -h, --help             Show this help message

Examples:
  countdown.sh 45
  countdown.sh 3:15 smblock --clear
  countdown.sh 10:00 future --throttle=0.1
  countdown.sh 1h30m --message="Break" --done-cmd='notify-send "Break" "Timer done"'
  countdown.sh --until=23:30      # until 23:30 today (or tomorrow if past)
  countdown.sh --until=2025-10-23T14:00
EOF
}
[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && { show_help; exit 0; }

# --- dependency preflight ----------------------------------------------------
for dep in toilet lolcat; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Missing '$dep'. Install with: sudo apt install $dep" >&2; exit 1; }
done

# ----- args (shift-based parser; supports -t 0.05 and long/short forms) -----
# Defaults
font="smblock"; clear_enabled=false; throttle="0.05"; until_str=""
final_msg="TIME'S UP!"; done_cmd=""; nosound=false; center=true; title_on=true; assume_yes=false

# Parse
positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -c|--clear) clear_enabled=true; shift ;;
    -l|--left) center=false; shift ;;
    -n|--nosound) nosound=true; shift ;;
    -T|--no-title) title_on=false; shift ;;
    -y|--yes) assume_yes=true; shift ;;

    -t|--throttle)
      throttle="${2:-}"; if [[ -z "$throttle" || "$throttle" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi; shift 2 ;;
    --throttle=*) throttle="${1#*=}"; shift ;;

    -u|--until)
      until_str="${2:-}"; if [[ -z "$until_str" || "$until_str" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi; shift 2 ;;
    --until=*) until_str="${1#*=}"; shift ;;

    -m|--message)
      final_msg="${2:-}"; if [[ -z "$final_msg" || "$final_msg" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi; shift 2 ;;
    --message=*) final_msg="${1#*=}"; shift ;;

    -d|--done-cmd)
      done_cmd="${2:-}"; if [[ -z "$done_cmd" || "$done_cmd" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi; shift 2 ;;
    --done-cmd=*) done_cmd="${1#*=}"; shift ;;

    --) shift; while [[ $# -gt 0 ]]; do positionals+=("$1"); shift; done ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) positionals+=("$1"); shift ;;
  esac
done

# Positional handling: [TIME|DURATION] [FONT]
first=""; [[ ${#positionals[@]} -ge 1 ]] && first="${positionals[0]}"
if [[ -z "$first" && -z "$until_str" ]]; then
  echo "Usage: $0 TIME|DURATION [FONT] [OPTIONS]  (try --help)" >&2; exit 1
fi
[[ ${#positionals[@]} -ge 2 ]] && font="${positionals[1]}"

maybe_clear(){ $clear_enabled && clear || echo; }

# ----- duration parsing ------------------------------------------------------
secs_from_duration() {
  local tok="$1" T=0
  # SS (allow large)
  if [[ "$tok" =~ ^([0-9]{1,7})$ ]]; then
    T=$((10#${BASH_REMATCH[1]}))
  # MM:SS
  elif [[ "$tok" =~ ^([0-9]{1,5}):([0-5]?[0-9])$ ]]; then
    local mm=${BASH_REMATCH[1]} ss=${BASH_REMATCH[2]}; T=$((10#$mm*60 + 10#$ss))
  # HH:MM:SS
  elif [[ "$tok" =~ ^([0-9]{1,5}):([0-5]?[0-9]):([0-5]?[0-9])$ ]]; then
    local hh=${BASH_REMATCH[1]} mm=${BASH_REMATCH[2]} ss=${BASH_REMATCH[3]}; T=$((10#$hh*3600 + 10#$mm*60 + 10#$ss))
  # Xm / Xh / Xs (case-insensitive)
  elif [[ "$tok" =~ ^([0-9]{1,7})([mMhHsS])$ ]]; then
    local val=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]}
    case "$unit" in
      m|M) T=$((10#$val*60)) ;;
      h|H) T=$((10#$val*3600)) ;;
      s|S) T=$((10#$val)) ;;
    esac
  # 1h30m20s style (order-insensitive among h/m/s)
  elif [[ "$tok" =~ ^(([0-9]+)[hH])?(([0-9]+)[mM])?(([0-9]+)[sS])?$ ]]; then
    local H=${BASH_REMATCH[2]:-0} M=${BASH_REMATCH[4]:-0} S=${BASH_REMATCH[6]:-0}
    T=$((10#$H*3600 + 10#$M*60 + 10#$S))
  # ISO 8601 durations like PT1H30M20S (time part only)
elif [[ $tok =~ ^P(T(([0-9]+)H)?(([0-9]+)M)?(([0-9]+)S)?)$ ]]; then
  local H=${BASH_REMATCH[3]:-0} M=${BASH_REMATCH[5]:-0} S=${BASH_REMATCH[7]:-0}
  T=$((10#$H*3600 + 10#$M*60 + 10#$S))
  else
    echo ""; return 1
  fi
  echo "$T"
}

now_epoch() { date +%s; }

# Tracks whether --until HH:MM[:SS] rolled to tomorrow
rolled_to_tomorrow=false
parse_until() {
  local u="$1" now ts
  rolled_to_tomorrow=false
  now=$(now_epoch)
  # Time of day HH:MM[:SS] — prefer this path so we can roll to tomorrow
  if [[ "$u" =~ ^([0-2]?[0-9]):([0-5][0-9])(:([0-5][0-9]))?$ ]]; then
    local today end
    today=$(date +%F)
    end=$(date -d "$today ${u}" +%s)
    if (( end <= now )); then
      end=$(( end + 86400 ))
      rolled_to_tomorrow=true
    fi
    echo "$end"; return 0
  fi
  # Full datetime via `date -d`
  if date -d "$u" +%s >/dev/null 2>&1; then
    ts=$(date -d "$u" +%s)
    echo "$ts"; return 0
  fi
  return 1
}

# Determine end_wall and total duration T
T=0; start_wall=$(now_epoch); end_wall=0
if [[ -n "$until_str" ]]; then
  if [[ -n "$first" && "$first" != --until=* && "$first" != -* ]]; then
    if secs_from_duration "$first" >/dev/null 2>&1; then
      echo "Note: both duration ('$first') and --until given; using --until." >&2
    fi
  fi
  if ! end_wall=$(parse_until "$until_str"); then
    echo "Invalid --until value. Use HH:MM[:SS] or YYYY-MM-DDTHH:MM[:SS]" >&2; exit 1
  fi
  T=$(( end_wall - start_wall )); (( T < 0 )) && T=0
  # If the computed target is far in the future (e.g., past time -> tomorrow), confirm
  threshold=$((21*3600))
  # Only prompt if the user gave a time-of-day that rolled to tomorrow
  if $rolled_to_tomorrow && (( T > threshold )); then
    hh=$(( T/3600 )); mm=$(( (T%3600)/60 )); ss=$(( T%60 ))
    msg="Target time is in ${hh}h ${mm}m ${ss}s. Continue? [y/N] "
    if $assume_yes; then
      : # proceed
    elif [ -t 0 ] && [ -t 1 ]; then
      printf "%s" "$msg" > /dev/tty
      read -r reply < /dev/tty || reply=""
      case "$reply" in
        [yY]*) : ;;
        *) echo "Aborted." >&2; exit 1 ;;
      esac
    else
      echo "Notice: ${msg} (non-interactive; proceeding)" >&2
    fi
  fi
else
  if ! T=$(secs_from_duration "$first"); then
    echo "Invalid time. Use SS, MM:SS, HH:MM:SS, Xm, Xh, Xs, 1h30m20s, PT1H30M20S; or --until=..." >&2; exit 1
  fi
  end_wall=$(( start_wall + T ))
fi

# ----- global gradient via a single lolcat (stdout only; stderr stays plain)
if command -v lolcat >/dev/null 2>&1; then
  exec > >(lolcat)
fi

# Clean traps: reset title on exit; on Ctrl-C, reset title then exit 130
if $title_on; then
  trap 'printf "]0;" 1>&2' EXIT
  trap '$title_on && printf "]0;" 1>&2; echo; echo "[Interrupted]"; exit 130' INT
else
  trap 'echo; echo "[Interrupted]"; exit 130' INT
fi

# ----- formatting ------------------------------------------------------------
fmt_time(){
  local rem=$1
  if (( rem >= 86400 )); then
    local d=$(( rem/86400 ))
    local h=$(( (rem%86400)/3600 ))
    local m=$(( (rem%3600)/60 ))
    local s=$(( rem%60 ))
    printf "%dd %02d:%02d:%02d" "$d" "$h" "$m" "$s"
  elif (( rem >= 3600 )); then
    printf "%d:%02d:%02d" $((rem/3600)) $(((rem%3600)/60)) $((rem%60))
  else
    printf "%02d:%02d"  $((rem/60)) $((rem%60))
  fi
}

# Centered printing helpers
print_centered_line(){
  local line="$1"
  if $center && command -v tput >/dev/null 2>&1; then
    local cols pad w
    cols=$(tput cols)
    w=${#line}; pad=$(( (cols - w) / 2 )); (( pad < 0 )) && pad=0
    printf "%*s%s\n" "$pad" "" "$line"
  else
    printf "%s\n" "$line"
  fi
}

print_frame(){
  local -n A=$1
  local l
  for l in "${A[@]}"; do print_centered_line "$l"; done
}

# ----- estimate lines per frame and cap per-line throttle (~0.9s/frame)
lpf=$(toilet -f "$font" "00:00:00" 2>/dev/null | wc -l)
(( lpf < 1 )) && lpf=4
frame_cap=0.90
if [[ "$throttle" != "0" && "$throttle" != "off" ]]; then
  cap=$(awk -v n="$lpf" -v fc="$frame_cap" 'BEGIN{printf "%.3f", fc/n}')
  over=$(awk -v u="$throttle" -v c="$cap" 'BEGIN{print (u>c)?"1":"0"}')
  [[ "$over" == "1" ]] && echo "Warning: --throttle=$throttle too high for ~$lpf lines/frame; capping to $cap (≈${frame_cap}s/frame)" >&2
  throttle=$(awk -v u="$throttle" -v c="$cap" 'BEGIN{printf "%.3f", (u<c)?u:c}')
fi

# ----- tick scheduler and duplicate-skip state ------------------------------
ts_tick=$(sleepenh 0)
prev_rem=-1

# ----- main loop: one frame per second; remaining derived from end time -----
while :; do
  now=$(now_epoch)
  rem=$(( end_wall - now )); (( rem < 0 )) && rem=0

  # Terminal title (unless disabled)
  $title_on && printf "\033]0;⏳ %s\007" "$(fmt_time "$rem")" 1>&2

  # Skip duplicate frames (can happen right after resume)
  if (( rem == prev_rem )); then
    ts_tick=$(sleepenh "$ts_tick" 1.0) || ts_tick=$(sleepenh 0)
    continue
  fi
  # If we jumped forward by more than one second, print a note
  if (( prev_rem != -1 && prev_rem - rem > 1 )); then
    echo "[Resync: skipped $((prev_rem - rem - 1)) second(s)]" >&2
  fi
  prev_rem=$rem

  maybe_clear
  mapfile -t FRAME < <( fmt_time "$rem" | toilet -f "$font" 2>/dev/null )
  (( ${#FRAME[@]} == 0 )) && FRAME=("")

  if [[ "$throttle" == "0" || "$throttle" == "off" ]]; then
    print_frame FRAME
  else
    ts_line=$(sleepenh 0)
    last=$(( ${#FRAME[@]} - 1 ))
    for i in "${!FRAME[@]}"; do
      print_centered_line "${FRAME[i]}"
      (( i == last )) || ts_line=$(sleepenh "$ts_line" "$throttle")
    done
  fi

  (( rem == 0 )) && break
  ts_tick=$(sleepenh "$ts_tick" 1.0) || ts_tick=$(sleepenh 0)
done

# ----- final message ---------------------------------------------------------
maybe_clear
if toilet -f "$font" "$final_msg" >/dev/null 2>&1; then
  mapfile -t END < <(toilet -f "$font" "$final_msg" 2>/dev/null)
else
  mapfile -t END < <(toilet -f big   "$final_msg" 2>/dev/null)
fi
print_frame END

# ----- finish: beeps (paplay preferred, else terminal bell), spaced with sleepenh
if ! $nosound; then
  beep_sound="/usr/share/sounds/freedesktop/stereo/complete.oga"
  ts_b=$(sleepenh 0)
  for _ in 1 2 3; do
    if command -v paplay >/dev/null 2>&1 && [[ -f "$beep_sound" ]]; then
      paplay "$beep_sound" >/dev/null 2>&1 &
    else
      printf '\a' >&2
    fi
    ts_b=$(sleepenh "$ts_b" 0.5)
  done
fi

# optional done command
if [[ -n "$done_cmd" ]]; then
  # run in foreground so its output appears before we exit (stderr visible)
  bash -lc "$done_cmd"
fi
