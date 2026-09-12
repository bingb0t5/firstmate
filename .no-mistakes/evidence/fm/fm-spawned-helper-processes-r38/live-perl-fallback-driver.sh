#!/usr/bin/env bash
set -u
. "$1"
fm_run_timed 60 bash -c '
  printf "%s\n" "$BASHPID" > "$1"
  printf "%s\n" "$(ps -o pgid= -p "$BASHPID" | tr -d "[:space:]")" >> "$1"
  sleep 600 &
  printf "%s\n" "$!" >> "$1"
  wait "$!"
' _ "$2"
