#!/usr/bin/env bash
# Drives any Android app through a scripted product-tour demo on a real
# connected device, narrates it with text-to-speech (macOS `say` or local
# Piper neural TTS), records the screen, and muxes narration + video into
# one MP4.
#
# App-agnostic: point it at any installed package with --app-id. The launch
# activity is auto-resolved from the package's MAIN/LAUNCHER intent filter;
# override it with --activity if the app has more than one launcher entry.
#
# The tour itself (which screens, in what order, what gets said) lives in a
# steps JSON file, not in this script; edit that file to change the demo.
# See the "STEP FILE FORMAT" section below for the schema.
#
# Safety invariant: a shipped step file should only mutate data it created
# itself in the same run (a throwaway account, records the demo seeds and
# then cleans up). It never touches pre-existing user data beyond things it
# seeded moments earlier. Keep that spirit if you extend it: this is a demo
# tool, not a fuzzer for a real account.
#
# Precondition: just the app installed and a device connected. A steps file
# can start from a clean slate itself (pm_clear, see action list below) and
# log in with credentials supplied through {{ENV:...}} substitution; export
# those variables yourself, or put them in a .env file sitting next to the
# steps file or next to this script (auto-loaded without overwriting
# anything you already exported).
#
# Usage:
#   ./android-demo.sh --app-id com.example.myapp      # full pipeline: drive + record + narrate + mux
#   ./android-demo.sh --serial <serial>               # target a specific device (auto-picked if only one is connected)
#   ./android-demo.sh --activity com.example.myapp.MainActivity   # override the launch activity (auto-resolved by default)
#   ./android-demo.sh --steps my-steps.json           # use a different step file
#   ./android-demo.sh --tts say                       # use macOS `say` instead of the default Piper neural TTS
#   ./android-demo.sh --tts piper                     # local Piper neural TTS (the default): much less robotic
#   ./android-demo.sh --tts piper --piper-model /path/to/voice.onnx   # a different downloaded Piper voice
#   ./android-demo.sh --voice Ava                     # (--tts say only) override the `say` voice (default: Samantha)
#   ./android-demo.sh --rate 180                      # (--tts say only) override the `say` speaking rate, words per minute
#   ./android-demo.sh --out demo.mp4                  # output path (default: ./android-demo-<timestamp>.mp4)
#   ./android-demo.sh --segment-seconds 150           # screenrecord segment length before an automatic cut+restart
#   ./android-demo.sh --dry-run                       # just drive the UI with short fixed pauses, no recording or narration: for testing step targets
#   ./android-demo.sh --no-narration                  # record video only, silent, skip all TTS/audio work
#   ./android-demo.sh --keep-workdir                  # don't delete the temp working directory (per-step audio/video) when done
#   ./android-demo.sh --loose                         # restore the old spaced-out pacing; default packs narration against the action
#
# Requires on this machine: adb, jq, and a TTS engine: local Piper neural
# TTS (the default; https://github.com/rhasspy/piper, noticeably more
# natural, fully offline once a voice model is downloaded) or macOS `say`
# (--tts say). ffmpeg (+ffprobe) is additionally
# required unless --dry-run or --no-narration is used. Piper voice models
# live under piper-voices/ next to this script, if you keep one there; get
# more from https://huggingface.co/rhasspy/piper-voices.
#
# STEP FILE FORMAT (JSON array, one object per step, in order):
#   action        one of: launch, reopen, pm_clear, tap_text, tap_contains,
#                 tap_contains_optional, tap_until_gone, tap_desc,
#                 tap_left_of_contains, swipe_up_from_contains,
#                 swipe_element, swipe_until_contains, long_press,
#                 double_tap, drag_and_drop, tap_xy, back, home_button,
#                 pause, swipe, dismiss_keyboard, assert_text, exec, if
#   text          exact (tap_text, assert_text) or substring
#                 (tap_contains, tap_contains_optional, tap_left_of_contains,
#                 swipe_up_from_contains) match against a uiautomator
#                 text="..." attribute; required for those actions.
#                 tap_contains_optional never fails the step if not found:
#                 use it for recovering from a transient/optional UI state
#                 (e.g. an in-app "Retry" button) without blocking the happy
#                 path where it never appears
#   offset_x      tap_left_of_contains only; device pixels to the left of the
#                 matched text's own left edge (default: 59). For a control
#                 (e.g. a checkbox) with no text/desc of its own that sits
#                 just left of a label: anchors wherever the label actually
#                 is instead of a hardcoded coordinate, so it survives the
#                 label shifting position between builds
#   delta_y       swipe_up_from_contains only; device pixels to swipe up by,
#                 starting from the matched text's own position (default:
#                 500). For scrolling a clipped scroll container (e.g. a
#                 form) so a lower field becomes tappable: dismiss_keyboard
#                 alone can leave it clipped out of view with no error, so a
#                 fixed coordinate tap on it can silently miss
#   contains      long_press/double_tap locator: SUBSTRING of the text
#                 attribute to press (checked only when "text" is absent)
#   duration_ms   long_press/double_tap hold length and drag length in ms.
#                 long_press default 1000 (keep >= ~600 so the hold clears
#                 the framework's ~500ms long-click timeout); drag_and_drop
#                 default 800. On `swipe` it is the gesture speed (default
#                 400)
#   delta         swipe_element only; pixels to swipe from the matched
#                 element's center in `direction` (default: 500)
#   direction     swipe_element/swipe: "up", "down", "left", or "right".
#                 swipe_element starts at the matched text's own center;
#                 plain `swipe` crosses the screen center (default: up)
#   from_text     drag_and_drop only; substring locating the dragged element
#                 (required). from_nth is its 1-based match index
#   to_text       drag_and_drop drop target: substring of the target's text.
#                 Exactly one of to_text / to_desc / x+y is required
#   to_desc       drag_and_drop drop target: exact content-desc instead
#   watch_for     tap_until_gone only; exact text whose presence means we
#                 haven't moved on yet; required for that action
#   max_attempts  tap_until_gone only; how many tap+wait cycles before giving
#                 up (default: 15)
#   interval_seconds  tap_until_gone only; seconds between tap attempts
#                 (default: 3)
#   nth           1-based, which match to use when more than one element has
#                 the same text (default: 1; also used by if/source=screen)
#   desc          exact match against a content-desc="..." attribute;
#                 required for tap_desc
#   x, y          required for tap_xy; raw device pixel coordinates (last
#                 resort: prefer tap_text/tap_contains/tap_desc/
#                 tap_left_of_contains, which survive layout shifts; use this
#                 only for fields with no stable text, like a password
#                 EditText)
#   type          optional on tap_text/tap_contains/tap_xy; after the tap,
#                 types this text into the now-focused field. Supports two
#                 template tokens: {{TIMESTAMP}} (unix seconds, so repeat
#                 runs don't collide on a unique-email-style field) and
#                 {{ENV:NAME}} (the environment variable NAME, auto-loaded
#                 from .env next to the steps file if present, see above)
#   max_swipes    swipe_until_contains only; cap on how many times to swipe
#                 up looking for the text before giving up (default: 6)
#   settle_ms     how long (ms) to let the UI animate/settle after the action
#                 fires, before narration for this step starts (default: 600)
#   narration     text to speak for this step (optional; omit for a silent
#                 beat). Every step's on-screen dwell time is at least this
#                 line's spoken length, so video and narration stay in sync.
#
#   exec: run an external command on this machine and wait for it to finish.
#   command       required; the command text. Multiline is fine (newlines
#                 preserved). Supports the same {{TIMESTAMP}}/{{ENV:NAME}}
#                 template tokens as type.
#   shell         "bash" (default), "sh", or "lambda". bash/sh run the
#                 command through that interpreter's stdin; lambda runs it
#                 as a jq filter with null input (jq is already required),
#                 so string/math/JSON munging works without a real shell;
#                 whatever it prints is the captured output and its exit
#                 status is the command's. The command's stdout+stderr is
#                 echoed (first few lines) and its exit status remembered:
#                 a following if step with source last_command can branch
#                 on both. DEMO_SERIAL, DEMO_APP_ID, DEMO_ACTIVITY,
#                 DEMO_SCREEN_W and DEMO_SCREEN_H are exported to the
#                 command (in lambda they sit under $ENV).
#   on_fail       exec only; "stop" (default) aborts the whole demo when
#                 the command exits non-zero, "continue" logs the failure
#                 and moves on (the recorded status still reflects the
#                 failure for if).
#
#   if: run a sub-context of demo steps conditionally.
#   source        "last_command" (default) tests the most recent exec step;
#                 "screen" polls live device UI text.
#   expect        source=last_command only; "success" (default) requires
#                 exit 0, "fail" requires non-zero. Before any exec has
#                 run, success is false and fail is false.
#   output_equals   source=last_command only; exact string the captured
#                 stdout must equal (optional extra constraint).
#   output_matches  source=last_command only; extended regex the captured
#                 stdout must match (optional extra constraint).
#   text          source=screen only; required. Text to look for on screen,
#                 interpreted per text_match ("contains", default, or
#                 "exact") against uiautomator text attributes.
#   equals        source=screen only; optional extra constraint that the
#                 found element's full (entity-unescaped) text equals it.
#   matches       source=screen only; optional extended-regex check against
#                 the found element's full text.
#   timeout_seconds  source=screen only; how long to poll for the text
#                 before deciding the condition is false (default: 8).
#   then, else    JSON arrays of steps (same schema; may nest more ifs) run
#                 when the condition holds / fails. At least one required;
#                 the untaken branch costs nothing at runtime. Narration
#                 inside branches works exactly like top-level steps.
#
# `launch` force-stops and cold-starts the app under test (use once, as
# step 1, or after pm_clear). `reopen` just foregrounds it again (use after
# home_button, to show resuming). `pm_clear` wipes the app's local
# data/session (not any backend account); use it to force a logged-out state
# partway through a manifest, e.g. to switch accounts mid-tour.
# `assert_text` aborts with a clear error if the expected text never appears
# (polling ~20s through slow loads), e.g. insert one after a login step as a
# signed-in guard. `exec` and `if` add host-side scripting and branching; see
# their field docs above.
#
# Gestures: `long_press` and `double_tap` locate their target by exact
# "text", "contains" (substring), or "desc", falling back to raw x+y
# coordinates; `swipe_element` swipes from a matched element's center in any
# direction (so the gesture stays inside the right pager/carousel even when
# the layout shifts); `drag_and_drop` drags one element onto another (or
# onto raw coordinates for unlabeled drop zones); plain `swipe` now covers
# all four screen directions with an optional duration_ms.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v adb >/dev/null 2>&1 || { echo "ERROR: adb not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH" >&2; exit 1; }

