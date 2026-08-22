#!/usr/bin/env bash
# Drives an Android app through spec-test scenarios (JSON files translating a
# spec document's Given/When/Then blocks into concrete UI steps) on a real
# connected device, asserting on-screen state instead of narrating/recording.
#
# Why this exists, not just android-demo.sh: verifying a fix on-device by
# manually issuing adb/uiautomator commands one at a time (from an interactive
# agent session) is slow and burns a lot of tokens on the back-and-forth. This
# runs the whole scenario unattended and hands back one pass/fail report --
# the driving code is the SAME code android-demo.sh uses (android-ui-lib.sh),
# just pointed at assertions instead of narration.
#
# Not a Gherkin engine. A spec's Given/When/Then is a starting point you
# translate by hand into concrete steps -- most "Then" clauses map cleanly to
# a text/desc check, but some don't (tone/voice, cross-session state, an
# unbuilt UI element, a backend-only concern) and those stay manual/out of
# scope rather than being faked into a false pass.
#
# Usage:
#   ./android-spec-test.sh --app-id com.example.app --scenarios scenarios/ai-chat.json
#   ./android-spec-test.sh --app-id com.example.app --scenarios scenarios/  # every *.json in the dir, one aggregate report
#   ./android-spec-test.sh --app-id com.example.app --scenarios FILE --serial <serial>
#   ./android-spec-test.sh --app-id com.example.app --scenarios FILE --activity com.example.app/.MainActivity
#   ./android-spec-test.sh --app-id com.example.app --scenarios FILE --only "Parent starts from a suggested starter question"
#   ./android-spec-test.sh --app-id com.example.app --scenarios FILE --report results.json
#
# Requires on this machine: adb, jq. No ffmpeg/TTS -- this never records or narrates.
#
# SCENARIO FILE FORMAT: JSON array whose entries are either a runnable
# scenario { "name": str, "steps": [step, ...] } or a coverage placeholder
# with no "name" -- { "_skipped": "<spec scenario name>", "_why": "<reason>" }
# for a spec scenario this file deliberately doesn't automate, or { "_note":
# "..." } for a file-level caveat. Placeholders are never executed; they only
# count toward the coverage report below (see --report). Each runnable
# scenario runs independently (a failed step fails that scenario and moves to
# the next one, it does not abort the run) and always starts from whatever
# `steps` puts it in -- there is no shared setup/teardown, keep each
# scenario's own steps self-contained (pm_clear/launch/login as needed).
#
# COVERAGE + PASS/FAIL REPORT: every run prints a per-file table (available =
# implemented + skipped placeholders; implemented = runnable scenarios;
# passed/failed = this run's result on the implemented ones) plus a total
# row, and lists any failing scenario with its failed step id and error.
# --report FILE additionally writes the full detail as JSON: {summary,
# results: [{file, name, status, failed_step, error}], skipped: [{file,
# skipped, why}]}. Point --scenarios at a whole directory to get one report
# across every spec file in a single run.
#
# ENVIRONMENT: {{ENV:NAME}} substitution reads exported vars as usual; a .env
# next to the scenario file or directory (then one next to this script) is
# loaded first without clobbering anything already exported. The optional
# "seed_requests" action is app-specific and needs SEED_REQUESTS_SCRIPT set
# to a seeder invoked as "<script> <child_id> <domain...>"; prefer a plain
# exec step otherwise.
#
# Step actions: everything android-demo.sh supports (see its own --help),
# PLUS these assertions (all non-mutating, all fail the scenario if not met):
#   assert_text            text     - exact text visible now (single dump, no poll)
#   assert_text_eventually text, [max_attempts], [interval_seconds]
#                                   - exact text visible, polling (default
#                                     ~20s; raise both for a real network
#                                     round trip, e.g. a live agent reply)
#   assert_contains        text     - substring visible now
#   assert_desc             desc    - exact content-desc visible now
#   assert_desc_contains    text, [max_attempts], [interval_seconds]
#                                   - content-desc contains substring, polling
#                                     (e.g. an assistant reply whose suffix is
#                                     unknown ahead of time)
#   assert_gone             text    - exact text NOT visible now
#   assert_contains_gone    text    - no text containing this substring, now
#   assert_checked / assert_unchecked   text OR desc, [nth]
#                                   - a Switch/Toggle's own checked state, read
#                                     off the SAME node located by exact text or
#                                     content-desc (correct for a toggle row
#                                     built with mergeDescendants, wrong for a
#                                     Switch left unmerged from its label)
#   tap_desc_contains       text, [nth]  - like tap_desc but substring match,
#                                     for a content-desc with a variable part
#                                     (e.g. "Notifications, 20 unread")
#
# assert_text/assert_contains/assert_desc/assert_desc_contains/assert_gone/
# assert_contains_gone/assert_checked/assert_unchecked all run the same
# {{TIMESTAMP}}/{{ENV:NAME}} substitution `type` does, so an assertion can
# check for a value seeded earlier in the same scenario (e.g. the email typed
# at signup).
#   wait_gone   text [max_attempts] [interval_seconds]  - polls until text is
#                                     gone (e.g. a "Thinking..." indicator
#                                     clearing once a live backend reply lands)
#
# exec / if - host-side scripting and branching (same semantics as the
# android-demo.sh tool's own --help):
#   exec: run an external command on this machine and wait for it to finish.
#     command   required; the command text (supports {{TIMESTAMP}}/{{ENV:NAME}}).
#     shell     "bash" (default), "sh", or "lambda" (a jq filter, null input).
#     on_fail   "stop" (default) fails the scenario when the command exits
#               non-zero; "continue" logs it and moves on (still recorded for
#               a following if/source=last_command). DEMO_SERIAL, DEMO_APP_ID,
#               DEMO_ACTIVITY, DEMO_SCREEN_W, DEMO_SCREEN_H are exported to it.
#   if: run a sub-list of steps conditionally.
#     source    "last_command" (default, tests the most recent exec) or
#               "screen" (polls live device UI text).
#     expect        source=last_command only; "success" (default) or "fail".
#     output_equals/output_matches  source=last_command only; extra checks
#                   against the captured stdout (string / extended regex).
#     text          source=screen only; required, text to look for.
#     text_match    source=screen only; "contains" (default) or "exact".
#     equals/matches  source=screen only; extra checks on the found element's
#                     full text.
#     timeout_seconds  source=screen only; how long to poll (default: 8).
#     then, else    arrays of steps (may nest more ifs); at least one required.
set -uo pipefail  # not -e: a failed step must fail its OWN scenario, not the whole script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v adb >/dev/null 2>&1 || { echo "ERROR: adb not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH" >&2; exit 1; }

