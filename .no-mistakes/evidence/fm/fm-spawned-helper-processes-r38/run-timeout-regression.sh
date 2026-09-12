#!/usr/bin/env bash
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29X96Q8GBCS5NB92S2S7GWB"
cd "$ROOT"
# Source helpers and test definitions without running the full suite
eval "$(sed -n '1,1976p' tests/fm-session-start.test.sh | sed '/^test_[a-z_]*() {$/,/^}$/!d;/^test_runtime_bound_truncates/,/^}$/d;/^test_runtime_bound_leaves/,/^}$/d' 2>/dev/null || true)"