SERIAL=""
APP_ID=""
ACTIVITY_OVERRIDE=""
STEPS_FILE=""
TTS_ENGINE="piper"
VOICE="Samantha"
RATE=""
PIPER_MODEL="${SCRIPT_DIR}/piper-voices/en_US-hfc_female-medium.onnx"
PIPER_BIN=""
OUT=""
SEGMENT_SECONDS=170
DRY_RUN=0
NO_NARRATION=0
KEEP_WORKDIR=0

usage() {
  # Print the leading comment block (everything after the shebang until the
  # first non-comment line), stripped of the "# " prefix.
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) shift; SERIAL="${1:-}" ;;
    --app-id) shift; APP_ID="${1:-}" ;;
    --activity) shift; ACTIVITY_OVERRIDE="${1:-}" ;;
    --steps) shift; STEPS_FILE="${1:-}" ;;
    --tts) shift; TTS_ENGINE="${1:-}" ;;
    --voice) shift; VOICE="${1:-}" ;;
    --rate) shift; RATE="${1:-}" ;;
    --piper-model) shift; PIPER_MODEL="${1:-}" ;;
    --piper-bin) shift; PIPER_BIN="${1:-}" ;;
    --out) shift; OUT="${1:-}" ;;
    --segment-seconds) shift; SEGMENT_SECONDS="${1:-}" ;;
    --dry-run) DRY_RUN=1 ;;
    --no-narration) NO_NARRATION=1 ;;
    --keep-workdir) KEEP_WORKDIR=1 ;;
    --loose) TIGHT_OPT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$TTS_ENGINE" in
  say|piper) ;;
  *) echo "ERROR: invalid --tts '$TTS_ENGINE' (expected say or piper)" >&2; exit 1 ;;
