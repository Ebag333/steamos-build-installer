#!/usr/bin/env bash
# proton-bench-harness.sh
#
# A/B benchmark harness for Proton launch options.
#
# Fetches ranked launch-option candidates from ProtonDB, runs a game with
# different environment-variable permutations, and captures GPU telemetry
# from nvidia-smi for each run.  Also collects MangoHud CSV output for
# per-frame FPS / frame-time data.  Produces a side-by-side comparison
# report at the end.
#
# The harness does NOT assume a fixed run duration — it waits for the game
# process to exit naturally.  For Cyberpunk's built-in benchmark this means
# it runs, the benchmark completes, and the process exits.
#
# Dependencies:
#   - protondb_launch_options_v8.py (same directory)
#   - nvidia-smi, python3
#   - mangohud (optional, globally installed or explicit)
#
# Usage:
#   ./proton-bench-harness.sh <appid> [--rounds N] [--skip-fetch]
#   ./proton-bench-harness.sh 1091500
#   ./proton-bench-harness.sh 1091500 --rounds 3
#   ./proton-bench-harness.sh 1091500 --skip-fetch
#
# Environment overrides:
#   PROTON_BENCH_CMD        game launch command (required)
#                           e.g. 'steam -applaunch 1091500 -- --benchmark'
#   PROTON_BENCH_ROUNDS     repetitions per case   (default: 1)
#   PROTON_BENCH_COOLDOWN   seconds between runs   (default: 15)
#   PROTON_BENCH_GPU_ID     nvidia-smi GPU index   (default: 0)
#   PROTON_BENCH_LOG_DIR    output directory        (default: ~/benchmark-harness)
#   PROTON_BENCH_MANGOHUD   0 to disable MangoHud  (default: 1 if available)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTONDB_SCRIPT="$SCRIPT_DIR/protondb_launch_options_v8.py"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

ROUNDS="${PROTON_BENCH_ROUNDS:-1}"
COOLDOWN="${PROTON_BENCH_COOLDOWN:-15}"
GPU_ID="${PROTON_BENCH_GPU_ID:-0}"
LOG_DIR="${PROTON_BENCH_LOG_DIR:-$HOME/benchmark-harness}"
SKIP_FETCH=0
APPID=""
EXTRA_CASES=()
USE_MANGOHUD="${PROTON_BENCH_MANGOHUD:-}"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") <appid> [OPTIONS]

Options:
  --rounds N        Repetitions per test case (default: $ROUNDS)
  --cooldown S      Seconds between runs (default: $COOLDOWN)
  --gpu-id N        nvidia-smi GPU index (default: $GPU_ID)
  --skip-fetch      Skip ProtonDB fetch, use cached options JSON
  --case "ENV..."   Add a custom env-var case (repeatable)
  --no-mangohud     Disable MangoHud even if globally installed
  -h, --help        Show this help

Environment (required):
  PROTON_BENCH_CMD   Actual game launch command.
                     e.g. PROTON_BENCH_CMD="steam -applaunch 1091500 -- --benchmark"

Examples:
  PROTON_BENCH_CMD="steam -applaunch 1091500 -- --benchmark" \\
    $(basename "$0") 1091500

  PROTON_BENCH_CMD="steam -applaunch 1091500 -- --benchmark" \\
    $(basename "$0") 1091500 --rounds 3 --case "PROTON_NO_ESYNC=1"
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds)
      ROUNDS="$2"
      shift 2
      ;;
    --cooldown)
      COOLDOWN="$2"
      shift 2
      ;;
    --gpu-id)
      GPU_ID="$2"
      shift 2
      ;;
    --skip-fetch)
      SKIP_FETCH=1
      shift
      ;;
    --case)
      EXTRA_CASES+=("$2")
      shift 2
      ;;
    --no-mangohud)
      USE_MANGOHUD=0
      shift
      ;;
    -h | --help) usage ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      [[ -z "$APPID" ]] || {
        echo "Unexpected argument: $1" >&2
        exit 1
      }
      APPID="$1"
      shift
      ;;
  esac
done

[[ -n "$APPID" ]] || {
  echo "Error: appid required" >&2
  usage
}