SERIAL=""
APP_ID=""
ACTIVITY_OVERRIDE=""
SCENARIOS_FILE=""
ONLY=""
REPORT=""

usage() { sed -n '2,110p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) shift; SERIAL="${1:-}" ;;
    --app-id) shift; APP_ID="${1:-}" ;;
    --activity) shift; ACTIVITY_OVERRIDE="${1:-}" ;;
    --scenarios) shift; SCENARIOS_FILE="${1:-}" ;;
    --only) shift; ONLY="${1:-}" ;;
    --report) shift; REPORT="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

[ -n "$SCENARIOS_FILE" ] || { echo "ERROR: --scenarios FILE_OR_DIR is required" >&2; exit 1; }
[ -e "$SCENARIOS_FILE" ] || { echo "ERROR: --scenarios path not found: $SCENARIOS_FILE" >&2; exit 1; }
# Each individual file is validated as a JSON array once SCENARIO_FILES is resolved, below.

[ -n "$APP_ID" ] || { echo "ERROR: no app specified; pass --app-id <package>" >&2; exit 1; }
case "$APP_ID" in
  */*) echo "ERROR: --app-id takes a bare package id (no '/'); pass the component separately with --activity" >&2; exit 1 ;;
esac

# Auto-load a .env next to the scenario file or directory (then one next to
# this script) for {{ENV:...}} substitution, without clobbering anything
# already exported.
load_env_file() {
  [ -f "$1" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|'#'*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done < "$1"
}
if [ -d "$SCENARIOS_FILE" ]; then
  load_env_file "${SCENARIOS_FILE%/}/.env"
else
  load_env_file "$(dirname "$SCENARIOS_FILE")/.env"
fi
load_env_file "${SCRIPT_DIR}/.env"

if [ -z "$SERIAL" ]; then
  DEVICES="$(adb devices | awk '$2 == "device" && $1 !~ /^emulator-/ {print $1}')"
  count="$(printf '%s\n' "$DEVICES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    echo "ERROR: no device connected over USB (adb devices shows nothing)" >&2
    exit 1
  elif [ "$count" -gt 1 ]; then
    echo "ERROR: $count devices connected; pass one with --serial:" >&2
    adb devices | tail -n +2 >&2
    exit 1
  fi
  SERIAL="$(printf '%s\n' "$DEVICES" | head -n 1)"
fi
ADB() { adb -s "$SERIAL" "$@"; }

# Resolve the launchable activity for APP_ID: explicit --activity wins;
# otherwise ask the package manager for the MAIN/LAUNCHER intent handler;
# fall back to the conventional ".MainActivity" if that comes up empty.
if [ -n "$ACTIVITY_OVERRIDE" ]; then
  case "$ACTIVITY_OVERRIDE" in
    */*) ACTIVITY="$ACTIVITY_OVERRIDE" ;;
    *)   ACTIVITY="${APP_ID}/${ACTIVITY_OVERRIDE}" ;;
  esac