esac

[ -n "$APP_ID" ] || { echo "ERROR: no app specified; pass --app-id <package>" >&2; exit 1; }
case "$APP_ID" in
  */*) echo "ERROR: --app-id takes a bare package id (no '/'); pass the component separately with --activity" >&2; exit 1 ;;
esac

[ -n "$STEPS_FILE" ] || STEPS_FILE="${SCRIPT_DIR}/android-demo-steps.json"
[ -f "$STEPS_FILE" ] || { echo "ERROR: step file not found: $STEPS_FILE" >&2; exit 1; }
jq -e 'type == "array"' "$STEPS_FILE" >/dev/null || { echo "ERROR: $STEPS_FILE is not a JSON array" >&2; exit 1; }

# Auto-load a .env next to the steps file (then one next to this script) for
# {{ENV:...}} substitution, without clobbering anything already exported.
load_env_file() {
  [ -f "$1" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|'#'*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done < "$1"
}
load_env_file "$(dirname "$STEPS_FILE")/.env"
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
SERIALS=("$SERIAL" "")
DEVICE_COUNT=1

# Resolve the launchable activity for APP_ID: explicit --activity wins;
# otherwise ask the package manager for the MAIN/LAUNCHER intent handler;
# fall back to the conventional ".MainActivity" if that comes up empty.
# Asked with a literal adb -s because the library that owns ADB() is sourced
# below, after the screen size is read.
if [ -n "$ACTIVITY_OVERRIDE" ]; then
  case "$ACTIVITY_OVERRIDE" in
    */*) ACTIVITY="$ACTIVITY_OVERRIDE" ;;
    *)   ACTIVITY="${APP_ID}/${ACTIVITY_OVERRIDE}" ;;
  esac
else
  brief="$(adb -s "$SERIAL" shell cmd package resolve-activity --brief \
            -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
            "$APP_ID" 2>/dev/null | tr -d '\r')"
  act="$(printf '%s\n' "$brief" | grep "^${APP_ID}/" | head -n 1)"
  [ -n "$act" ] || act="$(printf '%s\n' "$brief" | grep -m1 '/' || true)"
  ACTIVITY="${act:-${APP_ID}/.MainActivity}"
fi

if [ "$NO_NARRATION" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg not found on PATH" >&2; exit 1; }
  command -v ffprobe >/dev/null 2>&1 || { echo "ERROR: ffprobe not found on PATH (ships with ffmpeg)" >&2; exit 1; }
  if [ "$TTS_ENGINE" = "say" ]; then
    command -v say >/dev/null 2>&1 || { echo "ERROR: \`say\` not found; the say TTS engine is macOS-only (try --tts piper)" >&2; exit 1; }
  else
    # piper is commonly installed under a specific pyenv/venv Python where the
    # bare command isn't on PATH in every shell; check explicit --piper-bin
    # first, then PATH, then the newest pyenv install that has it, before
    # giving up.
    if [ -n "$PIPER_BIN" ]; then
      [ -x "$PIPER_BIN" ] || { echo "ERROR: --piper-bin '$PIPER_BIN' is not executable" >&2; exit 1; }
    elif command -v piper >/dev/null 2>&1 && piper --help >/dev/null 2>&1; then
      PIPER_BIN="$(command -v piper)"
    else
      PIPER_BIN="$(ls -1 "$HOME"/.pyenv/versions/*/bin/piper 2>/dev/null | tail -1)"
      [ -n "$PIPER_BIN" ] || {
        echo "ERROR: piper binary not found. Install it (pip install piper-tts) or pass --piper-bin /path/to/piper" >&2
        exit 1
      }
    fi
    [ -f "$PIPER_MODEL" ] || { echo "ERROR: Piper voice model not found: $PIPER_MODEL (download one from https://huggingface.co/rhasspy/piper-voices, or pass --piper-model)" >&2; exit 1; }
    PIPER_CONFIG="${PIPER_MODEL}.json"
    [ -f "$PIPER_CONFIG" ] || { echo "ERROR: Piper voice config not found: $PIPER_CONFIG (should sit next to the .onnx model)" >&2; exit 1; }
  fi
fi

[ -n "$OUT" ] || OUT="${SCRIPT_DIR}/android-demo-$(date +%Y%m%d-%H%M%S).mp4"
case "$OUT" in
  *.mp4) ;;
  *) echo "ERROR: --out must be an .mp4 file path (got directory or other: $OUT)" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$OUT")"

WORKDIR="$(mktemp -d /tmp/android-demo-XXXXXX)"

# The driving primitives (uiautomator lookup, gestures, exec, condition
# evaluation, device hygiene) live in android-ui-lib.sh, shared with
# android-spec-test.sh so both drive the UI the exact same way. This file
# only adds what is specific to a narrated recording: the beat clock, the
# screenrecord segment pump, and the TTS pipeline. The library owns ADB() and
# reads WORKDIR and SCREEN_W/SCREEN_H when its functions run, never at source
# time: WORKDIR is set above, the screen size just below.
source "${SCRIPT_DIR}/android-ui-lib.sh"

# ---------------------------------------------------------------- device hygiene
# Auto-rotate belongs to whoever owns the device, not to this run. `adb shell
# monkey -p <pkg> -c android.intent.category.LAUNCHER 1` turns it ON and never
# puts it back (monkey thaws rotation during its own setup). Snapshot the
# setting before any step can move it and restore it in cleanup().
autorotate_snapshot

# Muted for the recording itself, not dry-run (no sound/video is captured there, and a
# banner is harmless to a fixed-pause dry run). zen_mode 2 = total silence (blocks even
# alarms); restored to whatever the device had before, not hardcoded back to 0, so a
# user who already had their own DND setting doesn't lose it.
ORIGINAL_ZEN_MODE=""
if [ "$DRY_RUN" -eq 0 ]; then
  ORIGINAL_ZEN_MODE="$(ADB shell settings get global zen_mode 2>/dev/null | tr -d '\r')"
  ADB shell cmd notification set_dnd on >/dev/null 2>&1 || true
fi

