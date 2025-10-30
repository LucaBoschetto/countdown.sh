### ⌛ `countdown.sh`

A feature-rich, fully terminal-based countdown timer for Linux.

Uses **`toilet`** for text rendering and **`lolcat`** for smooth color gradients.
Accurate timing comes from an in-script port of **`sleepenh`**, keeping throttled output in sync with real time.

<p align="center">
  <img src="docs/screenshot.png" alt="Screenshot of countdown.sh" width="600"/>
</p>

#### ✨ Features

* Accepts flexible duration formats:

  * `SS`, `MM:SS`, `HH:MM:SS`
  * `45m`, `2h`, `1h30m20s`
  * ISO-8601 durations like `PT1H30M20S`
* **`-u, --until=<time>`** or full **`-u, --until=<YYYY-MM-DDTHH:MM>`** target
* Auto-rolls to next day if time is in the past
  (with optional confirmation or automatic notice)
* Adjustable **`-t, --throttle`** (default **0.05s**) for smooth scrolling output
* **Centered output** by default (**`-l, --left`** available)
* Default **font:** `smblock` (customize via **`-f, --font`**)
* Choose your frame style: default **`--scroll`**, cinematic **`-c/--clear`**, or **`-o/--overwrite`** to redraw in place
* Optional **sound at completion** (**`-n/--silent`** to mute, **`--sound`** to force enable)
* **`-m, --message`** to display a custom end screen
* **`-d, --done-cmd`** to execute a command when time’s up
* **`-C, --no-color`** (and **`--color`**) to control gradients
* Tune lolcat gradients with **`-p/--spread`** and **`-F/--freq`**
* **Logging controls** via `--debug`, `--log-level`, and `--log-file`
* **`-V, --version`** prints the current script build
* **Config file support**: `--config`, `--save-config[=path]`, `--print-config`
* Background **auto-update** checks keep the script fresh (configurable)
* Day-aware display for timers exceeding 24h
* Graceful suspend/resume handling (skips missed seconds)

---

#### ⚙️ Dependencies

Install all required packages:

```bash
sudo apt install toilet lolcat
```

or your preferred package manager. If they are not installed, the script will gracefully tell you.

---

#### 🤖 Examples

```bash
# 10-minute timer
./countdown.sh 10m

# Until next 15:00 today (or tomorrow if past)
./countdown.sh --until=15:00

# ISO-8601 style
./countdown.sh PT2H30M

# Use a different font and clear screen each tick
./countdown.sh 3:00 --font digital --clear

# Overwrite in-place without scrolling
./countdown.sh 10 -o

# Run a command when finished
./countdown.sh 5 --done-cmd 'notify-send "Countdown finished!"'

# Silent run with scrolling text
./countdown.sh 2m --silent

# Save your preferred defaults
./countdown.sh --left --no-color --sound --save-config

# Launch the interactive setup wizard
./countdown.sh --setup

# Manually check for updates
./countdown.sh --check-updates

# Show version
./countdown.sh --version

# Enable verbose logging to a file
./countdown.sh 10 --debug --log-file ~/.cache/countdown.log
```

---

#### 🧪 Testing

An optional test suite (`test_countdown.sh`) exercises all input formats and logic paths.
Run it from the same directory:

```bash
bash test_countdown.sh
```

#### 🔄 Automatic updates

The script ships with automatic update checks enabled. Each run spawns a quick background check (at most once every 24 hours) that downloads the latest `countdown.sh` if a newer version is published.

- Toggle the behavior via the setup wizard, config file (`autoupdate=true/false`), or CLI flags (`--auto-update` / `--no-auto-update`).
- Use `--check-updates` to perform an immediate foreground check and report the result.
- By default the script reads the official manifest at `https://raw.githubusercontent.com/LucaBoschetto/countdown.sh/main/latest.txt`.
- Set a custom source with `update_url=<manifest-or-script URL>` in your config if you mirror the project elsewhere.
- Use `--debug` (or `--log-level`/`--log-file`) to capture detailed updater logs for troubleshooting.

#### 🚧 Planned improvements

- Support multiple named profiles that map to different config files