else
  brief="$(ADB shell cmd package resolve-activity --brief \
            -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
            "$APP_ID" 2>/dev/null | tr -d '\r')"
  act="$(printf '%s\n' "$brief" | grep "^${APP_ID}/" | head -n 1)"
  [ -n "$act" ] || act="$(printf '%s\n' "$brief" | grep -m1 '/' || true)"
  ACTIVITY="${act:-${APP_ID}/.MainActivity}"
fi

WORKDIR="$(mktemp -d /tmp/android-spec-test-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
read -r SCREEN_W SCREEN_H < <(ADB shell wm size | grep -o '[0-9]\+x[0-9]\+' | tail -1 | tr 'x' ' ')
SCREEN_W="${SCREEN_W:-1080}"
SCREEN_H="${SCREEN_H:-2400}"

source "${SCRIPT_DIR}/android-ui-lib.sh"

# Context exported to exec-step commands (and visible as $ENV in lambda),
# same names as the general android_demo_maker tool uses.
export DEMO_SERIAL="$SERIAL" DEMO_APP_ID="$APP_ID" DEMO_ACTIVITY="$ACTIVITY" \
  DEMO_SCREEN_W="$SCREEN_W" DEMO_SCREEN_H="$SCREEN_H"

perform_action() {
  local action="$1" step="$2"
  case "$action" in
    launch)   ADB shell am force-stop "$APP_ID"; ADB shell am start -n "$ACTIVITY" >/dev/null ;;
    reopen)   ADB shell am start -n "$ACTIVITY" >/dev/null ;;
    pm_clear) ADB shell pm clear "$APP_ID" >/dev/null ;;
    tap_text)
      find_and_tap_text "$(jq -r '.text' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      maybe_type "$step"
      ;;
    tap_contains)
      find_and_tap_contains "$(jq -r '.text' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      maybe_type "$step"
      ;;
    tap_desc)
      find_and_tap_desc "$(jq -r '.desc' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      maybe_type "$step"
      ;;
    tap_desc_contains)
      find_and_tap_desc_contains "$(jq -r '.text' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      maybe_type "$step"
      ;;
    tap_until_gone)
      tap_until_gone "$(jq -r '.text' <<<"$step")" "$(jq -r '.watch_for' <<<"$step")" "$(jq -r '.max_attempts // 15' <<<"$step")" "$(jq -r '.interval_seconds // 3' <<<"$step")"
      ;;
    tap_left_of_contains)
      find_and_tap_left_of_contains "$(jq -r '.text' <<<"$step")" "$(jq -r '.offset_x // 59' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    swipe_up_from_contains)
      find_and_swipe_up_from_contains "$(jq -r '.text' <<<"$step")" "$(jq -r '.delta_y // 500' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    swipe_until_contains)
      find_and_tap_after_scrolling "$(jq -r '.text' <<<"$step")" "$(jq -r '.max_swipes // 6' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    tap_xy)
      ADB shell input tap "$(jq -r '.x' <<<"$step")" "$(jq -r '.y' <<<"$step")"
      maybe_type "$step"
      ;;
    dismiss_keyboard) ADB shell input keyevent 111 ;;
    back)             ADB shell input keyevent KEYCODE_BACK ;;
    home_button)      ADB shell input keyevent KEYCODE_HOME ;;
    pause)            : ;;  # the per-step settle_ms sleep in the runner loop below provides the dwell
    assert_signed_in) assert_signed_in ;;
    seed_requests)
      local child_id domains=() d
      child_id="$(jq -r '.child_id // empty' <<<"$step")"
      while IFS= read -r d; do domains+=("$d"); done < <(jq -r '.domains[]?' <<<"$step")
      if [ -z "${SEED_REQUESTS_SCRIPT:-}" ]; then
        echo "ERROR: seed_requests is app-specific; set SEED_REQUESTS_SCRIPT=<path> (invoked as \"<path> <child_id> <domain...>\") or use an exec step instead" >&2
        return 1
      fi
      if [ "${#domains[@]}" -gt 0 ]; then
        "$SEED_REQUESTS_SCRIPT" "$child_id" "${domains[@]}"
      else
        "$SEED_REQUESTS_SCRIPT" "$child_id"
      fi
      ;;
    swipe)
      local dir cx y1 y2
      dir="$(jq -r '.direction' <<<"$step")"
      cx=$(( SCREEN_W / 2 ))
      if [ "$dir" = "up" ]; then y1=$(( SCREEN_H * 70 / 100 )); y2=$(( SCREEN_H * 30 / 100 ))
      else y1=$(( SCREEN_H * 30 / 100 )); y2=$(( SCREEN_H * 70 / 100 )); fi
      ADB shell input swipe "$cx" "$y1" "$cx" "$y2" 400
      ;;
    assert_text)
      local text; text="$(substitute_templates "$(jq -r '.text' <<<"$step")")" || return 1
      dump_ui
      grep -qF "text=\"${text}\"" "$WORKDIR/dump.xml" \
        || { echo "ERROR: expected text \"${text}\" not found" >&2; return 1; }
      ;;
    assert_text_eventually)
      local text bounds; text="$(substitute_templates "$(jq -r '.text' <<<"$step")")" || return 1
      bounds="$(POLL_MAX_ATTEMPTS="$(jq -r '.max_attempts // 25' <<<"$step")" \
        POLL_INTERVAL_SECONDS="$(jq -r '.interval_seconds // 0.8' <<<"$step")" \
        poll_bounds _bounds_for_text "$text" "$(jq -r '.nth // 1' <<<"$step")")"
      [ -n "$bounds" ] || { echo "ERROR: expected text \"${text}\" never appeared" >&2; return 1; }
      ;;
    assert_contains)
      local text bounds; text="$(substitute_templates "$(jq -r '.text' <<<"$step")")" || return 1
      dump_ui
      bounds="$(_bounds_for_contains "$text" "$(jq -r '.nth // 1' <<<"$step")")"
      [ -n "$bounds" ] || { echo "ERROR: expected text containing \"${text}\" not found" >&2; return 1; }
      ;;
    assert_desc)
      local desc; desc="$(substitute_templates "$(jq -r '.desc' <<<"$step")")" || return 1
      dump_ui
      grep -qF "content-desc=\"${desc}\"" "$WORKDIR/dump.xml" \
        || { echo "ERROR: expected content-desc \"${desc}\" not found" >&2; return 1; }
      ;;
    assert_desc_contains)
      local text bounds; text="$(substitute_templates "$(jq -r '.text' <<<"$step")")" || return 1
      bounds="$(POLL_MAX_ATTEMPTS="$(jq -r '.max_attempts // 25' <<<"$step")" \
        POLL_INTERVAL_SECONDS="$(jq -r '.interval_seconds // 0.8' <<<"$step")" \
        poll_bounds _bounds_for_desc_contains "$text" "$(jq -r '.nth // 1' <<<"$step")")"
      [ -n "$bounds" ] || { echo "ERROR: expected content-desc containing \"${text}\" never appeared" >&2; return 1; }
      ;;
    assert_gone)
      local text; text="$(substitute_templates "$(jq -r '.text' <<<"$step")")" || return 1
      dump_ui
      if grep -qF "text=\"${text}\"" "$WORKDIR/dump.xml"; then
        echo "ERROR: expected text \"${text}\" to be gone, still present" >&2; return 1
      fi
      ;;
    assert_contains_gone)
      local text bounds; text="$(substitute_templates "$(jq -r '.text' <<<"$step")")" || return 1
      dump_ui
      bounds="$(_bounds_for_contains "$text" "$(jq -r '.nth // 1' <<<"$step")")"
      if [ -n "$bounds" ]; then
        echo "ERROR: expected no text containing \"${text}\", but found one" >&2; return 1
      fi
      ;;
    assert_checked|assert_unchecked)
      local text desc nth state expected
      text="$(jq -r '.text // empty' <<<"$step")"
      desc="$(jq -r '.desc // empty' <<<"$step")"
      nth="$(jq -r '.nth // 1' <<<"$step")"
      expected="true"; [ "$action" = "assert_unchecked" ] && expected="false"
      if [ -n "$text" ]; then
        state="$(_checked_for_text "$(substitute_templates "$text")" "$nth")"
      elif [ -n "$desc" ]; then
        state="$(_checked_for_desc "$(substitute_templates "$desc")" "$nth")"
      else
        echo "ERROR: ${action} requires a \"text\" or \"desc\" field" >&2; return 1
      fi
      [ -n "$state" ] || { echo "ERROR: ${action}: no checkable element found for text/desc \"${text}${desc}\"" >&2; return 1; }
      [ "$state" = "$expected" ] || { echo "ERROR: ${action}: expected checked=${expected}, found checked=${state}" >&2; return 1; }
      ;;
    wait_gone)
      wait_gone "$(jq -r '.text' <<<"$step")" "$(jq -r '.max_attempts // 20' <<<"$step")" "$(jq -r '.interval_seconds // 3' <<<"$step")"
      ;;
    exec)
      do_exec_step "$step"
      ;;
    *)
      echo "ERROR: unknown action '$action' - see --help" >&2
      return 1
      ;;
  esac
}