cleanup() {
  command -v autorotate_restore >/dev/null 2>&1 && autorotate_restore
  if [ -n "$ORIGINAL_ZEN_MODE" ]; then
    ADB shell settings put global zen_mode "$ORIGINAL_ZEN_MODE" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_WORKDIR" -eq 1 ]; then
    echo "==> Keeping workdir: $WORKDIR" >&2
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT
mkdir -p "$WORKDIR/audio" "$WORKDIR/video"

read -r SCREEN_W SCREEN_H < <(ADB shell wm size | grep -o '[0-9]\+x[0-9]\+' | tail -1 | tr 'x' ' ')
SCREEN_W="${SCREEN_W:-1080}"
SCREEN_H="${SCREEN_H:-2400}"
SCREEN_W_BY_DEV=("$SCREEN_W" "")
SCREEN_H_BY_DEV=("$SCREEN_H" "")
APP_BY_DEV=("$APP_ID" "")
ACTIVITY_BY_DEV=("$ACTIVITY" "")
# Points the cursor at device 1 and exports the DEMO_* context exec steps read.
use_device 1

STEP_COUNT="$(jq 'length' "$STEPS_FILE")"
echo "==> ${STEP_COUNT} top-level steps from $(basename "$STEPS_FILE"), device $SERIAL (${ACTIVITY})"

# assert_text_present <exact text> [nth]: fails the run if the text never
# shows up (polling through slow loads like poll_bounds does). Generic guard
# for post-login screens, empty states that should have content, etc.
assert_text_present() {
  local text="$1" nth="${2:-1}" bounds
  bounds="$(poll_bounds _bounds_for_text "$text" "$nth")"
  [ -n "$bounds" ] || { echo "ERROR: assert_text failed: no element with text=\"$text\" (nth=$nth) appeared on screen" >&2; return 1; }
}

# narr_id_to_file <step-id>: maps a step id like "3.t.1" to a filesystem-
# safe filename chunk ("3_t_1") so narration wavs can be found later from
# just the id, without any lookup tables.
narr_id_to_file() {
  printf '%s' "$1" | tr '.' '_' | tr -c 'A-Za-z0-9_' '_'
}

# synthesize_line <text> <out_file>: writes speech audio (any format ffmpeg
# reads: aiff for say, wav for piper) to out_file using whichever engine
# --tts selected. The caller always normalizes the result through ffmpeg
# afterward, so the two engines don't need to agree on sample rate/format.
synthesize_line() {
  local text="$1" out="$2"
  if [ "$TTS_ENGINE" = "piper" ]; then
    printf '%s' "$text" | "$PIPER_BIN" -m "$PIPER_MODEL" -c "$PIPER_CONFIG" -f "$out" >/dev/null 2>&1
  else
    local say_args=(-v "$VOICE")
    [ -n "$RATE" ] && say_args+=(-r "$RATE")
    say "${say_args[@]}" -o "$out" -- "$text"
  fi
}

perform_action() {
  local action="$1" step="$2"
  case "$action" in
    launch)
      ADB shell am force-stop "$APP_ID"
      ADB shell am start -n "$ACTIVITY" >/dev/null
      ;;
    reopen)
      ADB shell am start -n "$ACTIVITY" >/dev/null
      ;;
    pm_clear)
      ADB shell pm clear "$APP_ID" >/dev/null
      ;;
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
    tap_until_gone)
      tap_until_gone "$(jq -r '.text' <<<"$step")" "$(jq -r '.watch_for' <<<"$step")" "$(jq -r '.max_attempts // 15' <<<"$step")" "$(jq -r '.interval_seconds // 3' <<<"$step")"
      ;;
    tap_contains_optional)
      # Best-effort: taps a matching element if it shows up within a short
      # window, but never fails the run if it doesn't -- for recovering from
      # a transient backend hiccup (e.g. an in-app "Retry" button after a
      # failed fetch) without blocking the happy path where the failure/retry
      # UI never appears at all. Deliberately its OWN short loop rather than
      # poll_bounds's ~25-attempt window (each attempt costs a real ~2-3s
      # uiautomator dump, so that window is ~60-75s wall clock -- fine for a
      # lookup that's actually expected to eventually succeed, way too long
      # to silently sit on something that usually isn't there at all).
      local bounds sub nth i
      sub="$(jq -r '.text' <<<"$step")"
      nth="$(jq -r '.nth // 1' <<<"$step")"
      for i in 1 2 3 4; do
        bounds="$(_bounds_for_contains "$sub" "$nth")"
        [ -n "$bounds" ] && break
        sleep 1
      done
      if [ -n "$bounds" ]; then
        ADB shell input tap $(center_from_bounds "$bounds")
      fi
      ;;
    tap_left_of_contains)
      find_and_tap_left_of_contains "$(jq -r '.text' <<<"$step")" "$(jq -r '.offset_x // 59' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    swipe_up_from_contains)
      find_and_swipe_up_from_contains "$(jq -r '.text' <<<"$step")" "$(jq -r '.delta_y // 500' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    swipe_element)
      find_and_swipe_direction "$(jq -r '.text' <<<"$step")" "$(jq -r '.direction // "up"' <<<"$step")" "$(jq -r '.delta // 500' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    long_press)
      local lp_dur lp_text lp_contains lp_desc lp_x lp_y
      lp_dur="$(jq -r '.duration_ms // 1000' <<<"$step")"
      lp_text="$(jq -r '.text // empty' <<<"$step")"
      lp_contains="$(jq -r '.contains // empty' <<<"$step")"
      lp_desc="$(jq -r '.desc // empty' <<<"$step")"
      if [ -n "$lp_text" ]; then
        find_and_long_press text "$lp_text" "$(jq -r '.nth // 1' <<<"$step")" "$lp_dur"
      elif [ -n "$lp_contains" ]; then
        find_and_long_press contains "$lp_contains" "$(jq -r '.nth // 1' <<<"$step")" "$lp_dur"
      elif [ -n "$lp_desc" ]; then
        find_and_long_press desc "$lp_desc" "$(jq -r '.nth // 1' <<<"$step")" "$lp_dur"
      else
        lp_x="$(jq -r '.x // empty' <<<"$step")"; lp_y="$(jq -r '.y // empty' <<<"$step")"
        if [ -n "$lp_x" ] && [ -n "$lp_y" ]; then
          ADB shell input swipe "$lp_x" "$lp_y" "$lp_x" "$lp_y" "$lp_dur"
        else
          echo "ERROR: long_press needs 'text', 'contains', 'desc', or 'x'+'y'" >&2; return 1
        fi
      fi
      ;;
    double_tap)
      local dt_text dt_contains dt_desc dt_x dt_y
      dt_text="$(jq -r '.text // empty' <<<"$step")"
      dt_contains="$(jq -r '.contains // empty' <<<"$step")"
      dt_desc="$(jq -r '.desc // empty' <<<"$step")"
      if [ -n "$dt_text" ]; then
        find_and_double_tap text "$dt_text" "$(jq -r '.nth // 1' <<<"$step")"
      elif [ -n "$dt_contains" ]; then
        find_and_double_tap contains "$dt_contains" "$(jq -r '.nth // 1' <<<"$step")"
      elif [ -n "$dt_desc" ]; then
        find_and_double_tap desc "$dt_desc" "$(jq -r '.nth // 1' <<<"$step")"
      else
        dt_x="$(jq -r '.x // empty' <<<"$step")"; dt_y="$(jq -r '.y // empty' <<<"$step")"
        if [ -n "$dt_x" ] && [ -n "$dt_y" ]; then
          ADB shell "input tap $dt_x $dt_y && input tap $dt_x $dt_y"
        else
          echo "ERROR: double_tap needs 'text', 'contains', 'desc', or 'x'+'y'" >&2; return 1
        fi
      fi
      ;;
    drag_and_drop)
      local dd_to_text dd_to_desc dd_x dd_y
      dd_to_text="$(jq -r '.to_text // empty' <<<"$step")"
      dd_to_desc="$(jq -r '.to_desc // empty' <<<"$step")"
      dd_x="$(jq -r '.x // empty' <<<"$step")"; dd_y="$(jq -r '.y // empty' <<<"$step")"
      if [ -n "$dd_to_text" ]; then
        find_and_drag contains "$(jq -r '.from_text' <<<"$step")" "$(jq -r '.from_nth // 1' <<<"$step")" \
          contains "$dd_to_text" "$(jq -r '.to_nth // 1' <<<"$step")" "$(jq -r '.duration_ms // 800' <<<"$step")"
      elif [ -n "$dd_to_desc" ]; then
        find_and_drag contains "$(jq -r '.from_text' <<<"$step")" "$(jq -r '.from_nth // 1' <<<"$step")" \
          desc "$dd_to_desc" "$(jq -r '.to_nth // 1' <<<"$step")" "$(jq -r '.duration_ms // 800' <<<"$step")"
      elif [ -n "$dd_x" ] && [ -n "$dd_y" ]; then
        find_and_drag contains "$(jq -r '.from_text' <<<"$step")" "$(jq -r '.from_nth // 1' <<<"$step")" \
          point "$dd_x $dd_y" 1 "$(jq -r '.duration_ms // 800' <<<"$step")"
      else
        echo "ERROR: drag_and_drop needs a drop target: 'to_text', 'to_desc', or 'x'+'y'" >&2; return 1
      fi
      ;;
    tap_xy)
      ADB shell input tap "$(jq -r '.x' <<<"$step")" "$(jq -r '.y' <<<"$step")"
      maybe_type "$step"
      ;;
    dismiss_keyboard)
      ADB shell input keyevent 111
      ;;
    back)
      ADB shell input keyevent KEYCODE_BACK
      ;;
    home_button)
      ADB shell input keyevent KEYCODE_HOME
      ;;
    pause)
      : # narration/settle timing alone provides the dwell
      ;;
    assert_text)
      assert_text_present "$(jq -r '.text' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    exec)
      do_exec_step "$step"
      ;;
    swipe)
      local dir cx cy x1 x2 y1 y2 dur
      dir="$(jq -r '.direction' <<<"$step")"
      dur="$(jq -r '.duration_ms // 400' <<<"$step")"
      cx=$(( SCREEN_W / 2 )); cy=$(( SCREEN_H / 2 ))
      case "$dir" in
        up)    ADB shell input swipe "$cx" $(( SCREEN_H * 70 / 100 )) "$cx" $(( SCREEN_H * 30 / 100 )) "$dur" ;;
        down)  ADB shell input swipe "$cx" $(( SCREEN_H * 30 / 100 )) "$cx" $(( SCREEN_H * 70 / 100 )) "$dur" ;;
        left)  ADB shell input swipe $(( SCREEN_W * 80 / 100 )) "$cy" $(( SCREEN_W * 20 / 100 )) "$cy" "$dur" ;;
        right) ADB shell input swipe $(( SCREEN_W * 20 / 100 )) "$cy" $(( SCREEN_W * 80 / 100 )) "$cy" "$dur" ;;
        *) echo "ERROR: invalid swipe direction '$dir' (expected up, down, left, or right)" >&2; return 1 ;;
      esac
      ;;
    swipe_until_contains)
      find_and_tap_after_scrolling "$(jq -r '.text' <<<"$step")" "$(jq -r '.max_swipes // 6' <<<"$step")" "$(jq -r '.nth // 1' <<<"$step")"
      ;;
    *)
      echo "ERROR: unknown action '$action'; see STEP FILE FORMAT in --help" >&2
      return 1
      ;;
  esac
}

