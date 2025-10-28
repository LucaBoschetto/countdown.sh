#!/usr/bin/env bash
# Countdown with toilet + global lolcat gradient and cinematic throttling
# - Computes end timestamp once; each frame shows end-now (always in sync)
# - One frame per second; per-line throttle capped so a frame <~ 0.9s
# - Resilient to suspend/lag; next frame snaps to correct remaining time
# - Supports durations (SS | MM:SS | HH:MM:SS | Xm | Xh | Xs | 1h30m20s | ISO8601 PT1H30M20S)
# - Supports end time via --until=HH:MM[:SS] or --until=YYYY-MM-DDTHH:MM[:SS]
# - Frame style options (--scroll default, --clear, --overwrite)
# - Centered output by default (use --left to disable centering)
# - Custom finish message (--message), optional finish command (--done-cmd),
#   configurable sound (--sound/--silent), terminal title progress toggles

set -u

# --- help message ------------------------------------------------------------
show_help() {
  cat <<'EOF'
Usage: countdown.sh [DURATION] [OPTIONS]

Notes:
  Supply a duration positionally or use -u/--until to target a clock time.

DURATION formats:
  SS                          seconds (e.g., 45)
  MM:SS                       minutes:seconds (e.g., 3:15)
  HH:MM:SS                    hours:minutes:seconds (e.g., 1:02:30)
  Xm | Xh | Xs                unit-suffixed minutes/hours/seconds (e.g., 45m, 2h, 90s)
  1h30m20s                    combined units (H/M/S in any order; case-insensitive)
  PT1H30M20S                  ISO 8601 duration (P=period, T=time part, H/M/S units)

TIME (end time):
  -u TIME, --until=TIME       today at that time (tomorrow if already past)
  --until=YYYY-MM-DDTHH:MM[:SS]
                              explicit date/time (ISO-ish)

Options:
  -c, --clear                 Clear screen each second (default: scroll)
  -o, --overwrite             Redraw in place (no scroll/clear)
      --scroll                Scroll output (default)
  -l, --left                  Left-align output (default: centered)
      --center                Center output (default)
  -t SECONDS, --throttle=SECONDS
                              Delay between lines for cinematic output (default: 0.05)
  -C, --no-color              Disable lolcat gradients (default: color)
      --color                 Enable lolcat gradients (default)
  -m TEXT, --message="text"
                              Custom final message (default: TIME'S UP!)
  -d CMD, --done-cmd='cmd'
                              Run a command when the timer finishes (async)
  -f FONT, --font=FONT        Use a specific toilet font (default: smblock)
  -n, --silent                Disable finish sound (default: sound)
      --sound                 Enable finish sound (default)
  -T, --no-title              Disable terminal/tab title updates (default: enabled)
      --title                 Enable terminal/tab title updates (default)
  -y, --yes                   Auto-confirm prompts (e.g., very long --until)
  -u TIME, --until=TIME       End at a specific clock time (see TIME formats above)
  -p VALUE, --spread=VALUE    Pass --spread=VALUE through to lolcat gradients
  -F VALUE, --freq=VALUE      Pass --freq=VALUE through to lolcat gradients
      --config PATH           Load defaults from PATH (default: XDG config dir)
      --no-config             Skip loading any config file
      --save-config[=PATH]    Write current options to config and exit
      --print-config          Show effective configuration and exit
  -h, --help                  Show this help message

Examples:
  countdown.sh 45
  countdown.sh 3:15 --font smblock --clear
  countdown.sh 10:00 --font future --throttle=0.1
  countdown.sh 1h30m --message="Break" --done-cmd='notify-send "Break" "Timer done"'
  countdown.sh --until=23:30      # until 23:30 today (or tomorrow if past)
  countdown.sh --until=2025-10-23T14:00
EOF
}
[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && { show_help; exit 0; }

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

trim_ws(){
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

expand_path(){
  local p="$1"
  case "$p" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${p#~/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

default_config_path(){
  local base="${XDG_CONFIG_HOME:-$HOME/.config}"
  printf '%s/countdown/config' "$base"
}

set_bool_var(){
  local var="$1" raw="$2" label="$3"
  local lowered="${raw,,}"
  case "$lowered" in
    1|true|yes|on|enable|enabled)
      printf -v "$var" "true"
      ;;
    0|false|no|off|disable|disabled)
      printf -v "$var" "false"
      ;;
    *)
      echo "Warning: ignoring invalid boolean for ${label}: ${raw}" >&2
      return 1
      ;;
  esac
}

set_output_mode(){
  local raw="$1" val="${1,,}"
  case "$val" in
    scroll|clear|overwrite)
      output_mode="$val"
      ;;
    *)
      echo "Warning: ignoring invalid output mode value: ${raw}" >&2
      return 1
      ;;
  esac
}

