#!/usr/bin/env bash
# fm-scout-artifact-lib.sh - the single owner of "which file under data/<id>/ is
# this task's surviving artifact".
#
# data/<id>/report.md is the default and the only artifact an ordinary scout
# delivers. Two producers declare a different one:
#   - bin/fm-brief.sh --scout --sol-spec scaffolds a Sol spec scout whose whole
#     work product is data/<id>/spec.md, so nothing named report.md is ever
#     written for it.
#   - bin/fm-promote.sh --sol-spec-for installs that reviewed spec at the gated
#     ship task's own data/<id>/spec.md.
# Both record the declaration in data/<id>/.deliverable at the moment they
# establish the artifact, so every consumer classifies from a durable statement
# by the owning script rather than from whichever files happen to be present.
# That distinction is the point: an ordinary scout that leaves a stray spec.md
# behind is still an ordinary scout, and its teardown still demands report.md.
#
# Consumers: bin/fm-teardown.sh's scout work-product gate and backlog hint, and
# bin/fm-fleet-snapshot.sh's scout_reports[] inventory.
# No side effects on source.

FM_SCOUT_ARTIFACT_DEFAULT=report.md

# fm_scout_deliverable_marker <data-dir> <task-id>
fm_scout_deliverable_marker() {
  printf '%s/%s/.deliverable' "${1%/}" "$2"
}

# fm_scout_deliverable_name <data-dir> <task-id>
# Prints the declared artifact's basename. Only an exact recognized declaration
# is honoured; an absent, unreadable, or unrecognized marker reads as the
# default, so a damaged declaration narrows to the strict ordinary contract
# instead of widening what satisfies a gate.
fm_scout_deliverable_name() {
  local marker declared
  marker=$(fm_scout_deliverable_marker "$1" "$2")
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    declared=$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)
    case "$declared" in
      report.md|spec.md) printf '%s' "$declared"; return 0 ;;
    esac
  fi
  printf '%s' "$FM_SCOUT_ARTIFACT_DEFAULT"
}

# fm_scout_deliverable_path <data-dir> <task-id>
fm_scout_deliverable_path() {
  printf '%s/%s/%s' "${1%/}" "$2" "$(fm_scout_deliverable_name "$1" "$2")"
}

# fm_scout_deliverable_declare <data-dir> <task-id> <report.md|spec.md>
# Records the declaration atomically. Returns 1 on an unknown artifact name or a
# write failure, so a caller can refuse rather than proceed undeclared.
fm_scout_deliverable_declare() {
  local data=${1%/} id=$2 name=$3 marker tmp
  case "$name" in
    report.md|spec.md) ;;
    *) return 1 ;;
  esac
  marker=$(fm_scout_deliverable_marker "$data" "$id")
  mkdir -p "$data/$id" || return 1
  tmp="$marker.tmp.$$"
  printf '%s\n' "$name" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}
