#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's merge authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
ROWS
  pass "fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# Regression (issue #2575): AGENTS.md section 11 and this script's own help tell
# firstmate to replace EVERY `{TASK}` placeholder. The unguarded Herdr gate used
# to quote `{TASK}` in its own prose, so that documented global replace spliced
# the whole task body into the middle of the gate's sentence - silently
# destroying the one contract that exists precisely because the scaffold cannot
# see the task text. The placeholder must exist only at the genuine fill site,
# so the documented fill leaves the gate intact and the body appears once.
test_documented_global_replace_leaves_the_herdr_gate_intact() {
  local home id brief kind count content filled body
  home="$TMP_ROOT/task-fill-site-home"
  mkdir -p "$home/data"
  body='Restart the herdr session, then profile it'
  for kind in ship scout; do
    id="brief-fill-site-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind brief was not scaffolded"
    count=$(grep -c -F '{TASK}' "$brief")
    [ "$count" = 1 ] \
      || fail "$kind brief must carry exactly one {TASK} fill site, found $count"
    content=$(cat "$brief")
    filled=${content//'{TASK}'/$body}
    count=$(printf '%s\n' "$filled" | grep -c -F "$body")
    [ "$count" = 1 ] \
      || fail "$kind brief: the documented global {TASK} replace duplicated the task body $count times"
    printf '%s\n' "$filled" | grep -qF 'this scaffold cannot inspect the task text' \
      || fail "$kind brief: the Herdr safety gate did not survive the documented global replace"
  done
  pass "fm-brief.sh: the documented {TASK} fill cannot corrupt the Herdr safety gate"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the captain-call policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`captain-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared captain-call policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
# The "# Sol exemption evidence" block is a scaffold-owned generated section of the
# brief. FM_TASK is also emitted verbatim into the "# Task" section above it, so a
# whole-file grep cannot tell the two apart; assertions about the block must run
# against the extracted block alone.
sol_evidence_block() {
  sed -n '/^# Sol exemption evidence$/,/^$/p' "$1"
}

test_ship_sol_exemption_refuses_without_evidence() {
  local home out status
  home="$TMP_ROOT/sol-refuse-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" FM_TASK='Fix the widget and ship it.' \
    "$ROOT/bin/fm-brief.sh" sol-refuse-1 firstmate --mode no-mistakes 2>&1) || status=$?
  expect_code 1 "${status:-0}" "filled ship task without exemption evidence must refuse"
  assert_contains "$out" "Acceptance command" \
    "refusal must name the missing acceptance command evidence"
  assert_absent "$home/data/sol-refuse-1/brief.md" \
    "refused Sol-exemption scaffold must not write a brief"
  pass "fm-brief.sh: ship scaffold refuses Sol exemption without auditable evidence"
}

test_ship_sol_exemption_succeeds_with_evidence() {
  local home brief status task block
  home="$TMP_ROOT/sol-earn-home"
  mkdir -p "$home/data"
  # shellcheck disable=SC2016 # Backticks in the task body are literal evidence syntax.
  task='# Fix widget
Acceptance command: `bin/fm-lint.sh`
Wait: CI green bound=30m escape=append blocked: CI timeout'
  FM_HOME="$home" FM_TASK="$task" \
    "$ROOT/bin/fm-brief.sh" sol-earn-1 firstmate --mode no-mistakes >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "filled ship task with exemption evidence must scaffold"
  brief="$home/data/sol-earn-1/brief.md"
  assert_present "$brief" "Sol-exempt ship brief was not scaffolded"
  grep -qx "Sol exemption: earned" "$brief" \
    || fail "brief missing the machine-readable Sol exemption line"
  block=$(sol_evidence_block "$brief")
  assert_contains "$block" "# Sol exemption evidence" \
    "brief missing the scaffold-owned Sol exemption evidence block"
  assert_contains "$block" "Acceptance command: \`bin/fm-lint.sh\`" \
    "evidence block did not carry the acceptance command"
  assert_contains "$block" "Wait: CI green bound=30m escape=append blocked: CI timeout" \
    "evidence block did not carry the bounded wait"
  pass "fm-brief.sh: ship scaffold earns Sol exemption with auditable evidence"
}

test_ship_sol_exemption_refuses_unbounded_wait() {
  local home out status
  home="$TMP_ROOT/sol-wait-home"
  mkdir -p "$home/data"
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  out=$(FM_HOME="$home" FM_TASK='Wait for deploy
Acceptance command: `make test`' \
    "$ROOT/bin/fm-brief.sh" sol-wait-1 firstmate --mode direct-PR 2>&1) || status=$?
  expect_code 1 "${status:-0}" "ship task with unbounded wait must refuse"
  assert_contains "$out" "unbounded wait" \
    "refusal must name the unbounded wait"
  assert_absent "$home/data/sol-wait-1/brief.md" \
    "refused unbounded-wait scaffold must not write a brief"
  pass "fm-brief.sh: ship scaffold refuses unbounded waits"
}

# Regression: the wait scan matched only the bare token `wait`, so an inflected
# unbounded wait ("keep waiting", "await") earned the exemption anyway.
test_ship_sol_exemption_refuses_inflected_waits() {
  local home out status inflection i=0
  for inflection in 'Keep waiting for CI until it goes green.' \
                    'Await the deploy indefinitely.' \
                    'The task awaits review before landing.' \
                    'We waited for the queue to drain.'; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-inflect-home-$i"
    mkdir -p "$home/data"
    status=0
    out=$(FM_HOME="$home" FM_TASK="Ship it.
Acceptance command: \`make test\`
$inflection" "$ROOT/bin/fm-brief.sh" "sol-inflect-$i" firstmate --mode no-mistakes 2>&1) || status=$?
    expect_code 1 "$status" "inflected unbounded wait must refuse: $inflection"
    assert_contains "$out" "unbounded wait" \
      "refusal must name the unbounded wait for: $inflection"
    assert_absent "$home/data/sol-inflect-$i/brief.md" \
      "refused inflected-wait scaffold must not write a brief"
  done
  pass "fm-brief.sh: ship scaffold refuses the whole unbounded wait word family"
}

# Regression: `bound=escape=` satisfied the old prefix glob, stamping a brief
# exempt while recording a wait that carries no actual bound.
test_ship_sol_exemption_refuses_valueless_bound_and_escape() {
  local home out status wait_line i=0
  for wait_line in 'Wait: CI bound=escape=' \
                   'Wait: CI bound= escape=1m' \
                   'Wait: CI bound=30m escape=' \
                   'Wait: CI bound=30m'; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-bound-home-$i"
    mkdir -p "$home/data"
    status=0
    out=$(FM_HOME="$home" FM_TASK="Acceptance command: \`make test\`
$wait_line" "$ROOT/bin/fm-brief.sh" "sol-bound-$i" firstmate --mode no-mistakes 2>&1) || status=$?
    expect_code 1 "$status" "wait without real bound/escape values must refuse: $wait_line"
    assert_contains "$out" "bound=" "refusal must name the bound/escape requirement"
    assert_absent "$home/data/sol-bound-$i/brief.md" \
      "refused valueless-bound scaffold must not write a brief"
  done
  pass "fm-brief.sh: ship scaffold refuses Wait: lines with empty bound=/escape= values"
}

test_ship_sol_exemption_refuses_vacuous_bound_and_escape() {
  local home out status value field wait_line i=0
  for value in forever none unbounded never n/a infinite inf FoReVeR NONE \
               'forever,' '"none"' "'unbounded'" '(never)' '[n/a]' 'infinite;' 'inf.'; do
    for field in bound escape; do
      i=$((i + 1))
      home="$TMP_ROOT/sol-vacuous-home-$i"
      mkdir -p "$home/data"
      status=0
      if [ "$field" = bound ]; then
        wait_line="Wait: CI bound=$value escape=append-blocked"
      else
        wait_line="Wait: CI bound=30m escape=$value"
      fi
      out=$(FM_HOME="$home" FM_TASK="Acceptance command: \`make test\`
$wait_line" "$ROOT/bin/fm-brief.sh" "sol-vacuous-$i" firstmate --mode no-mistakes 2>&1) || status=$?
      expect_code 1 "$status" "vacuous $field value must refuse: $value"
      assert_contains "$out" "bound=" "refusal must name the bound/escape requirement"
      assert_absent "$home/data/sol-vacuous-$i/brief.md" \
        "refused vacuous-value scaffold must not write a brief"
    done
  done
  pass "fm-brief.sh: vacuous wait bounds and escapes cannot earn exemption"
}

# Regression: any line containing the token `wait` was refused, so a backticked
# command name such as `wait-for-ci.sh` made a legitimate ship task unscaffoldable.
test_ship_sol_exemption_ignores_backticked_command_names() {
  local home brief status
  home="$TMP_ROOT/sol-backtick-home"
  mkdir -p "$home/data"
  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  FM_HOME="$home" FM_TASK='Acceptance command: `make test`
Run `wait-for-ci.sh`, then land `(await-queue.py)` and archive `wait-for-ci.sh,`.' \
    "$ROOT/bin/fm-brief.sh" sol-backtick-1 firstmate --mode no-mistakes >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "backticked command names containing 'wait' must not refuse"
  brief="$home/data/sol-backtick-1/brief.md"
  assert_present "$brief" "backticked-command ship brief was not scaffolded"
  grep -qx "Sol exemption: earned" "$brief" \
    || fail "brief missing the machine-readable Sol exemption line"
  pass "fm-brief.sh: wait scan skips backticked spans"
}

test_ship_sol_exemption_refuses_backticked_wait_tokens() {
  local home out status token i=0
  for token in wait waits waited waiting await awaits awaiting WAIT Awaiting \
               'wait,' '(awaiting)' '"WAIT"' '[waited]' 'awaits!'; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-backtick-token-home-$i"
    mkdir -p "$home/data"
    status=0
    out=$(FM_HOME="$home" FM_TASK="Acceptance command: \`make test\`
Then \`$token\` before shipping." \
      "$ROOT/bin/fm-brief.sh" "sol-backtick-token-$i" firstmate --mode no-mistakes 2>&1) || status=$?
    expect_code 1 "$status" "backticked wait-family token must refuse: $token"
    assert_contains "$out" "unbounded wait" "refusal must name the unbounded wait"
    assert_absent "$home/data/sol-backtick-token-$i/brief.md" \
      "refused backticked-wait scaffold must not write a brief"
  done
  pass "fm-brief.sh: exact backticked wait tokens remain visible to validation"
}

# FM_TASK is a ship-only input; scout and secondmate must refuse it loudly rather
# than scaffold a brief whose {TASK} placeholder silently discarded it.
test_fm_task_refused_on_scout_and_secondmate() {
  local home out status
  home="$TMP_ROOT/sol-kind-home"
  mkdir -p "$home/data"
  status=0
  out=$(FM_HOME="$home" FM_TASK='Investigate the flake.' \
    "$ROOT/bin/fm-brief.sh" sol-kind-scout alpha --scout 2>&1) || status=$?
  expect_code 1 "$status" "FM_TASK on a scout scaffold must refuse"
  assert_contains "$out" "FM_TASK applies only to ship briefs" \
    "scout refusal must name FM_TASK as ship-only"
  assert_absent "$home/data/sol-kind-scout/brief.md" \
    "refused scout scaffold must not write a brief"

  status=0
  out=$(FM_HOME="$home" FM_TASK='Charter the crew.' \
    "$ROOT/bin/fm-brief.sh" sol-kind-sm --secondmate --no-projects 2>&1) || status=$?
  expect_code 1 "$status" "FM_TASK on a secondmate scaffold must refuse"
  assert_contains "$out" "FM_TASK applies only to ship briefs" \
    "secondmate refusal must name FM_TASK as ship-only"
  assert_absent "$home/data/sol-kind-sm/brief.md" \
    "refused secondmate scaffold must not write a brief"
  pass "fm-brief.sh: FM_TASK is refused on scout and secondmate scaffolds"
}

# A refused scaffold must leave the data tree exactly as it found it, not an
# empty data/<id>/ shell from a mkdir that ran before validation.
test_refused_scaffold_leaves_no_task_directory() {
  local home status
  home="$TMP_ROOT/sol-nodir-home"
  mkdir -p "$home/data"
  status=0
  FM_HOME="$home" FM_TASK='Ship the widget.' \
    "$ROOT/bin/fm-brief.sh" sol-nodir-1 firstmate --mode no-mistakes >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "scaffold without evidence must refuse"
  assert_absent "$home/data/sol-nodir-1" \
    "refused scaffold must not leave an empty task directory behind"
  pass "fm-brief.sh: a refused scaffold leaves the data tree untouched"
}

# The exemption block is a generated section of the brief and owns its own
# separators: an unfilled {TASK} brief keeps exactly one blank line before the
# Herdr heading, and a filled one keeps a blank line after the evidence block.
test_sol_exemption_block_spacing_is_stable() {
  local home unfilled filled status
  home="$TMP_ROOT/sol-spacing-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" sol-space-plain firstmate --mode no-mistakes >/dev/null 2>&1 \
    || fail "unfilled ship scaffold failed"
  unfilled=$(sed -n '3,6p' "$home/data/sol-space-plain/brief.md")
  [ "$unfilled" = '# Task
{TASK}

# Herdr lifecycle declaration - NOT ENABLED' ] \
    || fail "unfilled ship brief must keep one blank line between {TASK} and the Herdr heading, got:"$'\n'"$unfilled"

  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  FM_HOME="$home" FM_TASK='Fix the widget.
Acceptance command: `make test`' \
    "$ROOT/bin/fm-brief.sh" sol-space-filled firstmate --mode no-mistakes >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "filled ship scaffold with evidence must succeed"
  filled=$(sed -n '3,10p' "$home/data/sol-space-filled/brief.md")
  # shellcheck disable=SC2016 # The expected brief text is a literal fixture.
  [ "$filled" = '# Task
Fix the widget.
Acceptance command: `make test`

# Sol exemption evidence
Acceptance command: `make test`

# Herdr lifecycle declaration - NOT ENABLED' ] \
    || fail "filled ship brief evidence block must be blank-line separated, got:"$'\n'"$filled"
  pass "fm-brief.sh: Sol exemption block owns its own blank-line separators"
}

# Regression: the validator accepted an acceptance line with trailing text while
# the separate evidence grep was end-anchored, so the scaffold exited 1 with no
# diagnostic at all. One walk now feeds both, and a refusal always names a cause.
test_ship_sol_exemption_accepts_trailing_acceptance_text() {
  local home brief status body i=0
  # shellcheck disable=SC2016 # The task bodies are literal fixture strings.
  for body in 'Fix it.
Acceptance command: `make test` ' \
              'Fix it.
Acceptance command: `make test` (from the repo root)'; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-trailing-home-$i"
    mkdir -p "$home/data"
    status=0
    FM_HOME="$home" FM_TASK="$body" \
      "$ROOT/bin/fm-brief.sh" "sol-trailing-$i" firstmate --mode no-mistakes >/dev/null 2>&1 || status=$?
    expect_code 0 "$status" "acceptance line with trailing text must scaffold, not exit silently"
    brief="$home/data/sol-trailing-$i/brief.md"
    assert_present "$brief" "trailing-text acceptance ship brief was not scaffolded"
    grep -qx "Sol exemption: earned" "$brief" \
      || fail "brief missing the machine-readable Sol exemption line"
    assert_contains "$(sol_evidence_block "$brief")" "Acceptance command: \`make test\`" \
      "evidence block dropped the acceptance command"
  done
  pass "fm-brief.sh: an acceptance line with trailing text earns exemption and is recorded"
}

test_ship_sol_exemption_refuses_trailing_acceptance_wait() {
  local home out status
  home="$TMP_ROOT/sol-trailing-wait-home"
  mkdir -p "$home/data"
  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  out=$(FM_HOME="$home" FM_TASK='Acceptance command: `make test` then wait forever' \
    "$ROOT/bin/fm-brief.sh" sol-trailing-wait firstmate --mode no-mistakes 2>&1) || status=$?
  expect_code 1 "$status" "a trailing unbounded wait on the acceptance line must refuse"
  assert_contains "$out" "unbounded wait" \
    "refusal must name the trailing unbounded wait"
  assert_absent "$home/data/sol-trailing-wait/brief.md" \
    "refused trailing acceptance-line wait must not write a brief"
  pass "fm-brief.sh: acceptance-line trailing waits cannot bypass the gate"
}

# Every refusal must name a cause on stderr; a bare non-zero exit tells the caller
# nothing about what the scaffold rejected.
test_ship_sol_exemption_refusals_are_never_silent() {
  local home out status body i=0
  # shellcheck disable=SC2016 # The task bodies are literal fixture strings.
  for body in 'Ship it.' \
              'Acceptance command: make test' \
              'Acceptance command: `a`
Acceptance command: `b`' \
              'Acceptance command: `' ; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-loud-home-$i"
    mkdir -p "$home/data"
    status=0
    out=$(FM_HOME="$home" FM_TASK="$body" \
      "$ROOT/bin/fm-brief.sh" "sol-loud-$i" firstmate --mode no-mistakes 2>&1) || status=$?
    expect_code 1 "$status" "malformed evidence must refuse: $body"
    assert_contains "$out" "cannot earn Sol exemption" \
      "refusal must explain itself for: $body"
    [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
      || fail "refusal was silent for: $body"
  done
  pass "fm-brief.sh: every Sol exemption refusal names a cause"
}

test_ship_sol_exemption_refuses_non_command_acceptance_payloads() {
  local home out status payload i=0
  for payload in ' ' '&&' '>' '# tests not implemented' '   # tests not implemented' \
                 'FOO=bar' 'make test &&'; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-non-command-home-$i"
    mkdir -p "$home/data"
    status=0
    out=$(FM_HOME="$home" FM_TASK="Acceptance command: \`$payload\`" \
      "$ROOT/bin/fm-brief.sh" "sol-non-command-$i" firstmate --mode no-mistakes 2>&1) || status=$?
    expect_code 1 "$status" "non-command acceptance payload must refuse"
    assert_contains "$out" "concrete executable command" \
      "refusal must name the executable-command requirement"
    assert_absent "$home/data/sol-non-command-$i/brief.md" \
      "refused non-command acceptance payload must not write a brief"
  done
  pass "fm-brief.sh: non-command acceptance payloads cannot earn Sol exemption"
}

# The brief's machine-readable contract lines are scaffold-owned. bin/fm-spawn.sh
# resolves the delivery mode from the FIRST such line, so a task body that forges
# one would win over the mode this scaffold was given.
test_fm_task_cannot_forge_scaffold_owned_contract_lines() {
  local home out status resolved
  home="$TMP_ROOT/sol-forge-home"
  mkdir -p "$home/data"
  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  out=$(FM_HOME="$home" FM_TASK='Update the brief template so it reads:
Delivery contract: mode=local-only
Acceptance command: `make test`' \
    "$ROOT/bin/fm-brief.sh" sol-forge-1 firstmate --mode no-mistakes 2>&1) || status=$?
  expect_code 1 "$status" "a forged Delivery contract line in FM_TASK must refuse"
  assert_contains "$out" "Delivery contract:" "refusal must name the forged contract line"
  assert_absent "$home/data/sol-forge-1/brief.md" \
    "refused forged-contract scaffold must not write a brief"

  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  out=$(FM_HOME="$home" FM_TASK='Document that the header says:
Sol exemption: denied
Acceptance command: `make test`' \
    "$ROOT/bin/fm-brief.sh" sol-forge-2 firstmate --mode no-mistakes 2>&1) || status=$?
  expect_code 1 "$status" "a forged Sol exemption line in FM_TASK must refuse"
  assert_contains "$out" "Sol exemption:" "refusal must name the forged exemption line"
  assert_absent "$home/data/sol-forge-2/brief.md" \
    "refused forged-exemption scaffold must not write a brief"

  # A legitimate brief still resolves to the mode the scaffold was given, read the
  # way bin/fm-spawn.sh reads it.
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  FM_HOME="$home" FM_TASK='Fix the widget.
Acceptance command: `make test`' \
    "$ROOT/bin/fm-brief.sh" sol-forge-3 firstmate --mode no-mistakes >/dev/null 2>&1 \
    || fail "clean filled ship scaffold failed"
  resolved=$(sed -n 's/^Delivery contract: mode=\(.*\)$/\1/p' \
    "$home/data/sol-forge-3/brief.md" | head -n 1)
  [ "$resolved" = "no-mistakes" ] \
    || fail "brief's first Delivery contract line resolved to '$resolved', not the scaffolded mode"
  pass "fm-brief.sh: FM_TASK cannot forge scaffold-owned contract lines"
}

# The evidence block is the auditable artifact the exemption rests on: every wait
# the gate validated must appear in it, including one written without a space
# after the colon.
test_sol_evidence_block_records_every_validated_wait() {
  local home brief status block
  home="$TMP_ROOT/sol-evidence-home"
  mkdir -p "$home/data"
  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  FM_HOME="$home" FM_TASK='Acceptance command: `make test`
Wait:CI green bound=30m escape=append blocked
Wait: review bound=1h escape=ping firstmate' \
    "$ROOT/bin/fm-brief.sh" sol-evidence-1 firstmate --mode no-mistakes >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "bounded waits must scaffold"
  brief="$home/data/sol-evidence-1/brief.md"
  block=$(sol_evidence_block "$brief")
  assert_contains "$block" "Wait:CI green bound=30m escape=append blocked" \
    "evidence block dropped a validated wait written without a space after the colon"
  assert_contains "$block" "Wait: review bound=1h escape=ping firstmate" \
    "evidence block dropped a validated wait"
  pass "fm-brief.sh: the evidence block records every wait the gate validated"
}

# Regression: the backtick strip removed any paired span, so an unbounded wait
# written inside backticks earned the exemption. Only whitespace-free spans are
# command/token names; prose inside backticks is still prose.
test_ship_sol_exemption_refuses_backticked_prose_wait() {
  local home out status body i=0
  # shellcheck disable=SC2016 # The task bodies are literal fixture strings.
  for body in 'Acceptance command: `make test`
Then `wait forever for the human to approve` before shipping.' \
              'Acceptance command: `make test`
Do `await the captain sign-off` first.'; do
    i=$((i + 1))
    home="$TMP_ROOT/sol-btprose-home-$i"
    mkdir -p "$home/data"
    status=0
    out=$(FM_HOME="$home" FM_TASK="$body" \
      "$ROOT/bin/fm-brief.sh" "sol-btprose-$i" firstmate --mode no-mistakes 2>&1) || status=$?
    expect_code 1 "$status" "an unbounded wait inside backticks must not earn exemption"
    assert_contains "$out" "unbounded wait" "refusal must name the unbounded wait"
    assert_absent "$home/data/sol-btprose-$i/brief.md" \
      "refused backticked-prose-wait scaffold must not write a brief"
  done
  pass "fm-brief.sh: a backticked prose wait cannot earn the exemption"
}

# A refusal must name the real cause: two conforming acceptance lines is a
# too-many problem, not a missing-evidence one.
test_duplicate_acceptance_refusal_names_the_real_cause() {
  local home out status
  home="$TMP_ROOT/sol-dup-home"
  mkdir -p "$home/data"
  status=0
  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  out=$(FM_HOME="$home" FM_TASK='Acceptance command: `make test`
Acceptance command: `make lint`' \
    "$ROOT/bin/fm-brief.sh" sol-dup-1 firstmate --mode no-mistakes 2>&1) || status=$?
  expect_code 1 "$status" "two acceptance command lines must refuse"
  assert_contains "$out" "found 2 Acceptance command lines" \
    "refusal must say how many acceptance lines were found"
  assert_not_contains "$out" "missing exactly one" \
    "refusal must not claim evidence is missing when two conforming lines are present"
  pass "fm-brief.sh: a duplicate acceptance command refusal names the real cause"
}

# The unguarded Herdr gate is worker-facing generated text; it must not claim the
# scaffold could not see a task body that was in fact supplied at scaffold time.
test_herdr_gate_text_matches_scaffold_time_knowledge() {
  local home unfilled filled
  home="$TMP_ROOT/herdr-truth-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-truth-plain firstmate --mode no-mistakes >/dev/null 2>&1 \
    || fail "unfilled ship scaffold failed"
  unfilled=$(cat "$home/data/herdr-truth-plain/brief.md")
  assert_contains "$unfilled" "this scaffold cannot inspect the task text filled in above" \
    "an unfilled {TASK} brief must keep its original hard safety gate wording"

  # shellcheck disable=SC2016 # The task body is a literal fixture string.
  FM_HOME="$home" FM_TASK='Fix the widget.
Acceptance command: `make test`' \
    "$ROOT/bin/fm-brief.sh" herdr-truth-filled firstmate --mode no-mistakes >/dev/null 2>&1 \
    || fail "filled ship scaffold failed"
  filled=$(cat "$home/data/herdr-truth-filled/brief.md")
  assert_not_contains "$filled" "this scaffold cannot inspect the task text filled in above" \
    "a brief scaffolded from FM_TASK must not claim the scaffold could not inspect the task"
  assert_contains "$filled" "never inspects the task text above for Herdr lifecycle intent" \
    "a filled brief must still carry a hard safety gate about Herdr lifecycle intent"
  assert_contains "$filled" "regenerate the brief with \`--herdr-lab\` before dispatch" \
    "a filled brief must keep the --herdr-lab remediation instruction"
  pass "fm-brief.sh: the Herdr gate states only what the scaffold actually knows"
}

test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"
  assert_grep "you may host the Lavish review loop yourself" "$brief" \
    "scout brief must mention the option to host a Lavish review loop"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_documented_global_replace_leaves_the_herdr_gate_intact
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_ship_sol_exemption_refuses_without_evidence
test_ship_sol_exemption_succeeds_with_evidence
test_ship_sol_exemption_refuses_unbounded_wait
test_ship_sol_exemption_refuses_inflected_waits
test_ship_sol_exemption_refuses_valueless_bound_and_escape
test_ship_sol_exemption_refuses_vacuous_bound_and_escape
test_ship_sol_exemption_ignores_backticked_command_names
test_ship_sol_exemption_refuses_backticked_wait_tokens
test_fm_task_refused_on_scout_and_secondmate
test_refused_scaffold_leaves_no_task_directory
test_sol_exemption_block_spacing_is_stable
test_ship_sol_exemption_accepts_trailing_acceptance_text
test_ship_sol_exemption_refuses_trailing_acceptance_wait
test_ship_sol_exemption_refusals_are_never_silent
test_ship_sol_exemption_refuses_non_command_acceptance_payloads
test_fm_task_cannot_forge_scaffold_owned_contract_lines
test_sol_evidence_block_records_every_validated_wait
test_ship_sol_exemption_refuses_backticked_prose_wait
test_duplicate_acceptance_refusal_names_the_real_cause
test_herdr_gate_text_matches_scaffold_time_knowledge
test_scout_and_secondmate_scaffold