load_config_file(){
  local path="$1"
  [[ -f "$path" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=$(trim_ws "$key")
    [[ -z "$key" ]] && continue
    [[ ${key:0:1} == "#" || ${key:0:1} == ";" ]] && continue
    value=$(trim_ws "$value")
    if [[ ${value:0:1} == '"' && ${value: -1} == '"' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${value:0:1} == "'" && ${value: -1} == "'" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi
    local key_lc="${key,,}"
    case "$key_lc" in
      clear)
        local tmp_bool
        if set_bool_var tmp_bool "$value" "$key"; then
          if [[ "$tmp_bool" == "true" ]]; then
            output_mode="clear"
          else
            output_mode="scroll"
          fi
        fi
        ;;
      output_mode|mode) set_output_mode "$value" ;;
      center) set_bool_var center "$value" "$key" ;;
      color) set_bool_var use_lolcat "$value" "$key" ;;
      sound) set_bool_var sound_on "$value" "$key" ;;
      title) set_bool_var title_on "$value" "$key" ;;
      font) font="$value" ;;
      throttle) throttle="$value" ;;
      message) final_msg="$value" ;;
      done_cmd|done-cmd) done_cmd="$value" ;;
      spread|lolcat_spread) lolcat_spread="$value" ;;
      freq|frequency|lolcat_frequency) lolcat_frequency="$value" ;;
      *)
        echo "Warning: unknown config key '${key}' ignored" >&2
        ;;
    esac
  done <"$path"
}

write_config_file(){
  local path="$1"
  local dir
  dir=$(dirname "$path")
  mkdir -p "$dir" || { echo "Error: unable to create config directory '$dir'" >&2; return 1; }

  if [[ -e "$path" && "$assume_yes" != "true" ]]; then
    if [ -t 0 ] && [ -t 1 ]; then
      printf "Config file %s exists. Overwrite? [y/N] " "$path" > /dev/tty
      local reply
      read -r reply < /dev/tty || reply=""
      case "$reply" in
        [yY]*) ;;
        *) echo "Aborted." >&2; return 1 ;;
      esac
    else
      echo "Error: refusing to overwrite '$path' without --yes in non-interactive mode" >&2
      return 1
    fi
  fi

  local tmp
  tmp=$(mktemp "${dir}/countdown.tmp.XXXXXX") || { echo "Error: unable to create temporary file in '$dir'" >&2; return 1; }
  {
    printf "# countdown.sh configuration\n"
    printf "output_mode=%s\n" "$output_mode"
    printf "center=%s\n" "$center"
    printf "color=%s\n" "$use_lolcat"
    printf "sound=%s\n" "$sound_on"
    printf "title=%s\n" "$title_on"
    printf "font=%s\n" "$font"
    printf "throttle=%s\n" "$throttle"
    printf "message=%s\n" "$final_msg"
    printf "done_cmd=%s\n" "$done_cmd"
    printf "spread=%s\n" "$lolcat_spread"
    printf "freq=%s\n" "$lolcat_frequency"
  } >"$tmp"
  mv "$tmp" "$path" || { echo "Error: unable to write config to '$path'" >&2; rm -f "$tmp"; return 1; }
}