GAME_CMD="${PROTON_BENCH_CMD:-}"
if [[ -z "$GAME_CMD" ]]; then
  echo "Error: PROTON_BENCH_CMD is required." >&2
  echo "  e.g. PROTON_BENCH_CMD=\"steam -applaunch 1091500 -- --benchmark\"" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

command -v nvidia-smi >/dev/null 2>&1 || {
  echo "ERROR: nvidia-smi not found" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 not found" >&2
  exit 1
}

[[ -x "$PROTONDB_SCRIPT" ]] || {
  echo "ERROR: protondb_launch_options_v8.py not found at $PROTONDB_SCRIPT" >&2
  exit 1
}

# Auto-detect MangoHud unless explicitly disabled.
if [[ -z "$USE_MANGOHUD" ]]; then
  if command -v mangohud >/dev/null 2>&1; then
    USE_MANGOHUD=1
  else
    USE_MANGOHUD=0
  fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOG_DIR/${APPID}-${STAMP}"
mkdir -p "$RUN_DIR"

REPORT="$RUN_DIR/comparison.txt"
OPTIONS_JSON="$RUN_DIR/launch-options.json"
GAME_NAME=""

# MangoHud default output location — we override per-case via config.
# shellcheck disable=SC2034 # MANGOHUD_DEFAULT_LOG reserved for future use
MANGOHUD_DEFAULT_LOG="${XDG_CONFIG_HOME:-$HOME/.config}/MangoHud"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

gpu_snapshot() {
  nvidia-smi -i "$GPU_ID" \
    --query-gpu=name,driver_version,memory.total,power.limit \
    --format=csv,noheader 2>/dev/null || echo "unknown"
}

gpu_telemetry_line() {
  nvidia-smi -i "$GPU_ID" \
    --query-gpu=utilization.gpu,utilization.memory,clocks.gr,clocks.mem,memory.used,power.draw,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null || echo "?,?,?,?,?,?,?"
}

# Telemetry sampler — writes CSV rows to $1 while process $2 is alive.
# Stops 2 seconds after the game exits (to catch tail-end GPU state).
sample_telemetry() {
  local out_csv="$1"
  local watch_pid="$2"
  local ts line gpu_util mem_util gfx vram pwr temp

  echo "timestamp,gpu_util,mem_util,gfx_mhz,vram_used,power_w,temp_c" >"$out_csv"

  while kill -0 "$watch_pid" 2>/dev/null; do
    ts="$(date '+%T.%3N')"
    line="$(gpu_telemetry_line)"
    IFS=',' read -r gpu_util mem_util gfx _ vram pwr temp <<<"$line"
    echo "${ts},${gpu_util},${mem_util},${gfx},${vram},${pwr},${temp}" >>"$out_csv"
    sleep 1
  done

  # A couple more samples after exit to capture final state.
  for _ in 1 2; do
    ts="$(date '+%T.%3N')"
    line="$(gpu_telemetry_line)"
    IFS=',' read -r gpu_util mem_util gfx _ vram pwr temp <<<"$line"
    echo "${ts},${gpu_util},${mem_util},${gfx},${vram},${pwr},${temp}" >>"$out_csv"
    sleep 1
  done
}

# Parse MangoHud CSV output for frame-time stats.
# MangoHud CSV columns vary by config; we look for common ones.
summarize_mangohud() {
  local csv="$1"
  [[ -f "$csv" ]] || return

  python3 -c "
import csv, statistics, sys

path = sys.argv[1]
rows = []
try:
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
except Exception:
    sys.exit(0)

if not rows:
    sys.exit(0)

def safe_float(row, *keys):
    for key in keys:
        val = row.get(key, '').strip()
        if val:
            try:
                return float(val)
            except ValueError:
                continue
    return None

fps_vals = [v for r in rows if (v := safe_float(r, 'fps', 'FPS')) is not None]
ft_vals = [v for r in rows if (v := safe_float(r, 'frametime', 'frame_time', 'Frametime')) is not None]
gpu_load = [v for r in rows if (v := safe_float(r, 'gpu_load', 'GPU Load', 'gpu_util')) is not None]

result = {}
if fps_vals:
    result['fps_avg'] = f'{statistics.mean(fps_vals):.1f}'
    result['fps_1%'] = f'{sorted(fps_vals)[max(0, int(len(fps_vals)*0.01))]:.1f}'
    result['fps_min'] = f'{min(fps_vals):.1f}'
    result['fps_max'] = f'{max(fps_vals):.1f}'
if ft_vals:
    sorted_ft = sorted(ft_vals)
    result['ft_avg'] = f'{statistics.mean(ft_vals):.2f}'
    result['ft_p99'] = f'{sorted_ft[min(int(len(sorted_ft)*0.99), len(sorted_ft)-1)]:.2f}'
    result['ft_max'] = f'{max(ft_vals):.2f}'

for key in ('fps_avg', 'fps_1%', 'fps_min', 'fps_max', 'ft_avg', 'ft_p99', 'ft_max'):
    print(f'{key}={result.get(key, \"?\")}')
" "$csv" 2>/dev/null || true
}