# ---- Dry run: drive only, fixed short pauses, no recording/audio ----------
# Shares the real evaluator and dispatcher with the recorded drive so step
# targets can be tested exactly as they will run; exec steps are NOT executed
# here (they are reported and recorded as success so downstream if/source=
# last_command branches take the happy path).
dry_run_steps() {
  local arr="$1" depth="$2" n i d step action narration indent cond branch
  n="$(jq 'length' <<<"$arr")"
  indent=""
  for ((d = 0; d < depth; d++)); do indent="${indent}  "; done
  for ((i = 0; i < n; i++)); do
    step="$(jq -c ".[$i]" <<<"$arr")"
    action="$(jq -r '.action' <<<"$step")"
    narration="$(jq -r '.narration // empty' <<<"$step")"
    echo "${indent}-- step ${depth}.${i}: ${action}${narration:+  # ${narration}}"
    case "$action" in
      if)
        cond=0
        eval_condition "$step" || cond=$?
        case "$cond" in
          0)
            branch="then"
            echo "${indent}   (condition met -> then-branch)"
            ;;
          1)
            branch="else"
            echo "${indent}   (condition not met -> else-branch)"
            ;;
          *) return 1 ;;
        esac
        dry_run_steps "$(jq -c ".${branch} // []" <<<"$step")" $((depth + 1))
        ;;
      exec)
        # Never run external commands in a dry run; record success so
        # downstream if/source=last_command branches take the happy path.
        echo "${indent}   (dry run: skipping external command)"
        LAST_EXEC_STATUS="0"
        LAST_EXEC_OUTPUT=""
        ;;
      *)
        perform_action "$action" "$step"
        ;;
    esac
    sleep 1.2
  done
}