# run_step_list <json-array> <id-prefix> - walks a scenario's steps in order.
# An "if" step evaluates its condition (via eval_condition, shared with
# android-demo.sh) and recurses into just the taken branch; anything else
# (including "exec") runs through perform_action. Sets RUN_FAILED_ID/
# RUN_FAILED_ACTION/RUN_FAILED_ERROR and returns 1 on the first failure --
# nested ids look like "3.t.1" (step 3's then-branch, its 2nd step), same
# convention android-demo.sh uses so a failure is easy to find in the file.
RUN_FAILED_ID=""
RUN_FAILED_ACTION=""
RUN_FAILED_ERROR=""
run_step_list() {
  local arr="$1" prefix="$2"
  local n i step action id settle_ms out rc branch

  n="$(jq 'length' <<<"$arr")"
  for ((i = 0; i < n; i++)); do
    step="$(jq -c ".[$i]" <<<"$arr")"
    action="$(jq -r '.action' <<<"$step")"
    id="${prefix}${i}"

    if [ "$action" = "if" ]; then
      echo "  -- step ${id}: if"
      rc=0
      out="$(eval_condition "$step" 2>&1)" || rc=$?
      [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/     /'
      case "$rc" in
        0) branch="then"; echo "     (condition met -> then-branch)" ;;
        1) branch="else"; echo "     (condition not met -> else-branch)" ;;
        *)
          RUN_FAILED_ID="$id"; RUN_FAILED_ACTION="if"; RUN_FAILED_ERROR="$out"
          echo "  !! FAILED at step ${id} (if): ${out}" >&2
          return 1
          ;;
      esac
      run_step_list "$(jq -c ".${branch} // []" <<<"$step")" "${id}.${branch:0:1}." || return 1
      continue
    fi

    if [ "$action" = "exec" ]; then
      # Run directly, NOT through a $(...) capture: do_exec_step sets
      # LAST_EXEC_STATUS/LAST_EXEC_OUTPUT as globals for a following if step
      # to read, and a command substitution would run it in a subshell,
      # discarding those before this function's caller ever sees them. Its
      # own echoes already print the command/output/exit status live.
      echo "  -- step ${id}: exec"
      if ! perform_action "exec" "$step"; then
        RUN_FAILED_ID="$id"; RUN_FAILED_ACTION="exec"
        RUN_FAILED_ERROR="exec command failed (exit ${LAST_EXEC_STATUS:-?}); see console output above"
        return 1
      fi
      settle_ms="$(jq -r '.settle_ms // 600' <<<"$step")"
      sleep "$(awk -v ms="$settle_ms" 'BEGIN{printf "%.3f", ms/1000}')"
      continue
    fi

    echo "  -- step ${id}: ${action}"
    if ! out="$(perform_action "$action" "$step" 2>&1)"; then
      RUN_FAILED_ID="$id"; RUN_FAILED_ACTION="$action"; RUN_FAILED_ERROR="$out"
      echo "  !! FAILED at step ${id} (${action}): ${out}" >&2
      return 1
    fi
    # A tap that fires before the previous screen transition/animation finishes
    # can land on stale bounds (the next dump_ui races the UI actually
    # updating), not just look visually abrupt -- same reason android-demo.sh
    # dwells after every action.
    settle_ms="$(jq -r '.settle_ms // 600' <<<"$step")"
    sleep "$(awk -v ms="$settle_ms" 'BEGIN{printf "%.3f", ms/1000}')"
  done
  return 0
}