print_effective_config(){
  cat <<EOF
output_mode=$output_mode
center=$center
color=$use_lolcat
sound=$sound_on
title=$title_on
font=$font
throttle=$throttle
message=$final_msg
done_cmd=$done_cmd
spread=$lolcat_spread
freq=$lolcat_frequency
EOF
}

# ----- args (shift-based parser; supports -t 0.05 and long/short forms) -----
# Defaults
font="smblock"; throttle="0.05"; until_str=""
final_msg="TIME'S UP!"; done_cmd=""; sound_on=true; center=true; title_on=true; assume_yes=false; use_lolcat=true
output_mode="scroll"; lolcat_spread=""; lolcat_frequency=""; overwrite_prev_width=0; overwrite_prev_height=0; interrupt_requested=false
original_args=("$@")

config_path_env=${COUNTDOWN_CONFIG:-}
if [[ -n "$config_path_env" ]]; then
  config_path=$(expand_path "$config_path_env")
else
  config_path=$(default_config_path)
fi
load_config=true
save_config=false
save_config_path=""
print_config=false

for ((i=0; i<${#original_args[@]}; i++)); do
  arg="${original_args[i]}"
  case "$arg" in
    --no-config)
      load_config=false
      ;;
    --config)
      if (( i + 1 >= ${#original_args[@]} )); then
        echo "Error: --config requires a value" >&2
        exit 2
      fi
      load_config=true
      config_path=$(expand_path "${original_args[i+1]}")
      ((i++))
      ;;
    --config=*)
      cfg_value="${arg#*=}"
      if [[ -z "$cfg_value" ]]; then
        echo "Error: --config requires a value" >&2
        exit 2
      fi
      load_config=true
      config_path=$(expand_path "$cfg_value")
      ;;
  esac
done

if [[ -z "$config_path" ]]; then
  echo "Error: config path may not be empty" >&2
  exit 2
fi

if $load_config; then
  load_config_file "$config_path"
fi

# Parse
positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    -c|--clear) output_mode="clear"; shift ;;
    --scroll) output_mode="scroll"; shift ;;
    -o|--overwrite) output_mode="overwrite"; shift ;;
    -l|--left) center=false; shift ;;
    --center) center=true; shift ;;
    -n|--silent) sound_on=false; shift ;;
    --sound) sound_on=true; shift ;;
    -T|--no-title) title_on=false; shift ;;
    --title) title_on=true; shift ;;
    -y|--yes) assume_yes=true; shift ;;
    -C|--no-color) use_lolcat=false; shift ;;
    --color) use_lolcat=true; shift ;;

    --config)
      config_path="${2:-}"; if [[ -z "$config_path" || "$config_path" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      config_path=$(expand_path "$config_path"); shift 2 ;;
    --config=*)
      config_path="${1#*=}"; if [[ -z "$config_path" ]]; then echo "Error: --config requires a value" >&2; exit 2; fi
      config_path=$(expand_path "$config_path"); shift ;;
    --no-config)
      load_config=false; shift ;;
    --save-config)
      save_config=true; shift ;;
    --save-config=*)
      save_config=true; save_config_path=$(expand_path "${1#*=}"); shift ;;
    --print-config)
      print_config=true; shift ;;

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

    -f|--font)
      font="${2:-}"; if [[ -z "$font" || "$font" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi; shift 2 ;;
    --font=*)
      font="${1#*=}"; shift ;;

    -p|--spread)
      lolcat_spread="${2:-}"; if [[ -z "$lolcat_spread" || "$lolcat_spread" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      shift 2
      ;;
    -p=*|--spread=*)
      lolcat_spread="${1#*=}"; if [[ -z "$lolcat_spread" ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      shift
      ;;

    -F|--freq)
      lolcat_frequency="${2:-}"; if [[ -z "$lolcat_frequency" || "$lolcat_frequency" == -* ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      shift 2
      ;;
    -F=*|--freq=*)
      lolcat_frequency="${1#*=}"; if [[ -z "$lolcat_frequency" ]]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      shift
      ;;

    --) shift; while [[ $# -gt 0 ]]; do positionals+=("$1"); shift; done ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) positionals+=("$1"); shift ;;
  esac
done

# Positional handling: TIME|DURATION only
usage_msg="Usage: $0 [DURATION] [OPTIONS]  (try --help)"
if [[ ${#positionals[@]} -gt 1 ]]; then
  echo "Error: Too many positional arguments. Use -f/--font to set the font." >&2
  echo "$usage_msg" >&2
  exit 2
fi
first=""; [[ ${#positionals[@]} -ge 1 ]] && first="${positionals[0]}"
management_mode=false
if $save_config; then management_mode=true; fi
if $print_config; then management_mode=true; fi
if [[ -z "$first" && -z "$until_str" && "$management_mode" != "true" ]]; then
  echo "$usage_msg" >&2; exit 1
fi
if [[ "$management_mode" == "true" ]]; then
  if $print_config; then
    print_effective_config
  fi
  if $save_config; then
    target_path="$config_path"
    [[ -n "$save_config_path" ]] && target_path="$save_config_path"
    target_path=$(expand_path "$target_path")
    if [[ -z "$target_path" ]]; then
      echo "Error: unable to determine config path for saving" >&2
      exit 1
    fi
    if write_config_file "$target_path"; then
      echo "Config saved to $target_path"
    else
      exit 1
    fi
  fi
  exit 0
fi

# --- dependency preflight ----------------------------------------------------
deps=(toilet lolcat)
missing=()
for dep in "${deps[@]}"; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    missing+=("$dep")
  fi
done
if ((${#missing[@]})); then
  printf "Missing dependencies: %s\n" "${missing[*]}" >&2
  printf "Install them with one of:\n" >&2
  printf "  sudo apt install %s\n"   "${missing[*]}" >&2
  printf "  sudo pacman -S %s\n"     "${missing[*]}" >&2
  printf "  sudo dnf install %s\n"   "${missing[*]}" >&2
  printf "  sudo zypper install %s\n" "${missing[*]}" >&2
  exit 1
fi

# ----- terminal capability detection ----------------------------------------
headless=false
if ! [ -t 1 ] || [[ -z ${TERM:-} || $TERM == "dumb" ]]; then
  headless=true
fi
if $headless; then
  suppressed=()
  $center && suppressed+=("centering")
  $use_lolcat && suppressed+=("colors")
  if ((${#suppressed[@]})); then
    joiner=" and "
    if ((${#suppressed[@]} == 2)); then
      note="${suppressed[0]}${joiner}${suppressed[1]}"
    else
      note="${suppressed[0]}"
    fi
    echo "WARNING: running in headless mode: ${note} ignored" >&2
  fi
  center=false
  use_lolcat=false
fi

prepare_frame_output(){
  case "$output_mode" in
    clear)
      clear
      printf '\n'
      ;;
    overwrite)
      if (( overwrite_prev_height > 0 )); then
        printf '\033[%sA\r' "$overwrite_prev_height"
      else
        printf '\n'
      fi
      ;;
    *)
      echo
      ;;
  esac
}

pad_frame_for_overwrite(){
  [[ "$output_mode" == "overwrite" ]] || return 0
  local -n arr=$1
  local frame_width=0 line target_width pad i
  for line in "${arr[@]}"; do
    (( ${#line} > frame_width )) && frame_width=${#line}
  done
  target_width=$frame_width
  (( overwrite_prev_width > target_width )) && target_width=$overwrite_prev_width
  if (( target_width <= 0 )); then
    overwrite_prev_width=$target_width
    return 0
  fi
  for i in "${!arr[@]}"; do
    line="${arr[i]}"
    pad=$(( target_width - ${#line} ))
    if (( pad > 0 )); then
      arr[i]="${line}$(printf '%*s' "$pad" "")"
    fi
  done
    overwrite_prev_width=$target_width
  overwrite_prev_height=${#arr[@]}
}

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
parsed_end_wall=0
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
    parsed_end_wall=$end
    return 0
  fi
  # Full datetime via `date -d`
  if date -d "$u" +%s >/dev/null 2>&1; then
    ts=$(date -d "$u" +%s)
    parsed_end_wall=$ts
    return 0
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
  if ! parse_until "$until_str"; then
    echo "Invalid --until value. Use HH:MM[:SS] or YYYY-MM-DDTHH:MM[:SS]" >&2; exit 1
  fi
  end_wall=$parsed_end_wall
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
if $use_lolcat && command -v lolcat >/dev/null 2>&1; then
  lolcat_args=()
  [[ -n "$lolcat_spread" ]] && lolcat_args+=(--spread="$lolcat_spread")
  [[ -n "$lolcat_frequency" ]] && lolcat_args+=(--freq="$lolcat_frequency")
  exec > >(lolcat "${lolcat_args[@]}")
fi

# Clean traps: reset title on exit; on Ctrl-C, reset title then exit 130
reset_title() { printf $'\033]0;\007' 1>&2; }
show_cursor() { printf $'\033[?25h' 1>&2; }
hide_cursor() { printf $'\033[?25l' 1>&2; }

cleanup_exit(){
  $title_on && reset_title
  show_cursor
}

cleanup_interrupt(){
  interrupt_requested=true
}

handle_pending_interrupt(){
  $interrupt_requested || return 0
  if [[ "$output_mode" == "overwrite" && $overwrite_prev_height -gt 0 ]]; then
    printf '\r\033[K'
    local i
    for ((i=1; i<overwrite_prev_height; i++)); do
      printf '\n\033[K'
    done
    printf '\n'
  else
    echo
  fi
  echo "[Interrupted]"
  exit 130
}

trap cleanup_exit EXIT
trap cleanup_interrupt INT
handle_winch(){ overwrite_prev_width=0; }
trap handle_winch WINCH
hide_cursor

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
  if [[ "$output_mode" == "overwrite" ]]; then
    printf '\r\033[K'
  fi
  if [[ -z "$line" ]]; then
    printf '\n'
    return
  fi
  if $center && [[ -n ${TERM:-} && $TERM != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    local cols pad w
    cols=$(tput cols 2>/dev/null) || cols=0
    if (( cols > 0 )); then
      w=${#line}; pad=$(( (cols - w) / 2 )); (( pad < 0 )) && pad=0
      printf "%*s%s\n" "$pad" "" "$line"
      return
    fi
  fi
  printf "%s\n" "$line"
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
  handle_pending_interrupt
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

  prepare_frame_output
  mapfile -t FRAME < <( fmt_time "$rem" | toilet -f "$font" 2>/dev/null )
  (( ${#FRAME[@]} == 0 )) && FRAME=("")
  if [[ "$output_mode" == "overwrite" ]]; then
    FRAME=("" "${FRAME[@]}")
  fi

  pad_frame_for_overwrite FRAME

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
  if [[ "$output_mode" == "overwrite" ]]; then
    printf '\033[J'
  fi

  handle_pending_interrupt

  (( rem == 0 )) && break
  ts_tick=$(sleepenh "$ts_tick" 1.0) || ts_tick=$(sleepenh 0)
done

# ----- final message ---------------------------------------------------------
handle_pending_interrupt
prepare_frame_output
if toilet -f "$font" "$final_msg" >/dev/null 2>&1; then
  mapfile -t END < <(toilet -f "$font" "$final_msg" 2>/dev/null)
else
  mapfile -t END < <(toilet -f big   "$final_msg" 2>/dev/null)
fi
if [[ "$output_mode" == "overwrite" ]]; then
  END=("" "${END[@]}")
fi
pad_frame_for_overwrite END
print_frame END
if [[ "$output_mode" == "overwrite" ]]; then
  printf '\033[J'
fi

handle_pending_interrupt

# ----- finish: beeps (paplay preferred, else terminal bell), spaced with sleepenh
if $sound_on; then
  beep_sound="/usr/share/sounds/freedesktop/stereo/complete.oga"
  ts_b=$(sleepenh 0)
  for _ in 1 2 3; do
    handle_pending_interrupt
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
  handle_pending_interrupt
  # run in foreground so its output appears before we exit (stderr visible)
  bash -lc "$done_cmd"
fi