# Compute summary stats from a telemetry CSV.
summarize_csv() {
  local csv="$1"
  python3 -c "
import csv, statistics, sys

rows = []
with open(sys.argv[1]) as f:
    reader = csv.DictReader(f)
    for row in reader:
        try:
            rows.append({k: float(v) for k, v in row.items()
                         if k != 'timestamp' and v.strip() not in ('', '?')})
        except ValueError:
            continue

if not rows:
    print('no data,,,,,,,,' )
    sys.exit(0)

def avg(key):
    vals = [r[key] for r in rows if key in r]
    return f'{statistics.mean(vals):.1f}' if vals else '?'

def p95(key):
    vals = sorted(r[key] for r in rows if key in r)
    if not vals: return '?'
    return f'{vals[min(int(len(vals)*0.95), len(vals)-1)]:.1f}'

def mn(key):
    vals = [r[key] for r in rows if key in r]
    return f'{min(vals):.1f}' if vals else '?'

def mx(key):
    vals = [r[key] for r in rows if key in r]
    return f'{max(vals):.1f}' if vals else '?'

print(','.join([
    avg('gpu_util'), p95('gpu_util'), mn('gpu_util'), mx('gpu_util'),
    avg('mem_util'), p95('mem_util'),
    avg('gfx_mhz'), p95('gfx_mhz'),
    avg('vram_used'), mx('vram_used'),
    avg('power_w'), p95('power_w'),
    avg('temp_c'), mx('temp_c'),
]))
" "$csv"
}

# ---------------------------------------------------------------------------
# Fetch launch options from ProtonDB
# ---------------------------------------------------------------------------

fetch_launch_options() {
  log "Fetching ProtonDB launch options for appid $APPID ..."
  python3 "$PROTONDB_SCRIPT" "$APPID" \
    --json \
    >"$OPTIONS_JSON" 2>/dev/null || {
    echo "WARNING: ProtonDB fetch failed, continuing with empty options" >&2
    echo '{"result":[]}' >"$OPTIONS_JSON"
  }
}

# Load $OPTIONS_JSON and normalize the candidates list, then run a
# caller-supplied Python snippet with `candidates` in scope.
_with_candidates() {
  local snippet="$1"
  python3 - "$OPTIONS_JSON" <<PYEOF 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
candidates = data.get('result', [])
if isinstance(candidates, dict):
    candidates = candidates.get('candidates', [])
${snippet}
PYEOF
}

extract_top_candidates() {
  _with_candidates "
for c in candidates[:8]:
    canon = c.get('canonical', '')
    score = c.get('rankScore', 0)
    reports = c.get('reportCount', 0)
    if canon:
        print(f'{canon}\t{score}\t{reports}')
"
}

# ---------------------------------------------------------------------------
# Test-case definitions
# ---------------------------------------------------------------------------

declare -a CASE_LABELS=()
declare -a CASE_ENVS=()
declare -a CASE_ARGS=()

add_case() {
  local label="$1" envs="$2" args="$3"
  CASE_LABELS+=("$label")
  CASE_ENVS+=("$envs")
  CASE_ARGS+=("$args")
}

# ---------------------------------------------------------------------------
# Build test matrix
# ---------------------------------------------------------------------------