if [ "$DRY_RUN" -eq 1 ]; then
  ADB shell am start -n "$ACTIVITY" >/dev/null 2>&1 || true
  sleep 1
  dry_run_steps "$(cat "$STEPS_FILE")" 0
  echo "==> Dry run complete."
  exit 0
fi

# ---- Phase 1: pre-synthesize narration audio -------------------------------
# Real per-step timing (how long an action actually took) isn't known until
# Phase 2 (the drive) runs, so the narration TRACK itself is only assembled
# afterward, in Phase 3 -- using the real durations, not a guess made before
# a single tap happened. What must happen here is synthesis: TTS mid-drive
# would stall the run and show up as dead air in the video. With if-steps
# the executed sequence isn't known yet either, so EVERY leaf step's
# narration (then- and else-arms included) is synthesized up front, keyed by
# a stable tree-path id ("3", "4.t.1", ...); arms that end up untaken cost a
# few seconds of TTS here and are simply never muxed.
walk_and_synthesize() {
  local arr="$1" prefix="$2" n i step action narration raw wav
  n="$(jq 'length' <<<"$arr")"
  for ((i = 0; i < n; i++)); do
    step="$(jq -c ".[$i]" <<<"$arr")"
    action="$(jq -r '.action' <<<"$step")"
    if [ "$action" = "if" ]; then
      # ifs are timed beats too (their own breath + condition eval), so they
      # count toward the segment-cut budget just like leaf steps.
      TOTAL_LEAVES=$((TOTAL_LEAVES + 1))
      walk_and_synthesize "$(jq -c '.then // []' <<<"$step")" "${prefix}${i}.t."
      walk_and_synthesize "$(jq -c '.else // []' <<<"$step")" "${prefix}${i}.e."
    else
      TOTAL_LEAVES=$((TOTAL_LEAVES + 1))
      [ "$NO_NARRATION" -eq 1 ] && continue
      narration="$(jq -r '.narration // empty' <<<"$step")"
      [ -z "$narration" ] && continue
      raw="$WORKDIR/audio/n_$(narr_id_to_file "${prefix}${i}").raw"
      wav="$WORKDIR/audio/n_$(narr_id_to_file "${prefix}${i}").wav"
      synthesize_line "$narration" "$raw"
      ffmpeg -y -loglevel error -i "$raw" -ar 44100 -ac 1 "$wav"
      rm -f "$raw"
    fi
  done
}
echo "==> Synthesizing narration audio"
TOTAL_LEAVES=0
LEAVES_LEFT=0
walk_and_synthesize "$(cat "$STEPS_FILE")" ""
echo "==> ${TOTAL_LEAVES} timed beats (leaf steps + condition checks, all branches)"

# ---- Phase 2: drive the device + record the screen, segmented -------------
echo "==> Recording + driving the demo"
SEG_INDEX=0
SEG_ELAPSED="0"
REC_PID=""

start_segment() {
  ADB shell screenrecord --bit-rate 8000000 "/sdcard/_android_demo_seg_${SEG_INDEX}.mp4" &
  REC_PID=$!
  sleep 1
}