# Resolve --scenarios to a sorted list of scenario files: itself if it's a
# file, or every *.json inside it (one level, not recursive) if it's a
# directory -- so a whole-suite run/report is just `--scenarios
# android-spec-tests/` instead of one invocation per file.
SCENARIO_FILES=()
if [ -d "$SCENARIOS_FILE" ]; then
  while IFS= read -r f; do SCENARIO_FILES+=("$f"); done < <(find "$SCENARIOS_FILE" -maxdepth 1 -name '*.json' | sort)
  [ "${#SCENARIO_FILES[@]}" -gt 0 ] || { echo "ERROR: no *.json files found in $SCENARIOS_FILE" >&2; exit 1; }
else
  SCENARIO_FILES=("$SCENARIOS_FILE")
fi

RESULTS_JSON="[]"
SKIPPED_JSON="[]"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a FILE_NAMES FILE_IMPLEMENTED FILE_SKIPPED FILE_PASSED FILE_FAILED

for sf in "${SCENARIO_FILES[@]}"; do
  jq -e 'type == "array"' "$sf" >/dev/null || { echo "ERROR: $sf is not a JSON array" >&2; exit 1; }
  fname="$(basename "$sf")"
  entry_count="$(jq 'length' "$sf")"
  f_implemented=0 f_skipped=0 f_passed=0 f_failed=0

  echo ""
  echo "==> $(basename "$sf"): ${entry_count} entries, device $SERIAL ($APP_ID)"

  for i in $(seq 0 $((entry_count - 1))); do
    entry="$(jq -c ".[$i]" "$sf")"

    # An entry with no "name" is a coverage placeholder ({"_skipped": ...,
    # "_why": ...} or {"_note": ...}), not a runnable scenario -- record it
    # for the report, never execute it.
    if [ "$(jq 'has("name")' <<<"$entry")" != "true" ]; then
      f_skipped=$((f_skipped + 1))
      SKIP_COUNT=$((SKIP_COUNT + 1))
      label="$(jq -r '._skipped // "_note"' <<<"$entry")"
      why="$(jq -r '._why // .["_note"] // empty' <<<"$entry")"
      SKIPPED_JSON="$(jq -c --arg file "$fname" --arg label "$label" --arg why "$why" \
        '. + [{file: $file, skipped: $label, why: $why}]' <<<"$SKIPPED_JSON")"
      continue
    fi

    name="$(jq -r '.name' <<<"$entry")"
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
      continue
    fi
    f_implemented=$((f_implemented + 1))

    echo ""
    echo "=== ${fname}: ${name}"

    RUN_FAILED_ID=""; RUN_FAILED_ACTION=""; RUN_FAILED_ERROR=""
    if run_step_list "$(jq -c '.steps' <<<"$entry")" ""; then
      status="PASS"; failed_step=""; error_msg=""
      f_passed=$((f_passed + 1)); PASS_COUNT=$((PASS_COUNT + 1))
      echo "  => PASS"
    else
      status="FAIL"; failed_step="${RUN_FAILED_ID} (${RUN_FAILED_ACTION})"; error_msg="$RUN_FAILED_ERROR"
      f_failed=$((f_failed + 1)); FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  => FAIL"
    fi

    RESULTS_JSON="$(jq -c --arg file "$fname" --arg name "$name" --arg status "$status" \
      --arg step "$failed_step" --arg err "$error_msg" \
      '. + [{file: $file, name: $name, status: $status, failed_step: $step, error: $err}]' <<<"$RESULTS_JSON")"
  done

  FILE_NAMES+=("$fname")
  FILE_IMPLEMENTED+=("$f_implemented")
  FILE_SKIPPED+=("$f_skipped")
  FILE_PASSED+=("$f_passed")
  FILE_FAILED+=("$f_failed")
