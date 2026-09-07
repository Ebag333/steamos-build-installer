#!/usr/bin/env bash
# cpu-scaling-monitor — poll CPU scaling state every 1s.
# Ctrl-C to stop.
set -euo pipefail

printf '%-24s %-14s %-14s %-8s\n' "TIMESTAMP" "GOVERNOR" "EPP" "BOOST"
printf '%s\n' "$(printf '%.0s-' {1..64})"

while true; do
  ts="$(date +%H:%M:%S)"
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  epp="$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)"

  boost="n/a"
  if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    if [ "$(cat /sys/devices/system/cpu/cpufreq/boost)" = 1 ]; then boost="on"; else boost="off"; fi
  elif [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    if [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 0 ]; then boost="on"; else boost="off"; fi
  fi

  printf '%-24s %-14s %-14s %-8s\n' "$ts" "$gov" "$epp" "$boost"
  sleep 1
done