stop_segment() {
  [ -n "$REC_PID" ] || return 0
  # kill -INT on the LOCAL "adb shell screenrecord &" pid does not reliably
  # propagate to the REMOTE screenrecord process; adb doesn't forward
  # signals through a plain (non-PTY) shell session, so the local wrapper can
  # sit blocked on the device's output stream forever. Signal the on-device
  # process directly over a fresh adb call instead; that's what actually
  # makes it finalize the mp4 and close the stream the local wrapper is
  # waiting on. Bound the subsequent wait and fall back to a hard kill so a
  # genuinely wedged wrapper can never hang the whole run.
  ADB shell pkill -INT screenrecord >/dev/null 2>&1 || true
  local waited=0
  while kill -0 "$REC_PID" 2>/dev/null && [ "$waited" -lt 8 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -9 "$REC_PID" 2>/dev/null || true
  wait "$REC_PID" 2>/dev/null || true
  sleep 1
  ADB pull "/sdcard/_android_demo_seg_${SEG_INDEX}.mp4" "$WORKDIR/video/seg_${SEG_INDEX}.mp4" >/dev/null 2>&1
  ADB shell rm -f "/sdcard/_android_demo_seg_${SEG_INDEX}.mp4" >/dev/null 2>&1 || true
  REC_PID=""
}

# ---- Drive engine ----------------------------------------------------------
# Steps run through a small recursive executor because of `if`: the sequence
# that actually executes is decided at runtime by each condition. Every
# executed step gets one "beat": deterministic jitter pause, its action (for
# an if-step, the condition evaluation itself), then settle + narration
# dwell. Each beat appends an entry to TIMELINE_* with its REAL measured
# duration, which Phase 3 replays into the narration track -- that replay,
# not pre-run guesses, is what keeps narration synced when retries or slow
# loads stretch a step far past plan. Segment cutting rides along per beat.
LEAF_SEED=0
BEAT_SEED=0
BEAT_PRE="0"
# TIGHT packs the audio against the picture: no jitter pause before an action,
# narration starting the instant the beat starts (so it plays over the screen
# transition instead of after it), and a hair of tail. The old spaced-out
# timing reads as dead air on a demo meant to be watched end to end. Opt back
# into the old pacing with --loose (or TIGHT_OPT=0).
TIGHT="${TIGHT_OPT:-${TIGHT:-1}}"
TIGHT_TAIL="${TIGHT_TAIL:-0.15}"
TIMELINE_ID=()
TIMELINE_SETTLE=()
TIMELINE_PRE=()
TIMELINE_ACT=()
TIMELINE_DWELL=()
TIMELINE_HAS_NARR=()

# begin_beat: pick this beat's jitter pause (seeded by execution order, so
# a re-run over the same steps file reproduces the same timing) and sleep it.
begin_beat() {
  BEAT_SEED="$LEAF_SEED"
  LEAF_SEED=$((LEAF_SEED + 1))
  if [ "$TIGHT" = 1 ]; then
    BEAT_PRE="0"
  else
    BEAT_PRE="$(awk -v seed="$BEAT_SEED" 'BEGIN{srand(seed+1); printf "%.2f", 0.4 + rand()*0.5}')"
    sleep "$BEAT_PRE"
  fi
}

# end_beat <id> <narration> <settle_s> <act>: hold the screen for settle +
# spoken length (+ small tail), record the beat, then honor the segment cut
# threshold by rotating screenrecord files mid-run.
end_beat() {
  local id="$1" narration="$2" settle_s="$3" act="$4"
  local narration_wav="" speak_dur="0" tail_pause dwell has_narr step_total
  if [ "$NO_NARRATION" -eq 0 ] && [ -n "$narration" ]; then
    narration_wav="$WORKDIR/audio/n_$(narr_id_to_file "$id").wav"
    if [ -f "$narration_wav" ]; then
      has_narr=y
      speak_dur="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$narration_wav")"
    fi
  fi
  if [ "$TIGHT" = 1 ]; then
    tail_pause="$TIGHT_TAIL"
    # Speech already started at the top of the beat and has been running
    # through the action, so only hold for whatever is left of it, never for
    # its full length on top of the action time.
    dwell="$(awk -v s="$settle_s" -v sp="$speak_dur" -v a="$act" -v t="$tail_pause" \
      'BEGIN{r=sp-a; if (r<s) r=s; printf "%.2f", r+t}')"
  elif [ "${has_narr:-n}" = "y" ]; then
    tail_pause="$(awk -v seed="$BEAT_SEED" 'BEGIN{srand(seed+7); printf "%.2f", 0.6 + rand()*0.7}')"
    dwell="$(awk -v s="$settle_s" -v sp="$speak_dur" -v t="$tail_pause" 'BEGIN{printf "%.2f", s+sp+t}')"
  else
    tail_pause="$(awk -v seed="$BEAT_SEED" 'BEGIN{srand(seed+7); printf "%.2f", 1.0 + rand()}')"
    dwell="$(awk -v s="$settle_s" -v sp="$speak_dur" -v t="$tail_pause" 'BEGIN{printf "%.2f", s+sp+t}')"
  fi
  sleep "$dwell"

  TIMELINE_ID+=("$id")
  TIMELINE_SETTLE+=("$settle_s")
  TIMELINE_PRE+=("$BEAT_PRE")
  TIMELINE_ACT+=("$act")
  TIMELINE_DWELL+=("$dwell")
  TIMELINE_HAS_NARR+=("${has_narr:-n}")

  step_total="$(awk -v p="$BEAT_PRE" -v d="$dwell" -v a="$act" 'BEGIN{printf "%.2f", p+a+d}')"
  SEG_ELAPSED="$(awk -v a="$SEG_ELAPSED" -v b="$step_total" 'BEGIN{printf "%.2f", a+b}')"
  LEAVES_LEFT=$((LEAVES_LEFT - 1))
  if awk -v a="$SEG_ELAPSED" -v lim="$SEGMENT_SECONDS" 'BEGIN{exit !(a>=lim)}' && [ "$LEAVES_LEFT" -gt 0 ]; then
    echo "   (cutting recording segment at ${SEG_ELAPSED}s)"
    stop_segment
    SEG_INDEX=$((SEG_INDEX + 1))
    SEG_ELAPSED="0"
    start_segment
  fi
}

# run_leaf_step <step-json> <id>
run_leaf_step() {
  local step="$1" id="$2"
  local action narration settle_ms settle_s
  local action_start action_end act
  action="$(jq -r '.action' <<<"$step")"
  narration="$(jq -r '.narration // empty' <<<"$step")"
  settle_ms="$(jq -r '.settle_ms // 600' <<<"$step")"
  settle_s="$(awk -v ms="$settle_ms" 'BEGIN{printf "%.3f", ms/1000}')"
  echo "-- step ${id}: ${action}${narration:+  # ${narration}}"
  begin_beat
  action_start="$(date +%s.%N)"
  perform_action "$action" "$step"
  action_end="$(date +%s.%N)"
  act="$(awk -v a="$action_start" -v b="$action_end" 'BEGIN{d=b-a; if (d<0) d=0; printf "%.3f", d}')"
  end_beat "$id" "$narration" "$settle_s" "$act"
}

# run_steps <json-array> <id-prefix>: walks an array of steps in order,
# dispatching leaves and expanding ifs recursively. An if-step's own beat
# (usually a silent breath) plays out before its branch starts, so branch
# steps don't crowd it off the screen.
run_steps() {
  local arr="$1" prefix="$2" n i step action id narration settle_ms settle_s
  local cond=0 branch action_start action_end act
  n="$(jq 'length' <<<"$arr")"
  for ((i = 0; i < n; i++)); do
    step="$(jq -c ".[$i]" <<<"$arr")"
    action="$(jq -r '.action' <<<"$step")"
    id="${prefix}${i}"
    case "$action" in
      if)
        narration="$(jq -r '.narration // empty' <<<"$step")"
        settle_ms="$(jq -r '.settle_ms // 600' <<<"$step")"
        settle_s="$(awk -v ms="$settle_ms" 'BEGIN{printf "%.3f", ms/1000}')"
        echo "-- step ${id}: if${narration:+  # ${narration}}"
        begin_beat
        action_start="$(date +%s.%N)"
        cond=0
        eval_condition "$step" || cond=$?
        action_end="$(date +%s.%N)"
        act="$(awk -v a="$action_start" -v b="$action_end" 'BEGIN{d=b-a; if (d<0) d=0; printf "%.3f", d}')"
        case "$cond" in
          0)
            branch="then"
            echo "   # condition met -> then-branch"
            ;;
          1)
            branch="else"
            echo "   # condition not met -> else-branch"
            ;;
          *)
            return 1
            ;;
        esac
        end_beat "$id" "$narration" "$settle_s" "$act"
        run_steps "$(jq -c ".${branch} // []" <<<"$step")" "${id}.${branch:0:1}."
        ;;
      *)
        run_leaf_step "$step" "$id"
        ;;
    esac
  done
}