done

# ---- Coverage + pass/fail report -------------------------------------------
# "Available" = every spec scenario this file accounts for, run or not
# (implemented + skipped placeholders); "implemented" = the subset actually
# converted to runnable steps. Distinct from PASS/FAIL, which only applies to
# implemented scenarios that were actually run this invocation (skipped by
# --only doesn't count against either).
echo ""
echo "==> Coverage + result summary"
printf '%-40s %10s %10s %8s %8s\n' "FILE" "AVAILABLE" "IMPLEMENTED" "PASSED" "FAILED"
for idx in "${!FILE_NAMES[@]}"; do
  avail=$(( FILE_IMPLEMENTED[idx] + FILE_SKIPPED[idx] ))
  printf '%-40s %10s %10s %8s %8s\n' "${FILE_NAMES[$idx]}" "$avail" "${FILE_IMPLEMENTED[$idx]}" "${FILE_PASSED[$idx]}" "${FILE_FAILED[$idx]}"
done
TOTAL_AVAILABLE=$(( PASS_COUNT + FAIL_COUNT + SKIP_COUNT ))
printf '%-40s %10s %10s %8s %8s\n' "TOTAL" "$TOTAL_AVAILABLE" "$((PASS_COUNT + FAIL_COUNT))" "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "==> Failing scenarios:"
  jq -r '.[] | select(.status == "FAIL") | "  - [\(.file)] \(.name) -- failed at step \(.failed_step): \(.error)"' <<<"$RESULTS_JSON"
fi

if [ -n "$REPORT" ]; then
  jq -n --argjson results "$RESULTS_JSON" --argjson skipped "$SKIPPED_JSON" \
    --argjson pass "$PASS_COUNT" --argjson fail "$FAIL_COUNT" --argjson skip "$SKIP_COUNT" \
    '{summary: {available: ($pass + $fail + $skip), implemented: ($pass + $fail), passed: $pass, failed: $fail, skipped: $skip},
      results: $results, skipped: $skipped}' > "$REPORT"
  echo "==> Report written to $REPORT"
fi

[ "$FAIL_COUNT" -eq 0 ]