build_cases() {
  log "Building test cases ..."

  add_case "baseline" "" ""
  add_case "PROTON_NO_UPLOAD_HVV=1" "PROTON_NO_UPLOAD_HVV=1" ""
  add_case "VKD3D_CONFIG=no_upload_hvv" "VKD3D_CONFIG=no_upload_hvv" ""
  add_case "DXVK_ASYNC=1" "DXVK_ASYNC=1" ""
  add_case "PROTON_NO_UPLOAD_HVV=1 + DXVK_ASYNC=1" \
    "PROTON_NO_UPLOAD_HVV=1 DXVK_ASYNC=1" ""

  if ((!SKIP_FETCH)); then
    fetch_launch_options
  elif [[ -f "$OPTIONS_JSON" ]]; then
    log "Using cached $OPTIONS_JSON"
  else
    echo '{"result":[]}' >"$OPTIONS_JSON"
  fi

  local count=0
  # shellcheck disable=SC2034 # reports unused; only canon and score are consumed
  while IFS=$'\t' read -r canon score reports; do
    [[ -n "$canon" ]] || continue
    ((count++))
    ((count > 8)) && break

    local env_str="" arg_str=""
    local -a parts
    read -ra parts <<<"$canon"
    for part in "${parts[@]}"; do
      if [[ "$part" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        env_str+="${env_str:+ }$part"
      elif [[ "$part" == "%command%" ]]; then
        continue
      else
        arg_str+="${arg_str:+ }$part"
      fi
    done

    add_case "protondb #$count (score ${score})" "$env_str" "$arg_str"
  done <<<"$(extract_top_candidates)"

  for custom in "${EXTRA_CASES[@]}"; do
    add_case "custom: $custom" "$custom" ""
  done

  log "${#CASE_LABELS[@]} test cases defined"
}

# ---------------------------------------------------------------------------
# Run one benchmark iteration
# ---------------------------------------------------------------------------

run_one() {
  local case_idx="$1"
  local round="$2"
  local label="${CASE_LABELS[$case_idx]}"
  local envs="${CASE_ENVS[$case_idx]}"
  local args="${CASE_ARGS[$case_idx]}"

  local safe_label
  safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
  local case_dir="$RUN_DIR/case-${case_idx}-${safe_label}"
  mkdir -p "$case_dir"

  local telemetry="$case_dir/telemetry-r${round}.csv"
  local summary="$case_dir/summary-r${round}.txt"
  local mangohud_csv="$case_dir/mangohud-r${round}.csv"
  local mangohud_summary="$case_dir/mangohud-summary-r${round}.txt"
  local env_log="$case_dir/env.txt"

  # Record exact environment for reproducibility.
  {
    echo "case=$label"
    echo "round=$round"
    echo "env=$envs"
    echo "args=$args"
    echo "timestamp=$(date --iso-8601=seconds)"
  } >"$env_log"

  log "  Round $round: $label"

  # Expand %command% in protondb args to the actual game command.
  local full_args="${args//\%command\%/$GAME_CMD}"

  # Build env prefix.
  local env_prefix=""
  if [[ -n "$envs" ]]; then
    for kv in $envs; do
      env_prefix+="env $kv "
    done
  fi

  # MangoHud: create a per-case config that logs CSV to our case dir.
  local mangohud_conf=""
  if ((USE_MANGOHUD)); then
    mangohud_conf="$case_dir/mangohud.conf"
    cat >"$mangohud_conf" <<MANGOCONF
output_folder=$case_dir
log_duration=0
csv=1
legacy_layout=false
MANGOCONF
    env_prefix+="MANGOHUD_CONFIGFILE=$mangohud_conf "
  fi

  # Start the game in background so we can watch its PID.
  log "    starting: ${env_prefix}${full_args}"
  eval "${env_prefix}${full_args}" >"$case_dir/stdout.log" 2>"$case_dir/stderr.log" &
  local game_pid=$!

  # Start telemetry sampler watching the game PID.
  sample_telemetry "$telemetry" "$game_pid" &
  local telem_pid=$!

  # Wait for game to finish.
  local game_rc=0
  wait "$game_pid" 2>/dev/null || game_rc=$?
  log "    game exited (rc=$game_rc)"

  # Stop telemetry sampler.
  wait "$telem_pid" 2>/dev/null || true

  # Summarize nvidia-smi telemetry.
  summarize_csv "$telemetry" >"$summary"

  # Summarize MangoHud data if available.
  if ((USE_MANGOHUD)); then
    # MangoHud writes its own filename; find the latest in our case dir.
    local mh_csv
    mh_csv="$(find "$case_dir" -maxdepth 1 -name '*.csv' ! -name '*telemetry*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [[ -n "$mh_csv" && "$mh_csv" != "$telemetry" ]]; then
      mv "$mh_csv" "$mangohud_csv" 2>/dev/null || true
    fi
    summarize_mangohud "$mangohud_csv" >"$mangohud_summary"
    log "    mangohud -> $mangohud_summary"
  fi

  log "    telemetry -> $summary"
}

# ---------------------------------------------------------------------------
# Generate comparison report
# ---------------------------------------------------------------------------

generate_report() {
  log "Generating comparison report ..."

  {
    echo "============================================================"
    echo "Proton Launch-Option Benchmark Report"
    echo "============================================================"
    echo "AppID:        $APPID"
    echo "Game:         $GAME_NAME"
    echo "GPU:          $(gpu_snapshot)"
    echo "Rounds:       $ROUNDS"
    echo "MangoHud:     $( ((USE_MANGOHUD)) && echo "enabled" || echo "disabled")"
    echo "Command:      $GAME_CMD"
    echo "Date:         $(date --iso-8601=seconds)"
    echo "Log dir:      $RUN_DIR"
    echo
    echo "------------------------------------------------------------"
    printf "%-40s | %8s %8s %8s %8s | %8s %8s | %8s %8s | %8s %8s | %8s %8s" \
      "Case" \
      "GPUavg" "GPU95th" "GPUmin" "GPUmax" \
      "MEMavg" "MEM95th" \
      "GFXavg" "GFX95th" \
      "VRAMavg" "VRAMmax" \
      "PWRavg" "PWR95th"
    if ((USE_MANGOHUD)); then
      printf " | %8s %8s %8s %8s" "FPSavg" "FPS1%" "FTavg" "FTp99"
    fi
    echo
    echo "------------------------------------------------------------"

    for i in "${!CASE_LABELS[@]}"; do
      local label="${CASE_LABELS[$i]}"
      local safe_label
      safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
      local case_dir="$RUN_DIR/case-${i}-${safe_label}"

      # Collect per-round summaries.
      local -a stats_files=()
      local -a mh_files=()
      for ((r = 1; r <= ROUNDS; r++)); do
        [[ -f "$case_dir/summary-r${r}.txt" ]] && stats_files+=("$case_dir/summary-r${r}.txt")
        [[ -f "$case_dir/mangohud-summary-r${r}.txt" ]] && mh_files+=("$case_dir/mangohud-summary-r${r}.txt")
      done

      if ((${#stats_files[@]} == 0)); then
        printf "%-40s | %s\n" "$label" "no data"
        continue
      fi

      # Average nvidia-smi stats across rounds.
      local averaged
      averaged="$(python3 -c "
import statistics, sys

all_rows = []
for path in sys.argv[1:]:
    with open(path) as f:
        vals = f.read().strip().split(',')
    if len(vals) >= 14:
        try:
            all_rows.append([float(v) if v != '?' else None for v in vals])
        except ValueError:
            pass

if not all_rows:
    print(','.join(['?'] * 14)); sys.exit(0)

cols = list(zip(*all_rows))
result = []
for col in cols:
    clean = [v for v in col if v is not None]
    result.append(f'{statistics.mean(clean):.1f}' if clean else '?')
print(','.join(result))
" "${stats_files[@]}")"

      IFS=',' read -r gpu_avg gpu95 gpu_min gpu_max mem_avg mem95 \
        gfx_avg gfx95 vram_avg vram_max pwr_avg pwr95 \
        _temp_avg _temp_max <<<"$averaged"

      printf "%-40s | %8s %8s %8s %8s | %8s %8s | %8s %8s | %8s %8s | %8s %8s" \
        "${label:0:40}" \
        "$gpu_avg" "$gpu95" "$gpu_min" "$gpu_max" \
        "$mem_avg" "$mem95" \
        "$gfx_avg" "$gfx95" \
        "$vram_avg" "$vram_max" \
        "$pwr_avg" "$pwr95"

      # Append MangoHud FPS/frame-time columns if available.
      if ((USE_MANGOHUD && ${#mh_files[@]} > 0)); then
        local mh_avg
        mh_avg="$(python3 -c "
import statistics, sys

vals = {'fps_avg':[], 'fps_1%':[], 'ft_avg':[], 'ft_p99':[]}
for path in sys.argv[1:]:
    with open(path) as f:
        for line in f:
            if '=' in line:
                k, v = line.strip().split('=', 1)
                if k in vals and v != '?':
                    try: vals[k].append(float(v))
                    except ValueError: pass

for key in ('fps_avg', 'fps_1%', 'ft_avg', 'ft_p99'):
    s = vals[key]
    print(f'{statistics.mean(s):.1f}' if s else '?')
" "${mh_files[@]}")"

        local fps_avg fps1 ft_avg ft_p99
        IFS=$'\n' read -r fps_avg fps1 ft_avg ft_p99 <<<"$mh_avg"
        printf " | %8s %8s %8s %8s" "$fps_avg" "$fps1" "$ft_avg" "$ft_p99"
      fi

      echo
    done

    echo
    echo "Legend:"
    echo "  GPU/MEM util = %, GFX = MHz, VRAM = MiB, PWR = W, TEMP = C"
    echo "  95th = 95th percentile, avg = average, min/max = observed extremes"
    if ((USE_MANGOHUD)); then
      echo "  FPSavg = average FPS, FPS1% = 1% low, FTavg = avg frame time (ms), FTp99 = 99th percentile frame time (ms)"
    fi
    echo
    echo "Raw telemetry CSVs are in: $RUN_DIR/case-*/"
    echo
    echo "============================================================"
    echo "Launch options fetched from ProtonDB"
    echo "============================================================"
    if [[ -f "$OPTIONS_JSON" ]]; then
      _with_candidates "
for i, c in enumerate(candidates[:10], 1):
    canon = c.get('canonical', '?')
    score = c.get('rankScore', '?')
    reports = c.get('reportCount', '?')
    applicable = c.get('applicable', '?')
    score_str = f'{score:5.1f}' if isinstance(score, (int, float)) else f'{score:>5}'
    print(f'{i:2}. [{score_str}] ({reports:3} reports) {canon}')
    if not applicable:
        print(f'    reason: {c.get(\"applicabilityReason\", \"?\")}')
"
    fi
  } | tee "$REPORT"

  log "Report saved to: $REPORT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  echo
  echo "============================================================"
  echo " Proton Launch-Option Benchmark Harness"
  echo "============================================================"
  echo " AppID:    $APPID"
  echo " Rounds:   $ROUNDS"
  echo " Command:  $GAME_CMD"
  echo " MangoHud: $( ((USE_MANGOHUD)) && echo "enabled" || echo "disabled")"
  echo " Log dir:  $RUN_DIR"
  echo "============================================================"
  echo

  log "GPU: $(gpu_snapshot)"

  build_cases

  GAME_NAME="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('name', sys.argv[2]))
" "$OPTIONS_JSON" "AppID $APPID" 2>/dev/null || echo "AppID $APPID")"
  log "Game: $GAME_NAME"

  # Confirm before running.
  if [[ -t 0 ]]; then
    echo
    read -rp "Run ${#CASE_LABELS[@]} cases x $ROUNDS rounds? [Y/n] " confirm
    [[ "${confirm,,}" != "n" ]] || {
      log "Aborted."
      exit 0
    }
  fi

  local total_runs=$((${#CASE_LABELS[@]} * ROUNDS))
  local run_num=0

  for ((r = 1; r <= ROUNDS; r++)); do
    for i in "${!CASE_LABELS[@]}"; do
      ((run_num++))
      log "[$run_num/$total_runs] Case $((i + 1))/${#CASE_LABELS[@]}, round $r/$ROUNDS ..."
      run_one "$i" "$r"

      if ((run_num < total_runs)); then
        log "  Cooling down ${COOLDOWN}s ..."
        sleep "$COOLDOWN"
      fi
    done
  done

  generate_report
  log "All done. Results in: $RUN_DIR"
}

main