start_segment
run_steps "$(cat "$STEPS_FILE")" ""
stop_segment

# ---- Phase 3: assemble the narration track by replaying TIMELINE_* ---------
# Each executed beat recorded its REAL action duration during the drive, so
# the leading silence before a step's narration matches how long the video
# actually spent on that action. This is what keeps a slow tap_until_gone/
# poll_bounds retry from letting every later line of narration drift out
# from under the picture -- and it works through if-branches too, since only
# beats that actually executed are on the timeline.
if [ "$NO_NARRATION" -eq 0 ]; then
  echo "==> Assembling narration track"
  concat_inputs=()
  tl_n="${#TIMELINE_ID[@]}"
  for ((i = 0; i < tl_n; i++)); do
    settle_s="${TIMELINE_SETTLE[$i]}"
    pre="${TIMELINE_PRE[$i]}"
    act="${TIMELINE_ACT[$i]}"
    if [ "$TIGHT" = 1 ]; then
      lead_s="$pre"
    else
      lead_s="$(awk -v a="$pre" -v b="$settle_s" -v c="$act" 'BEGIN{printf "%.3f", a+b+c}')"
    fi
    tag="$(narr_id_to_file "${TIMELINE_ID[$i]}")"

    narration_wav=""
    if [ "${TIMELINE_HAS_NARR[$i]}" = "y" ]; then
      narration_wav="$WORKDIR/audio/n_${tag}.wav"
    fi
    if [ -n "$narration_wav" ] && [ -f "$narration_wav" ]; then
      speak_dur="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$narration_wav")"
    else
      narration_wav=""
      speak_dur="0"
    fi
    # Whatever of the beat's own wall time the lead and the speech did not use.
    # Same formula in both modes, so the audio track stays exactly as long as
    # the video no matter how the dwell was chosen.
    tail_s="$(awk -v p="$pre" -v a="$act" -v d="${TIMELINE_DWELL[$i]}" -v l="$lead_s" -v sp="$speak_dur" \
      'BEGIN{v=p+a+d-l-sp; if (v<0) v=0; printf "%.3f", v}')"

    lead_wav="$WORKDIR/audio/lead_${tag}.wav"
    tail_wav="$WORKDIR/audio/tail_${tag}.wav"
    ffmpeg -y -loglevel error -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100" -t "$lead_s" -q:a 9 "$lead_wav"
    ffmpeg -y -loglevel error -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100" -t "$tail_s" -q:a 9 "$tail_wav"

    if [ -n "$narration_wav" ]; then
      concat_inputs+=("$lead_wav" "$narration_wav" "$tail_wav")
    else
      concat_inputs+=("$lead_wav" "$tail_wav")
    fi
  done

  args=()
  for f in "${concat_inputs[@]}"; do args+=(-i "$f"); done
  filter=""
  for idx in "${!concat_inputs[@]}"; do filter="${filter}[${idx}:a]"; done
  filter="${filter}concat=n=${#concat_inputs[@]}:v=0:a=1[out]"
  ffmpeg -y -loglevel error "${args[@]}" -filter_complex "$filter" -map "[out]" "$WORKDIR/narration.wav"
fi

# ---- Phase 4: concat video segments (always re-encodes, even for one) -----
# screenrecord's own output has no duration in its container header when
# stopped early via SIGINT (harmless on its own; real players compute
# playback length from packet timestamps) but it makes ffmpeg's `-shortest`
# in the Phase 5 mux misjudge the video as zero-length and emit an empty
# clip. Routing every run through this re-encode, single segment or not,
# gives Phase 5 a video with real duration metadata to work with, since the
# multi-segment path already needed this pass anyway.
SEG_COUNT=$((SEG_INDEX + 1))
echo "==> Normalizing ${SEG_COUNT} recording segment$([ "$SEG_COUNT" -gt 1 ] && echo s)"
args=()
filter=""
for s in $(seq 0 $((SEG_COUNT - 1))); do
  args+=(-i "$WORKDIR/video/seg_${s}.mp4")
  filter="${filter}[${s}:v]"
done
filter="${filter}concat=n=${SEG_COUNT}:v=1:a=0[outv]"
# Normalise the frame rate on the way out of the concat. screenrecord emits
# variable-rate frames with duplicate DTS, and h264 written straight from them
# lands its first keyframe tens of seconds in. Players then show the opening as
# smeared blocks until the second keyframe arrives. Normalising to a constant
# rate and forcing a keyframe every 2s fixes the start, and costs nothing
# anywhere else. sc_threshold=0 keeps the interval regular rather than letting
# x264 place keyframes on scene cuts, which a screen recording has few of.
filter="${filter//\[outv\]/[outvraw]}"
filter="${filter};[outvraw]fps=30,format=yuv420p[outv]"
ffmpeg -y -loglevel error "${args[@]}" -filter_complex "$filter" -map "[outv]" \
  -fps_mode cfr -c:v libx264 -preset veryfast -crf 20 \
  -g 60 -keyint_min 30 -sc_threshold 0 \
  "$WORKDIR/video/combined.mp4"
VIDEO="$WORKDIR/video/combined.mp4"

# ---- Phase 5: mux narration onto the video ---------------------------------
if [ "$NO_NARRATION" -eq 1 ]; then
  cp "$VIDEO" "$OUT"
else
  echo "==> Muxing narration onto video"
  ffmpeg -y -loglevel error -i "$VIDEO" -i "$WORKDIR/narration.wav" \
    -map 0:v -map 1:a -c:v copy -c:a aac -shortest -movflags +faststart "$OUT"
fi

echo "==> Done: $OUT"
