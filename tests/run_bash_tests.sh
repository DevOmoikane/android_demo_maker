#!/usr/bin/env bash
# Bash-level tests for the Android driving scripts. The Python suite covers the
# studio backend; this exercises the shell library/driver logic that Python
# cannot import: the device-hygiene guards, type-focus settle, poll knobs, the
# --loose pacing flag, and the frame-rate normalization pass.
#
# Run with: tests/run_bash_tests.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/android-ui-lib.sh"
DEMO="$ROOT/android-demo.sh"
SPEC="$ROOT/android-spec-test.sh"

PASS=0
FAIL=0

note() { printf 'ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bail() { printf 'FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }

expect() { # expect <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then note "$1"; else bail "$1 (got: $2, want: $3)"; fi
}

expect_contains() { # expect_contains <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) note "$1" ;;
    *) bail "$1 (missing: $3)" ;;
  esac
}

expect_no_contains() { # expect_no_contains <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) bail "$1 (unexpected: $3)" ;;
    *) note "$1" ;;
  esac
}

# Extended-regex matcher over a string rather than a file: used to read values
# out of a traced run, which is not on disk.
expect_match() { # expect_match <desc> <string> <extended-regex>
  if printf '%s\n' "$2" | grep -Eq -- "$3"; then note "$1"; else bail "$1 (no match: $3)"; fi
}

# For counts that are only bounded, not exact: a screen condition polls until
# its timeout, so how many times it dumped the hierarchy is not a fixed number.
at_least() { # at_least <desc> <actual> <minimum>
  if [ "$2" -ge "$3" ] 2>/dev/null; then note "$1"; else bail "$1 (got: $2, want: >= $3)"; fi
}

# The workdir a run kept, which is where its pulled segments are.
kept_workdir() { printf '%s\n' "$1" | sed -n 's/^==> Keeping workdir: //p'; }

# Occurrences of a substring inside a single string, for a value that is one
# comma-joined line rather than a list.
count_occurrences() { # count_occurrences <desc> <string> <substring> <expected>
  local n
  n="$(printf '%s' "$2" | grep -o -- "$3" | wc -l | tr -d ' ')"
  if [ "$n" = "$4" ]; then note "$1"; else bail "$1 (got: $n occurrences of '$3' in: $2)"; fi
}

expect_grep() { # expect_grep <desc> <file> <fixed-pattern>
  if grep -q -- "$3" "$2"; then note "$1"; else bail "$1 (no match: $3 in $(basename "$2"))"; fi
}

expect_no_grep() { # expect_no_grep <desc> <file> <fixed-pattern>
  if grep -q -- "$3" "$2"; then bail "$1 (unexpected match: $3 in $(basename "$2"))"; else note "$1"; fi
}

# ---------------------------------------------------------------- syntax
for f in "$DEMO" "$SPEC" "$LIB" "$ROOT/android-compose-lib.sh"; do
  if bash -n "$f"; then note "bash -n parses $(basename "$f")"; else bail "bash -n failed on $(basename "$f")"; fi
done

# ---------------------------------------------------------------- stubbed env
SERIAL_A="SER1"
SERIAL_B="SER2"
FAKE_USB_A=1
FAKE_USB_B=1
FAKE_DEVICES_A="SER1  device usb:2-2 product:raven model:Pixel_6_Pro device:raven transport_id:2"
FAKE_DEVICES_A_WIFI="SER1  device product:raven model:Pixel_6_Pro device:raven transport_id:2"
FAKE_DEVICES_B="SER2  device usb:2-4 product:cuttlefish model:sdk_gphone64 device:cuttlefish transport_id:4"
FAKE_DEVICES_B_WIFI="SER2  device product:cuttlefish model:sdk_gphone64 device:cuttlefish transport_id:4"
SLEPT=()
TYPED=()
ADB_LOG=""
ROT_A="$(mktemp)"
ROT_B="$(mktemp)"
printf '0\n' > "$ROT_A"
printf '1\n' > "$ROT_B"
cleanup_test_tmp() {
  rm -rf "${STUB_DIR:-/nonexistent}" "${CALLS:-/nonexistent}" \
         "${EMPTY_STEPS:-/nonexistent}" "${EMPTY_SCENARIOS:-/nonexistent}" \
         "${LAUNCH_SCENARIOS:-/nonexistent}" "${MIXED_STEPS:-/nonexistent}" \
         "${SIMPLE_STEPS:-/nonexistent}" "${APP2_STEPS:-/nonexistent}" \
         "${MIXED_SCENARIOS:-/nonexistent}" 2>/dev/null
  rm -f "$ROT_A" "$ROT_B"
}
trap cleanup_test_tmp EXIT

# Raw adb is the only thing stubbed now: the library owns ADB()/ADB_FOR(), so a
# device-targeted call arrives as `adb -s <serial> <rest>`. Every -s call is
# appended to ADB_LOG so a test can assert which device a command reached.
# State that used to live in one ROT_FILE is per-device now, which is the point
# of the change: restoring device 1 must not disturb device 2.
adb() {
  if [ "${1:-}" = "devices" ] && [ "${2:-}" = "-l" ]; then
    local la lb
    if [ "$FAKE_USB_A" = 1 ]; then la="$FAKE_DEVICES_A"; else la="$FAKE_DEVICES_A_WIFI"; fi
    if [ "$FAKE_USB_B" = 1 ]; then lb="$FAKE_DEVICES_B"; else lb="$FAKE_DEVICES_B_WIFI"; fi
    printf '%s\n%s\n' "$la" "$lb"
    return 0
  fi
  [ "${1:-}" = "-s" ] || return 0
  local sn="$2"
  shift 2
  ADB_LOG="${ADB_LOG}${sn}|${*};"
  case "$*" in
    "shell settings get system accelerometer_rotation")
      if [ "$sn" = "$SERIAL_A" ]; then cat "$ROT_A"; else cat "$ROT_B"; fi
      ;;
    "shell settings put system accelerometer_rotation "*)
      if [ "$sn" = "$SERIAL_A" ]; then
        printf '%s\n' "${@: -1}" > "$ROT_A"
      else
        printf '%s\n' "${@: -1}" > "$ROT_B"
      fi
      ;;
    "shell input text "*) TYPED+=("${@: -1}") ;;
  esac
  return 0
}

sleep() { SLEPT+=("${1:-}"); }

# Caller side of the library contract, exactly what the drivers now set.
SERIALS=("$SERIAL_A" "$SERIAL_B")
DEVICE_COUNT=2
SCREEN_W_BY_DEV=(1080 720)
SCREEN_H_BY_DEV=(2400 1600)
APP_BY_DEV=("com.example.app" "com.other.app")
ACTIVITY_BY_DEV=("com.example.app/.MainActivity" "com.other.app/.MainActivity")
APP_ID="${APP_BY_DEV[0]}"
ACTIVITY="${ACTIVITY_BY_DEV[0]}"

# shellcheck source=/dev/null
. "$LIB"

# ---------------------------------------------------------------- device cursor
ADB_LOG=""
use_device 2
expect "use_device sets the cursor" "$CUR_DEV" "2"
expect "use_device loads device 2 screen size" "$SCREEN_W/$SCREEN_H" "720/1600"
expect "use_device loads device 2 app context" "$APP_ID" "com.other.app"
expect "use_device loads device 2 activity" "$ACTIVITY" "com.other.app/.MainActivity"
expect "use_device exports device 2's exec context" \
  "$DEMO_SERIAL/$DEMO_APP_ID/$DEMO_SCREEN_W" "$SERIAL_B/com.other.app/720"
ADB shell echo hi >/dev/null
expect "ADB targets the cursor's device" "$ADB_LOG" "$SERIAL_B|shell echo hi;"
ADB_FOR 1 shell echo hi >/dev/null
expect "ADB_FOR targets an explicit device" \
  "$ADB_LOG" "$SERIAL_B|shell echo hi;$SERIAL_A|shell echo hi;"
use_device 1
expect "use_device back to 1 reloads device 1" "$SCREEN_W/$SCREEN_H" "1080/2400"
expect "use_device back to 1 re-exports device 1's context" "$DEMO_SERIAL" "$SERIAL_A"

# ---------------------------------------------------------------- step dispatch
step_device '{"action":"tap_text","text":"x","device":2}'
expect "a device 2 step moves the cursor" "$CUR_DEV" "2"
step_device '{"action":"tap_text","text":"x"}'
expect "an absent device means 1" "$CUR_DEV" "1"
step_device '{"action":"tap_text","text":"x","device":"1"}'
expect "a stringified 1 is accepted" "$CUR_DEV" "1"
rc=0
out="$(step_device '{"action":"tap_text","text":"x","device":3}' 2>&1)" || rc=$?
expect "device 3 is rejected" "$rc" "1"
expect_contains "the rejection names the allowed values" "$out" "1 or 2"

# A device the run never attached is a different failure from a nonsense number:
# the cursor would point at an empty SERIALS slot and the step would die later as
# a confusing adb error, so it is refused up front with the fix in the message.
# The cursor starts on device 1, so an adb call after the refusal is evidence of
# where it actually is: a step_device that moved before refusing would send that
# call to device 2's serial instead.
DEVICE_COUNT=1
use_device 1
rc=0
out="$(step_device '{"action":"tap_text","text":"x","device":2}' 2>&1)" || rc=$?
expect "a device 2 step is refused in a single-device run" "$rc" "1"
expect_contains "the refusal names the flag that adds the device" "$out" "--serial-2"
ADB_LOG=""
ADB shell echo where-am-i
expect "a refused step leaves the cursor still on device 1" \
  "$(printf '%s\n' "$ADB_LOG" | sed -n 's/^\([^|]*\)|.*/\1/p')" "$SERIAL_A"
rc=0
step_device '{"action":"tap_text","text":"x","device":1}' || rc=$?
expect "a device 1 step still works with one device attached" "$rc" "0"
DEVICE_COUNT=2

# ---------------------------------------------------------------- autorotate
GUARD_AUTOROTATE=true
printf '0\n' > "$ROT_A"
printf '1\n' > "$ROT_B"
autorotate_snapshot
expect "snapshot records device 1" "${AUTOROTATE_AT_START[0]}" "0"
expect "snapshot records device 2" "${AUTOROTATE_AT_START[1]}" "1"
printf '1\n' > "$ROT_A"
out="$(autorotate_restore 2>&1)"
expect "restore puts device 1 back" "$(cat "$ROT_A")" "0"
expect "restore leaves device 2 alone" "$(cat "$ROT_B")" "1"
expect_contains "restore names the device" "$out" "device 1"
expect_contains "restore reports the verb" "$out" "restored"

GUARD_AUTOROTATE=false
AUTOROTATE_AT_START=("" "")
printf '0\n' > "$ROT_A"
autorotate_snapshot
expect "GUARD_AUTOROTATE=false skips the snapshot" "${AUTOROTATE_AT_START[0]}" ""
expect "GUARD_AUTOROTATE=false skips every device" "${AUTOROTATE_AT_START[1]}" ""
GUARD_AUTOROTATE=true

# ---------------------------------------------------------------- device_is_usb
FAKE_USB_A=1
FAKE_USB_B=1
device_is_usb 1 && rc=0 || rc=1
expect "device 1 reports USB" "$rc" "0"
FAKE_USB_B=0
device_is_usb 2 && rc=0 || rc=1
expect "device 2 over wireless reports not-USB" "$rc" "1"
FAKE_USB_B=1

# ---------------------------------------------------------------- exec radio guard
GUARD_RADIO_TOGGLE_USB_ONLY=true
FAKE_USB_A=0
radio_step='{"command": "svc wifi disable", "on_fail": "continue"}'
rc=0
out="$(do_exec_step "$radio_step" 2>&1)" || rc=$?
expect "radio toggle is refused off-USB" "$rc" "1"
expect_contains "refusal names the USB requirement" "$out" "not on USB"

FAKE_USB_A=1
rc=0
out="$(do_exec_step "$radio_step" 2>&1)" || rc=$?
expect "radio toggle runs when USB" "$rc" "0"
expect_no_grep "guard does not fire over USB" <(printf '%s' "$out") "not on USB"

FAKE_USB_B=0
use_device 2
rc=0
out="$(do_exec_step "$radio_step" 2>&1)" || rc=$?
expect "radio toggle is refused for device 2 off-USB" "$rc" "1"
FAKE_USB_B=1
use_device 1

# ---------------------------------------------------------------- type-focus settle
SLEPT=()
TYPED=()
type_step='{"type": "hello"}'
maybe_type "$type_step" >/dev/null
[ "${#SLEPT[@]}" -ge 1 ] && [ "${SLEPT[0]}" = "0.4" ] \
  && note "maybe_type settles 0.4s before typing" \
  || bail "maybe_type default settle missing (slept: ${SLEPT[*]:-none})"
[ "${#TYPED[@]}" -eq 1 ] && [ "${TYPED[0]}" = "hello" ] \
  && note "maybe_type typed the value" \
  || bail "maybe_type typed wrong (typed: ${TYPED[*]:-none})"

SLEPT=()
TYPE_FOCUS_SETTLE_SECONDS=0.7
maybe_type "$type_step" >/dev/null
[ "${#SLEPT[@]}" -ge 1 ] && [ "${SLEPT[0]}" = "0.7" ] \
  && note "TYPE_FOCUS_SETTLE_SECONDS is honored" \
  || bail "settle override ignored (slept: ${SLEPT[*]:-none})"
unset TYPE_FOCUS_SETTLE_SECONDS

SLEPT=()
TYPED=()
maybe_type '{"action": "tap_text", "text": "x"}' >/dev/null
[ "${#SLEPT[@]}" -eq 0 ] && note "no settle when the step has no type" \
  || bail "settled despite no type field"
[ "${#TYPED[@]}" -eq 0 ] && note "no typing when the step has no type" \
  || bail "typed despite no type field"

# ---------------------------------------------------------------- exec slots
# Not captured in a command substitution: that is a subshell, and do_exec_step's
# whole purpose here is to leave the result in the calling shell's globals.
GUARD_RADIO_TOGGLE_USB_ONLY=false
LAST_EXEC_STATUS_BY_DEV=("1" "")
LAST_EXEC_OUTPUT_BY_DEV=("" "")
use_device 2
do_exec_step '{"command": "echo hello", "shell": "bash", "on_fail": "continue"}' \
  >/dev/null 2>&1
expect "device 2 slot holds the output" "${LAST_EXEC_OUTPUT_BY_DEV[1]}" "hello"
expect "device 2 bare mirror is current" "$LAST_EXEC_OUTPUT" "hello"
expect "device 1 slot untouched" "${LAST_EXEC_OUTPUT_BY_DEV[0]}" ""
expect "device 2 slot holds the status" "${LAST_EXEC_STATUS_BY_DEV[1]}" "0"
expect "device 1 status slot untouched" "${LAST_EXEC_STATUS_BY_DEV[0]}" "1"
use_device 1
expect "switching back reloads device 1's empty output" "$LAST_EXEC_OUTPUT" ""
expect "switching back reloads device 1's status" "$LAST_EXEC_STATUS" "1"
GUARD_RADIO_TOGGLE_USB_ONLY=true

# ---------------------------------------------------------------- poll knobs
POLL_MAX_ATTEMPTS=3
POLL_INTERVAL_SECONDS=0.01
SLEPT=()
COUNTER_FILE="$(mktemp)"
never() { printf 'x\n' >> "$COUNTER_FILE"; }
poll_bounds never
expect "poll_bounds honors POLL_MAX_ATTEMPTS" "$(wc -l < "$COUNTER_FILE" | tr -d ' ')" "3"
expect "poll_bounds sleeps between attempts" "${#SLEPT[@]}" "3"
rm -f "$COUNTER_FILE"
unset POLL_MAX_ATTEMPTS POLL_INTERVAL_SECONDS

# ---------------------------------------------------------------- compositing
# Sourced directly: the composing functions are pure and touch no device, which
# is the whole reason they live in their own file.
COMPOSE_HEIGHT=1080
# shellcheck source=/dev/null
. "$ROOT/android-compose-lib.sh"

DEVICE_COUNT=1
SCREEN_W_BY_DEV=(1080)
SCREEN_H_BY_DEV=(2400)
expect "single device filter is unchanged" \
  "$(build_concat_filter 3)" \
  "[0:v][1:v][2:v]concat=n=3:v=1:a=0[outvraw];[outvraw]fps=30,format=yuv420p[outv]"
expect "single device, single segment" \
  "$(build_concat_filter 1)" \
  "[0:v]concat=n=1:v=1:a=0[outvraw];[outvraw]fps=30,format=yuv420p[outv]"
# One device passes through unscaled, so the composite is the device's own screen
# and not a pane of it. The driver reports this size, so it has to be set here.
build_compose_geometry 1080
expect "one device's output is its own screen size" "$COMPOSE_W x $COMPOSE_H" "1080 x 2400"

DEVICE_COUNT=2
SCREEN_W_BY_DEV=(1080 1080)
SCREEN_H_BY_DEV=(2400 2400)
geom() { build_compose_geometry "$1"; printf '%s x %s' "$COMPOSE_W" "$COMPOSE_H"; }
expect "two 1080x2400 panes at 1080" "$(geom 1080)" "972 x 1080"

SCREEN_W_BY_DEV=(1440 1440)
SCREEN_H_BY_DEV=(2560 2560)
expect "a fractional pane width rounds up to even" "$(geom 1080)" "1216 x 1080"
expect "an odd height rounds down to even" \
  "$(build_compose_geometry 1081; printf '%s' "$COMPOSE_H")" "1080"
expect "an absurd height is floored" \
  "$(build_compose_geometry 4; printf '%s' "$COMPOSE_H")" "16"

SCREEN_W_BY_DEV=(1080 1080)
SCREEN_H_BY_DEV=(2400 2400)
COMPOSE_HEIGHT=1080
f2="$(build_concat_filter 2)"
expect "two devices build two hstacks" \
  "$(printf '%s' "$f2" | grep -o 'hstack=inputs=2' | wc -l | tr -d ' ')" "2"
expect "inputs are ordered segment-major" \
  "$(printf '%s' "$f2" | grep -o '\[[0-9]:v\]' | tr -d '\n')" "[0:v][1:v][2:v][3:v]"
# ffmpeg names a filter chain's output with a label on its trailing side, so the
# pane is `[<input>]scale=<pane_w>:<h>...[s<s>d<d>]`. The input index is what
# pins the pane to a device, and it is segment-major, so [0:v] is segment 0
# device 1 and [1:v] is segment 0 device 2.
expect_contains "device 1 pane is scaled to its width" "$f2" \
  "[0:v]scale=486:1080:force_original_aspect_ratio=decrease,pad=486:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s0d1]"
expect_contains "device 2 pane is scaled to its width" "$f2" \
  "[1:v]scale=486:1080:force_original_aspect_ratio=decrease,pad=486:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s0d2]"
expect_contains "hstack joins the two panes" "$f2" "[s0d1][s0d2]hstack=inputs=2[s0h]"
# Chains are separated by semicolons and a label names a chain's output rather
# than starting the next chain, so the graph must read segment 0's stack, then
# segment 1's. Counting separators catches a missing one, which ffmpeg rejects
# outright with "trailing garbage after a filter".
# 2 segments x 2 panes + 2 hstacks + 1 concat + 1 outv, less the leading one.
expect "every chain is semicolon separated" \
  "$(printf '%s' "$f2" | tr -cd ';' | wc -c | tr -d ' ')" "7"
expect_contains "panes are concat in order" "$f2" "[s0h][s1h]concat=n=2:v=1:a=0[outvraw]"
expect_contains "trailing normalization" "$f2" "[outvraw]fps=30,format=yuv420p[outv]"
expect "every stream is rebased" \
  "$(printf '%s' "$f2" | grep -o 'setpts=PTS-STARTPTS' | wc -l | tr -d ' ')" "4"
expect "no padding filter is emitted" \
  "$(printf '%s' "$f2" | grep -c 'tpad' || true)" "0"

SCREEN_W_BY_DEV=(1080 720)
SCREEN_H_BY_DEV=(2400 1600)
expect "mismatched aspects get different pane widths" \
  "$(printf '%s' "$(build_concat_filter 1)" | grep -o 'scale=[0-9]*:1080' | tr '\n' ' ')" \
  "scale=486:1080 scale=486:1080 "

SCREEN_W_BY_DEV=(1080 1920)
SCREEN_H_BY_DEV=(2400 1080)
expect "a landscape second device gets its own pane width" \
  "$(printf '%s' "$(build_concat_filter 1)" | grep -o 'scale=[0-9]*:1080' | tr '\n' ' ')" \
  "scale=486:1080 scale=1920:1080 "

# ------------------------------------------------------------- input order
# The input list and the filter graph have to agree on which recording is which
# pane, and neither can see the other: the driver fills its -i slots from
# compose_input_order, the graph numbers its inputs with compose_input_index. A
# disagreement is invisible, since ffmpeg renders whatever pairing it is given,
# so the two are pinned against each other here rather than one being asserted
# and the other assumed.
DEVICE_COUNT=2
SCREEN_W_BY_DEV=(1080 1080)
SCREEN_H_BY_DEV=(2400 2400)
f3="$(build_concat_filter 3)"
expect "the input list is segment-major" \
  "$(compose_input_order 3 | tr '\n' ';' | sed 's/;$//')" \
  "0 1;0 2;1 1;1 2;2 1;2 2"
# Every (segment, device) the input list yields must be the pair the graph names
# at that input's index. Reading the graph's own labels back gives the pairing it
# will actually use, so this fails if either half moves.
graph_pairs() {
  printf '%s' "$f3" | tr ';' '\n' \
    | sed -n 's/^\[\([0-9]*\):v\].*\[s\([0-9]*\)d\([0-9]*\)\]$/\1 \2 \3/p'
}
expect "each input index pairs with the pane the graph names at it" \
  "$(graph_pairs | tr '\n' ';' | sed 's/;$//')" \
  "0 0 1;1 0 2;2 1 1;3 1 2;4 2 1;5 2 2"
# The pane the graph builds for a pair must read the input that the list files
# under that pair's *position*, and not merely the index compose_input_index
# computes for it: those two are the same value only while the list is in the
# order the index assumes, so comparing against the position is what makes a
# reordered list visible. Three segments and two devices is the smallest case
# where the two orders differ at all; on a single segment they coincide, which
# is why this cannot be checked on the one-segment recorded run further down.
mismatch=0
nth=0
while read -r s d; do
  graph_idx="$(printf '%s' "$f3" | tr ';' '\n' \
    | sed -n "s/^\[\([0-9]*\):v\].*\[s${s}d${d}\]\$/\1/p")"
  [ "$graph_idx" = "$nth" ] || mismatch=$((mismatch + 1))
  nth=$((nth + 1))
done < <(compose_input_order 3)
expect "every pane reads the input its own list position files" "$mismatch" "0"
# A one-device run still enumerates one input per segment, so phase 4's loop
# shape is the same for both, and DEVICE_COUNT unset means one device.
DEVICE_COUNT=1
expect "one device lists one input per segment" \
  "$(compose_input_order 3 | tr '\n' ';' | sed 's/;$//')" "0 1;1 1;2 1"
unset DEVICE_COUNT
expect "an unset device count means one device" \
  "$(compose_input_order 2 | tr '\n' ';' | sed 's/;$//')" "0 1;1 1"
expect "and the geometry defaults instead of erroring" \
  "$(build_compose_geometry 1080; printf '%s x %s' "$COMPOSE_W" "$COMPOSE_H")" "1080 x 2400"

# The library's functions stay defined, but the state this section set is not
# left behind: DEVICE_COUNT=2 and the geometry arrays would silently apply to
# every section that follows, which is a trap for whoever adds the next one.
unset COMPOSE_HEIGHT f2 f3 geom graph_pairs DEVICE_COUNT
unset SCREEN_W_BY_DEV SCREEN_H_BY_DEV
expect "the compositing section leaves no device count behind" "${DEVICE_COUNT:-<unset>}" "<unset>"
expect "and no geometry arrays" \
  "$(declare -p SCREEN_W_BY_DEV 2>&1 | grep -c 'not found' || true)" "1"

# ---------------------------------------------------------------- demo driver smoke
help_out="$("$DEMO" --help 2>&1)"
expect_contains "--loose is documented in --help" "$help_out" "--loose"
rc=0
"$DEMO" --loose --help >/dev/null 2>&1 || rc=$?
expect "--loose is accepted by the parser" "$rc" "0"

expect_grep "phase-4 concat forces cfr frame rate" "$DEMO" "-fps_mode cfr"
# The concat's trailing fps=30 lives in the compositing library now that the
# graph is built there, so the 30fps assertion moved with it. The cfr mode and
# keyframe flags stay on the driver's ffmpeg line.
expect_grep "phase-4 concat normalizes to 30fps" "$ROOT/android-compose-lib.sh" "fps=30"
expect_grep "phase-4 concat forces keyframes" "$DEMO" "keyint_min 30"
expect_grep "TIGHT pacing is configurable" "$DEMO" "TIGHT_OPT"
# The demo driver sources the library, so these guards are checked where they
# now live rather than against a copy that no longer exists in the demo.
expect_grep "autorotate guard wired into the shared library" "$LIB" "GUARD_AUTOROTATE"
expect_grep "radio guard wired into the shared library" "$LIB" "GUARD_RADIO_TOGGLE_USB_ONLY"
expect_grep "type settle wired into the shared library" "$LIB" "TYPE_FOCUS_SETTLE_SECONDS"
expect_grep "shared library poll_bounds honors knobs" "$LIB" "POLL_MAX_ATTEMPTS"
expect_grep "demo sources the shared library" "$DEMO" '^source "\${SCRIPT_DIR}/android-ui-lib\.sh"$'
# Phase 4's filter comes from the compositing library now, so a driver that
# stopped sourcing it would call an undefined build_concat_filter and pass an
# empty graph to ffmpeg. Nothing else in the suite would notice.
expect_grep "demo sources the compositing library" "$DEMO" '^source "\${SCRIPT_DIR}/android-compose-lib\.sh"$'
expect_grep "spec-test snapshots auto-rotate before steps" "$SPEC" "autorotate_snapshot"
expect_grep "spec-test restores auto-rotate on exit" "$SPEC" "autorotate_restore; rm -rf"

expect_contains "--serial-2 is documented" "$help_out" "--serial-2"
expect_contains "--compose-height is documented" "$help_out" "--compose-height"
# The device field is the one per-step field neither driver's help used to
# document, and it is the field the second-device feature turns on. Nothing else
# here reads --help, so without these two it could go missing again unnoticed.
# Matched with a regex rather than a fixed substring so that rewrapping the
# comment does not redden them over cosmetics.
expect_match "the device step field is documented in --help" \
  "$help_out" '^  device +1 \(the default\) or 2'
rc=0
"$DEMO" --serial-2 SER2 --app-id-2 com.other.app --compose-height 1440 --help >/dev/null 2>&1 || rc=$?
expect "second-device flags parse" "$rc" "0"

spec_help="$("$SPEC" --help 2>&1)"
expect_contains "spec documents --serial-2" "$spec_help" "--serial-2"
expect_match "spec documents the device step field" \
  "$spec_help" '^Step fields: .*"device"'
# The spec driver's help is derived from its comment block instead of a line
# range, and this is what holds it to that. A hard-coded range there fell two
# lines behind the block once and quietly dropped the last two documented
# fields from --help while every other assertion stayed green. The count
# compares the script's own output against a fresh scan of the file; the
# contains pins the block's last line directly, with no scan involved, so the
# pair fails even if the two scans were to agree on the wrong thing.
expect "the spec driver's help covers its whole comment block" \
  "$("$SPEC" --help 2>&1 | wc -l | tr -d ' ')" \
  "$(awk 'NR > 1 && $0 !~ /^#/ {exit} NR > 1 {print}' "$SPEC" | wc -l | tr -d ' ')"
expect_contains "and reaches the block's last documented line" \
  "$spec_help" "then, else    arrays of steps (may nest more ifs)"
rc=0
"$SPEC" --serial-2 SER2 --app-id-2 com.other.app --help >/dev/null 2>&1 || rc=$?
expect "spec second-device flags parse" "$rc" "0"

# ------------------------------------------------------- second-device resolution
# Serials, activities and screen sizes are resolved by shelling out to adb, so
# the only honest way to test that wiring is to hand a driver a fake adb and read
# back what it asked for. ADB_CALLS logs every call, FAKE_DEVICES is what
# `adb devices` answers with, and SER1 reports a 1080x2400 screen while any other
# serial reports 720x1600, so a size read aimed at the wrong device shows up as a
# wrong number instead of a plausible one. FAKE_RESOLVE replaces the
# package manager's whole answer, to reach the resolver's fallbacks. A
# SIZELESS* serial hits the stub's "Override size: N/A" branch, so a wm size
# with nothing parseable in it comes back; SIZELESS_PAIR below pairs two.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/adb" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ADB_CALLS"
if [ "${1:-}" = "devices" ]; then
  printf 'List of devices attached\n%s\n' "$FAKE_DEVICES"
  exit 0
fi
serial=""
[ "${1:-}" = "-s" ] && serial="$2"
case "$*" in
  *"wm size"*)
    case "$serial" in
      SER1)     echo "Physical size: 1080x2400" ;;
      SIZELESS*) echo "Override size: N/A" ;;
      *)        echo "Physical size: 720x1600" ;;
    esac ;;
  *resolve-activity*)
    if [ -n "${FAKE_RESOLVE:-}" ]; then
      printf '%s\n' "$FAKE_RESOLVE"
    else
      for last; do :; done
      printf 'priority=0 preferredOrder=0 match=0x108000\n%s/.MainActivity\n' "$last"
    fi ;;
  # One serial per value the driver has to handle, so a restore that drops any
  # of them is visible: 0 off, 1 important interruptions, 2 total silence,
  # 3 alarms only, null for a device that never set it, and GARBAGE for a read
  # the driver must refuse to write back.
  *"get global zen_mode"*)
    case "$serial" in
      SER1) echo "0" ;;
      ZEN1) echo "1" ;;
      ZEN3) echo "3" ;;
      ZENNULL) echo "null" ;;
      GARBAGE) echo "not-a-zen-mode" ;;
      *) echo "2" ;;
    esac ;;
  *accelerometer_rotation*) echo "1" ;;
  # A real pull writes the destination, and the driver checks for that file, so a
  # stub that did not would make every device in every run look like a failed
  # pull. NOPULL fails the way a device that dropped off mid-segment does: the
  # pull itself fails and no file appears.
  *pull*_android_demo_seg*)
    if [ "$serial" = "NOPULL" ]; then
      echo "adb: error: failed to stat remote object" >&2
      exit 1
    fi
    for last; do :; done
    : > "$last" ;;
esac
exit 0
STUB
# A fake ffmpeg in the same stub dir, for the one thing the adb log cannot see:
# the argument list phase 4 actually hands ffmpeg. The input order is the point,
# since a mispaired -i still renders a plausible video, so it has to be read off
# the invocation rather than inferred from the graph. Every argument is logged on
# its own line, which is what makes "-i b.mp4 -i a.mp4" distinguishable from
# "-i ba.mp4". The stub creates the output file so the run carries on to phase 5.
cat > "$STUB_DIR/ffmpeg" <<'STUB'
#!/usr/bin/env bash
for arg; do printf '%s\n' "$arg" >> "$FFMPEG_ARGS"; done
printf -- '---\n' >> "$FFMPEG_ARGS"
for last; do :; done
: > "$last"
exit 0
STUB
chmod +x "$STUB_DIR/adb" "$STUB_DIR/ffmpeg"
CALLS="$(mktemp)"
EMPTY_STEPS="$(mktemp)"
EMPTY_SCENARIOS="$(mktemp)"
LAUNCH_SCENARIOS="$(mktemp)"
MIXED_STEPS="$(mktemp)"
SIMPLE_STEPS="$(mktemp)"
APP2_STEPS="$(mktemp)"
MIXED_SCENARIOS="$(mktemp)"
printf '[]\n' > "$EMPTY_STEPS"
printf '[]\n' > "$EMPTY_SCENARIOS"
# One scenario that launches, so the resolved activity is visible as the
# component the driver actually asks the device to start.
printf '[{"name":"launches","steps":[{"action":"launch"}]}]\n' > "$LAUNCH_SCENARIOS"
# A recording whose steps all do different things, so each keyevent in the call
# log identifies exactly one step: device 2 is named on one leaf and on the if
# that follows it, and on neither the else arm nor the last leaf. A step that
# inherited the cursor, or defaulted wrongly, moves a keyevent to another serial
# and breaks a count. The if's text is never on screen, so the else arm runs and
# the then arm's launch must never appear in the log.
cat > "$MIXED_STEPS" <<'JSON'
[
  {"action":"back"},
  {"action":"if","device":2,"source":"screen","text":"Login","timeout_seconds":0,
   "then":[{"action":"launch","device":1}],
   "else":[{"action":"dismiss_keyboard"}]},
  {"action":"home_button","device":2},
  {"action":"back"}
]
JSON
# The same shape with every device field dropped, for the single-device runs
# where a device 2 step is refused.
printf '[{"action":"back"},{"action":"dismiss_keyboard"}]\n' > "$SIMPLE_STEPS"
# Every action perform_action routes through the bare APP_ID/ACTIVITY, on a
# device 2 step, so the cursor's app is what gets asked for.
printf '[{"action":"launch","device":2},{"action":"pm_clear","device":2},{"action":"reopen","device":2}]\n' > "$APP2_STEPS"
# The spec driver's own dispatch, as scenarios rather than steps. Which serial a
# command reached is the only honest read on which device the driver dispatched a
# step to, so every step here does something the adb call log can tell apart, and
# each is placed so that "dispatched to its own device" and "left the cursor where
# the previous step left it" produce different logs:
#   s0  back, no device              -> device 1
#   s1  if, device 2                 -> its screen condition is read from device 2
#       (the cursor is on device 1 going in, so an undispatched if reads device 1)
#   s1.then tap_xy 5 6, device 1     -> never runs: "Login" is never on screen
#   s1.else tap_xy 7 8, device 1     -> device 1, although its if named device 2,
#                                        so a branch step dispatches on its own
#   s2  exec, no device              -> device 1's exec slot is what now holds it
#   s3  dismiss_keyboard, no device  -> device 1, right after device 2 steps above
#   s4  if, device 2                 -> device 2's exec slot is EMPTY, so the else
#                                        arm runs. On device 1 it would read the
#                                        exec s2 just ran there, and take the then
#   s4.then home_button, device 2    -> never runs
#   s4.else tap_xy 11 12, device 2   -> device 2, so a branch step routed on its
#                                        own device rather than its if's
#   s5  exec, device 2               -> device 2's exec slot now holds it
#   s6  if, device 2                 -> reads that, so the THEN arm runs; on
#                                        device 1 it would read s2 and take the
#                                        then arm too, but s6.then's action would
#                                        then land on device 1
#   s6.then home_button, device 2    -> device 2, inside the taken branch
#   s6.else launch                   -> never runs
#   s7  pm_clear, device 2           -> device 2's own app
#   s8  pm_clear, no device          -> device 1 and device 1's own app
# A second scenario, so the first failing still leaves this one to run: a step
# that fails must fail its own scenario, which is this driver's whole contract.
cat > "$MIXED_SCENARIOS" <<'JSON'
[
  {"name":"routes each step to its device",
   "steps":[
     {"action":"back","settle_ms":0},
     {"action":"if","device":2,"source":"screen","text":"Login","timeout_seconds":0,
      "then":[{"action":"tap_xy","x":5,"y":6,"device":1}],
      "else":[{"action":"tap_xy","x":7,"y":8,"device":1}]},
     {"action":"exec","command":"echo exec ran on $DEMO_SERIAL"},
     {"action":"dismiss_keyboard","settle_ms":0},
     {"action":"if","device":2,
      "then":[{"action":"home_button","device":2}],
      "else":[{"action":"tap_xy","x":11,"y":12,"device":2}]},
     {"action":"exec","device":2,"command":"echo exec ran on $DEMO_SERIAL"},
     {"action":"if","device":2,
      "then":[{"action":"home_button","device":2}],
      "else":[{"action":"launch"}]},
     {"action":"pm_clear","device":2},
     {"action":"pm_clear","settle_ms":0}
   ]},
  {"name":"runs after a failed scenario","steps":[{"action":"back","settle_ms":0}]}
]
JSON

drive() { # drive <fake-devices> <driver> <driver args...>
  local runner
  FAKE_DEVICES="$1"; shift
  runner="$1"; shift
  : > "$CALLS"
  FFMPEG_ARGS=""
  DRIVE_RC=0
  # TRACED=1 traces the driver so the per-device arrays it builds can be read
  # back; nothing else exposes them until step dispatch can target device 2.
  # The stub ffmpeg logs to a file rather than a variable, since it is a separate
  # process; a fresh one per run keeps each run's argument list to itself.
  FFMPEG_LOG="$(mktemp)"
  DRIVE_OUT="$(ADB_CALLS="$CALLS" FAKE_DEVICES="$FAKE_DEVICES" \
               FAKE_RESOLVE="${FAKE_RESOLVE:-}" FFMPEG_ARGS="$FFMPEG_LOG" \
               PATH="$STUB_DIR:$PATH" \
               bash ${TRACED:+-x} "$runner" --app-id com.example.app "$@" 2>&1)" || DRIVE_RC=$?
  DRIVE_CALLS="$(cat "$CALLS")"
  DRIVE_FFMPEG="$(cat "$FFMPEG_LOG")"
  rm -f "$FFMPEG_LOG"
}
# The concat invocation's -i arguments in the order they were passed, one per
# line, reduced to the bare segment file names so a work directory in the path
# does not have to be stripped and the expectation can name seg_0_1.mp4.
# The value that followed a given -i in the logged argument list, one per line
# with the bare segment file name, so the expectation can say seg_0_1.mp4 and
# the work directory in the path does not have to be stripped. Reading the
# value from the line after -i is what distinguishes "-i b.mp4 -i a.mp4" from a
# single "-i ba.mp4", so the order in the log is the order ffmpeg was given.
concat_inputs() { # concat_inputs <driver-scoped ffmpeg arg log>
  printf '%s\n' "$1" | awk '/^-i$/{getline; n=split($0, p, "/"); print p[n]}'
}
# The filter graph from the logged argument list, i.e. what phase 4 paired with
# the inputs above rather than what the library would produce now.
concat_graph() { # concat_graph <driver-scoped ffmpeg arg log>
  printf '%s\n' "$1" | awk '/^-filter_complex$/{getline; print; exit}'
}
count_calls() { printf '%s\n' "$1" | grep -c -- "$2" | tr -d ' '; }
# The distinct serials a run addressed, in first-seen order. Counting serials
# rather than asserting one is absent is what makes "only the named device was
# contacted" an assertion that can actually fail.
serials_touched() {
  printf '%s\n' "$1" | sed -n 's/^-s \([^ ]*\) .*/\1/p' | awk '!seen[$0]++' | tr '\n' ','
}

PHONE_AND_EMULATOR='SER1  device usb:1-1
emulator-5554  device product:sdk_gphone64'
TWO_PHONES_AND_EMULATOR='SER1  device usb:1-1
SER2  device usb:1-2
emulator-5554  device'

# A lone emulator is a candidate for device 2 even though the primary
# auto-detect filters emulators out, which is the whole point of the feature.
drive "$PHONE_AND_EMULATOR" "$DEMO" --serial SER1 --dry-run --steps "$EMPTY_STEPS"
expect "a phone plus one emulator runs" "$DRIVE_RC" "0"
expect_contains "the lone other device, an emulator, becomes device 2" \
  "$DRIVE_OUT" "==> recording 2 devices: SER1 and emulator-5554"
expect "device 2 reaches the library's per-device loop too, on the snapshot and the restore" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell settings get system accelerometer_rotation')" "2"
expect "device 2's screen size is read from device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell wm size')" "1"
expect_contains "device 2 hosts the same app by default" "$DRIVE_CALLS" \
  "-s emulator-5554 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.example.app"

# Without --serial the primary auto-detect still skips the emulator, and picks
# the phone, while device 2 adopts it.
drive "$PHONE_AND_EMULATOR" "$DEMO" --dry-run --steps "$EMPTY_STEPS"
expect "auto-detect over a phone and an emulator runs" "$DRIVE_RC" "0"
expect_contains "the primary auto-detect still skips emulators" \
  "$DRIVE_OUT" "device SER1 (com.example.app/.MainActivity)"
expect_contains "and that emulator is still adopted as device 2" \
  "$DRIVE_OUT" "==> recording 2 devices: SER1 and emulator-5554"

# Two phones and no --serial stays fatal, as before.
drive "$TWO_PHONES_AND_EMULATOR" "$DEMO" --dry-run --steps "$EMPTY_STEPS"
expect "several phones and no --serial is still fatal" "$DRIVE_RC" "1"
expect_contains "and still names the flag that disambiguates" \
  "$DRIVE_OUT" "2 devices connected; pass one with --serial"

# With --serial naming one of them, two others is a reason to stay
# single-device rather than to guess which one to pair.
drive "$TWO_PHONES_AND_EMULATOR" "$DEMO" --serial SER1 --dry-run --steps "$EMPTY_STEPS"
expect "two others still runs, single-device" "$DRIVE_RC" "0"
expect_contains "the two others are reported" \
  "$DRIVE_OUT" "2 other devices are attached but --serial-2 was not given"
expect_contains "and so is the list to pick from" "$DRIVE_OUT" "SER2  device usb:1-2"
expect_no_contains "no two-device banner without --serial-2" "$DRIVE_OUT" "recording 2 devices"
# Three serials are attached here and one was named, so this can fail: it is a
# statement about which serials were addressed, not about one that cannot appear.
expect "only the named serial of the three attached ones is contacted" \
  "$(serials_touched "$DRIVE_CALLS")" "$SERIAL_A,"

# One device on its own never reaches the device-2 branch at all.
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --dry-run --steps "$EMPTY_STEPS"
expect "a lone device runs" "$DRIVE_RC" "0"
expect_no_contains "a lone device stays a single-device run" "$DRIVE_OUT" "recording 2 devices"
expect "a lone device reads one screen size" \
  "$(count_calls "$DRIVE_CALLS" 'shell wm size')" "1"

# An explicit --serial-2 is taken as given, attached or not, so it has to make
# device 2 live in its own right rather than relying on auto-detection.
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --serial-2 emulator-5554 \
  --dry-run --steps "$EMPTY_STEPS"
expect "an explicit --serial-2 runs" "$DRIVE_RC" "0"
expect_contains "the named serial is device 2, attached or not" \
  "$DRIVE_OUT" "==> recording 2 devices: SER1 and emulator-5554"
expect "an explicit --serial-2 reaches the library's per-device loop too" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell settings get system accelerometer_rotation')" "2"

drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --serial-2 SER1 \
  --dry-run --steps "$EMPTY_STEPS"
expect "--serial-2 equal to --serial is refused" "$DRIVE_RC" "1"
expect_contains "the refusal names the clash" \
  "$DRIVE_OUT" "--serial-2 is the same device as --serial (SER1)"

# --app-id-2 gets the same bare-package-id check --app-id has, so a malformed
# value says so instead of resolving to a doubled component path.
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --app-id-2 com.other.app/.MainActivity \
  --dry-run --steps "$EMPTY_STEPS"
expect "a component in --app-id-2 is refused" "$DRIVE_RC" "1"
expect_contains "and names the flag and its own fix" "$DRIVE_OUT" \
  "--app-id-2 takes a bare package id"
expect "and nothing was asked of any device" "$DRIVE_CALLS" ""

# A device whose `wm size` answers with nothing parseable must not take the run
# down: read returns non-zero on EOF, which under the demo driver's set -e would
# abort silently and leave the assumed-size fallback below it unreachable.
SIZELESS_PAIR='SIZELESS  device usb:1-1
SIZELESS2  device usb:1-2'
TRACED=1
drive "$SIZELESS_PAIR" "$DEMO" --serial SIZELESS --serial-2 SIZELESS2 \
  --dry-run --steps "$EMPTY_STEPS"
unset TRACED
expect "devices with no readable screen size still run" "$DRIVE_RC" "0"
expect_match "device 1 falls back to the assumed width" "$DRIVE_OUT" '^\+* SCREEN_W=1080$'
expect_match "device 1 to the assumed height" "$DRIVE_OUT" '^\+* SCREEN_H=2400$'
expect_match "device 2 falls back to the assumed width" \
  "$DRIVE_OUT" '^\+* SCREEN_W_BY_DEV\[1\]=1080$'
expect_match "device 2 to the assumed height" "$DRIVE_OUT" '^\+* SCREEN_H_BY_DEV\[1\]=2400$'

# --app-id-2 reaches device 2's resolution without disturbing device 1's.
drive "$PHONE_AND_EMULATOR" "$DEMO" --serial SER1 --app-id-2 com.other.app \
  --dry-run --steps "$EMPTY_STEPS"
expect_contains "device 2 resolves the app it was given" \
  "$DRIVE_CALLS" "-s emulator-5554 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.other.app"
expect_contains "device 1 still resolves its own app" \
  "$DRIVE_CALLS" "-s SER1 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.example.app"

# What the driver actually resolved for device 2, read off its own trace. These
# are the array entries use_device() reads, and nothing outside the script can
# see them until steps can name a device. --activity-2 here as well, so this
# covers the override path into slot 2 and the query it makes unnecessary.
TRACED=1
drive "$PHONE_AND_EMULATOR" "$DEMO" --serial SER1 --app-id-2 com.other.app \
  --activity-2 .Custom --dry-run --steps "$EMPTY_STEPS"
unset TRACED
expect_match "device 2's screen width lands in slot 2" \
  "$DRIVE_OUT" '^\+* SCREEN_W_BY_DEV\[1\]=720$'
expect_match "device 2's screen height lands in slot 2" \
  "$DRIVE_OUT" '^\+* SCREEN_H_BY_DEV\[1\]=1600$'
expect_match "device 2's app lands in slot 2" \
  "$DRIVE_OUT" '^\+* APP_BY_DEV\[1\]=com\.other\.app$'
expect_match "device 2's activity override lands in slot 2" \
  "$DRIVE_OUT" '^\+* ACTIVITY_BY_DEV\[1\]=com\.other\.app/\.Custom$'
expect_no_contains "an --activity-2 override skips the query entirely" \
  "$DRIVE_CALLS" "-s emulator-5554 shell cmd package resolve-activity"

# An override that already names a component is used as it stands, not
# re-prefixed with the package.
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --activity com.other.app/.Deep \
  --dry-run --steps "$EMPTY_STEPS"
expect_contains "an absolute --activity is launched unchanged" "$DRIVE_CALLS" \
  "shell am start -n com.other.app/.Deep"
expect_no_contains "and skips the resolve query" "$DRIVE_CALLS" "resolve-activity"

# The demo driver's own copy of resolve_activity_for, on both of its fallbacks:
# the dry run launches the resolved component, so the call log shows what it
# settled on.
FAKE_RESOLVE="No activity found"
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --dry-run --steps "$EMPTY_STEPS"
expect "an empty resolve answer still runs the demo driver" "$DRIVE_RC" "0"
expect_contains "and falls back to the conventional .MainActivity" "$DRIVE_CALLS" \
  "shell am start -n com.example.app/.MainActivity"

FAKE_RESOLVE="com.other.vendor/.DeepLink"
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --dry-run --steps "$EMPTY_STEPS"
expect "a non-matching resolve answer still runs the demo driver" "$DRIVE_RC" "0"
expect_contains "and takes the one component that came back" "$DRIVE_CALLS" \
  "shell am start -n com.other.vendor/.DeepLink"
unset FAKE_RESOLVE

# --------------------------------------------------------------- step dispatch
# A step's device field is only real if the driver actually moves the cursor
# before running the step, and the honest way to see that is to read back which
# serial each command reached. Every step in MIXED_STEPS does something
# different, so each keyevent in the call log belongs to exactly one step and a
# step that inherited the cursor, or defaulted wrongly, breaks a count.
# Traced, so this one run also answers which entry point dispatched each step,
# which nothing else exposes. The call log is unaffected by tracing.
TRACED=1
drive "$PHONE_AND_EMULATOR" "$DEMO" --serial SER1 --app-id-2 com.other.app \
  --dry-run --steps "$MIXED_STEPS"
unset TRACED
DRY_TRACE="$DRIVE_OUT"
expect "a dry run over two devices with per-step devices runs" "$DRIVE_RC" "0"
expect "the device 2 leaf reaches device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent KEYCODE_HOME')" "1"
expect "and never device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent KEYCODE_HOME')" "0"
expect "the two device 1 leaves both reach device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent KEYCODE_BACK')" "2"
expect "and no device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent KEYCODE_BACK')" "0"
expect "a branch leaf with no device falls back to device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent 111')" "1"
expect "and not to device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent 111')" "0"
# The if's text is never on screen, so the untaken then arm, whose only step is
# a launch, must never have run.
expect_no_contains "the untaken then arm never ran" "$DRIVE_CALLS" "am force-stop"
at_least "the if's condition is read from device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell uiautomator dump')" "1"
expect "and never from device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell uiautomator dump')" "0"
expect_contains "a dry run names the device a step routed to" "$DRIVE_OUT" \
  "-- dry step 0.2: home_button  [device 2]"
# Every dispatched step goes through step_device, or a step runs on whichever
# device the one before it left behind. Five steps dispatch here: two top-level
# leaves, the if, its else-arm leaf, and the last leaf. The recorded trace below
# is the same count through the other two entry points.
expect "the dry run dispatches every step through step_device" \
  "$(count_calls "$DRY_TRACE" '^+ step_device ')" "5"
# Three: two device 2 dispatches plus the per-device pre-launch below.
expect "its device 2 steps move the cursor to 2" \
  "$(count_calls "$DRY_TRACE" '^+ use_device 2$')" "3"
# The pre-launch has to cover device 2 too, or a device 2 step is driven against
# whatever that device happened to be showing. With --app-id-2 the two devices
# host different apps, so this also shows the pre-launch reads the per-device one.
expect_contains "a dry run pre-launches device 2's app on device 2" "$DRIVE_CALLS" \
  "-s emulator-5554 shell am start -n com.other.app/.MainActivity"
expect_contains "and still pre-launches device 1's own app on device 1" "$DRIVE_CALLS" \
  "-s SER1 shell am start -n com.example.app/.MainActivity"
# A dry run captures no sound, so it must not touch DND on either device.
expect "a dry run leaves DND alone" \
  "$(count_calls "$DRIVE_CALLS" 'zen_mode\|set_dnd')" "0"

# A device the run never attached is refused before anything is asked of it,
# rather than pointing the cursor at an empty serial and failing later as a
# confusing adb error.
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --dry-run --steps "$MIXED_STEPS"
expect "a device 2 step in a single-device run is refused" "$DRIVE_RC" "1"
expect_contains "and the refusal names the flag that would add it" "$DRIVE_OUT" "--serial-2"
# Only the first leaf ran, the one that names no device. The device 2 step is
# refused before its action is dispatched, so its keyevent never goes anywhere.
expect "nothing was dispatched after the refusal" \
  "$(count_calls "$DRIVE_CALLS" 'input keyevent')" "1"

# The same steps through the recorded path rather than the dry run, which reaches
# the other two entry points: run_leaf_step and run_steps, not dry_run_steps.
# Traced, so this one run answers both what reached which serial (the adb call
# log, which tracing does not change) and which entry points moved the cursor
# (the trace, which nothing else exposes). It also covers the recorder pump and
# the DND hygiene, because all three are read off that same call log.
TRACED=1
drive "$PHONE_AND_EMULATOR" "$DEMO" --serial SER1 --no-narration --steps "$MIXED_STEPS" \
  --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
unset TRACED
RECORDED_TRACE="$DRIVE_OUT"
expect "a recorded device 2 leaf still reaches device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent KEYCODE_HOME')" "1"
expect "and never device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent KEYCODE_HOME')" "0"
expect "and both recorded device 1 leaves reach device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent KEYCODE_BACK')" "2"
at_least "the recorded if reads its condition from device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell uiautomator dump')" "1"
expect "and the else arm's leaf ran on device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent 111')" "1"
expect "with no keyevent of its own going to device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent 111')" "0"

# Segments are per (segment, device), and the pump runs in three ordered phases:
# signal every device, wait for every device, then pull every device.
#
# The adb call log alone cannot order the phases: `wait` is a shell builtin, not
# an adb call, so the log shows every pkill before every pull whether or not a
# wait happens in between. The trace can, because it records the wait itself.
# Each phase appears once per device, so the sequence below is what separates
# three loops from the two shapes that get it wrong:
#   wait moved after pull:   signal,signal,pull,pull,wait,wait
#   wait deleted:            signal,signal,pull,pull
#   per-device {wait;pull}:  signal,signal,wait,pull,wait,pull
PUMP_PHASES="$(printf '%s\n' "$RECORDED_TRACE" \
  | grep -E '^\+ (ADB_FOR [0-9]+ shell pkill -INT screenrecord|ADB_FOR [0-9]+ pull /sdcard/_android_demo_seg|wait [0-9]+)' \
  | sed -E 's/^\+ ADB_FOR [0-9]+ (shell )?(pkill|pull) .*/\2/; s/^\+ wait [0-9]+.*/wait/' \
  | tr '\n' ',')"
expect "the pump signals every device, then waits for all of them, then pulls" \
  "$PUMP_PHASES" \
  "pkill,pkill,wait,wait,pull,pull,"
# The phase sequence above already fails for all three wrong shapes, since only
# three loops put every wait before every pull. Pin the counts anyway, because a
# fourth shape that waits more or less often would still be a bug.
count_occurrences "the wait phase waits once per device" "$PUMP_PHASES" 'wait,' "2"
count_occurrences "the signal phase signals once per device" "$PUMP_PHASES" 'pkill,' "2"
count_occurrences "the pull phase pulls once per device" "$PUMP_PHASES" 'pull,' "2"
# The recorder's own adb calls, in order, as a cross-check that the trace-derived
# phases describe the same run.
PUMP_ORDER="$(printf '%s\n' "$DRIVE_CALLS" \
  | grep -E 'screenrecord --bit-rate|pkill -INT screenrecord|pull /sdcard/_android_demo_seg' \
  | sed -E 's/^-s [^ ]+ shell //; s/^-s [^ ]+ //; s/ .*//' | tr '\n' ',')"
expect "the pump launches, signals, then pulls, per device in that order" \
  "$PUMP_ORDER" \
  "screenrecord,screenrecord,pkill,pkill,pull,pull,"
expect_contains "device 1 records to its own on-device file" "$DRIVE_CALLS" \
  "/sdcard/_android_demo_seg_0_1.mp4"
expect_contains "device 2 records to its own on-device file" "$DRIVE_CALLS" \
  "/sdcard/_android_demo_seg_0_2.mp4"
expect_contains "device 1 is pulled to its own local file" "$DRIVE_CALLS" \
  "video/seg_0_1.mp4"
expect_contains "device 2 is pulled to its own local file" "$DRIVE_CALLS" \
  "video/seg_0_2.mp4"
expect "each device's on-device file is cleaned up" \
  "$(count_calls "$DRIVE_CALLS" 'shell rm -f /sdcard/_android_demo_seg_0_')" "2"

# What phase 4 hands ffmpeg, read off the invocation above. This is the
# assertion the negative control showed was missing: mutating the driver's loop to
# device-major left every other assertion green, because a mispaired input list
# still renders a plausible 972x1080 video and nothing else in the run can see it.
# Both facts below come out of one real run: the -i values in the order they were
# passed, and the graph that was passed with them.
RECORDED_INPUTS="$(concat_inputs "$DRIVE_FFMPEG")"
RECORDED_GRAPH="$(concat_graph "$DRIVE_FFMPEG")"
expect "phase 4 passes the inputs segment-major, device 1 first" \
  "$(printf '%s' "$RECORDED_INPUTS" | tr '\n' ',')" "seg_0_1.mp4,seg_0_2.mp4"
# And the two halves against each other on that same run: reading the pane labels
# back out of the graph and requiring pane N to come from input N. ffmpeg accepts
# any pairing and renders it, so nothing short of this comparison notices.
mispair=0
nth_input=0
while read -r seg_file; do
  # The file name is where the driver put that recording, so the pair is read
  # off the run rather than off the library that produced it.
  sd="${seg_file#seg_}"; s="${sd%%_*}"
  case "$sd" in
    # seg_<s>_<d>.mp4, so what is left after the last _ is the device.
    *_*) d="${sd##*_}"; d="${d%.mp4}" ;;
    *) d="" ;;
  esac
  pane="$(printf '%s' "$RECORDED_GRAPH" \
    | tr ';' '\n' | sed -n "s/^\[\([0-9]*\):v\].*\[s${s}d${d}\]\$/\1/p")"
  [ "$pane" = "$nth_input" ] || mispair=$((mispair + 1))
  nth_input=$((nth_input + 1))
done <<< "$RECORDED_INPUTS"
expect "every pane reads the input at its own position" "$mispair" "0"
expect "the graph's panes are in input order" \
  "$(printf '%s' "$RECORDED_GRAPH" \
     | grep -c '^\[0:v\].*\[s0d1\];\[1:v\].*\[s0d2\]' || true)" "1"
# The run reports the composite it is about to write, which is what gives
# COMPOSE_W a production consumer: without the banner, build_compose_geometry's
# output would be read only by a test.
expect_contains "and the run names the composite size" "$DRIVE_OUT" \
  "==> Normalizing 1 recording segment to 972x1080"

# Multi-segment order is pinned where it can be, which is the library. The driver
# cannot cut a second segment in this suite because LEAVES_LEFT is 0 rather than
# TOTAL_LEAVES, a defect that predates this task, so a two-segment run is not
# reachable from here. Instead the driver is required to take its order from
# compose_input_order and to have no loop of its own, and the multi-segment order
# is asserted against the library, which is what the driver consumes verbatim.
expect_grep "phase 4 takes its input order from the library" "$DEMO" \
  'done < <(compose_input_order "$SEG_COUNT")'
expect_no_grep "and builds no input loop of its own" "$DEMO" \
  'for d in $(seq 1 "$DEVICE_COUNT")'

# DND is the other host setting a second device needs, and it is where
# recording-silence is set up. Each device must be restored to what it had
# before, addressed by name: at cleanup the cursor holds whatever the last step
# left behind, and this run's last step named no device, so a cursor-following
# restore would land on device 1 for both. The stub answers 0 for SER1 and 2 for
# every other serial, so a restore that flattened everything to one value, or
# followed the cursor, shows up as the wrong number on the wrong serial.
expect "both devices are snapshotted for DND" \
  "$(count_calls "$DRIVE_CALLS" 'shell settings get global zen_mode')" "2"
expect "both devices are muted for the recording" \
  "$(count_calls "$DRIVE_CALLS" 'shell cmd notification set_dnd on')" "2"
expect_contains "device 1's own zen mode is restored" "$DRIVE_CALLS" \
  "-s SER1 shell settings put global zen_mode 0"
expect_contains "device 2's own zen mode is restored, not device 1's" "$DRIVE_CALLS" \
  "-s emulator-5554 shell settings put global zen_mode 2"
expect_no_contains "and no device is handed back a value it never had" "$DRIVE_CALLS" \
  "-s emulator-5554 shell settings put global zen_mode 0"
# A device that already had DND off must not be left with it on: the run muted
# device 1 (zen 0 -> 2) and cleanup has to hand 0 back to that same serial.
expect "a muted device 1 is put back exactly once" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell settings put global zen_mode 0')" "1"

# A value the driver drops is not a small thing: cleanup skips the restore, so
# the phone is left in Do Not Disturb after the demo. AOSP zen_mode has four
# values plus null, and every one of them is a state a user can be in, so each
# gets its own serial here and its own assertion that the value comes back.
# The 0 and 2 cases are the ones already asserted above; these are 1, 3 and null.
drive 'ZEN1  device usb:1-1
ZEN3  device usb:1-2' "$DEMO" --serial ZEN1 --serial-2 ZEN3 --no-narration \
  --steps "$SIMPLE_STEPS" --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect_contains "a phone in important-interruptions-only is put back to 1" \
  "$DRIVE_CALLS" "-s ZEN1 shell settings put global zen_mode 1"
expect_contains "a phone in alarms-only is put back to 3" \
  "$DRIVE_CALLS" "-s ZEN3 shell settings put global zen_mode 3"
expect "both were muted for the recording" \
  "$(count_calls "$DRIVE_CALLS" 'shell cmd notification set_dnd on')" "2"

# null is what a phone that never set zen_mode reads back, and it is still a
# value to restore. GARBAGE is the other half of the same run: a read the driver
# does not recognize is not a setting, so it must not be written back.
drive 'ZENNULL  device usb:1-1
GARBAGE  device usb:1-2' "$DEMO" --serial ZENNULL --serial-2 GARBAGE \
  --no-narration --steps "$SIMPLE_STEPS" --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect_contains "a phone that never set zen_mode is put back to null" \
  "$DRIVE_CALLS" "-s ZENNULL shell settings put global zen_mode null"
expect_contains "a device with an unreadable zen mode is still snapshotted" \
  "$DRIVE_CALLS" "-s GARBAGE shell settings get global zen_mode"
expect_contains "and is still muted for the recording" "$DRIVE_CALLS" \
  "-s GARBAGE shell cmd notification set_dnd on"
expect_no_contains "but its unreadable value is never written back" \
  "$DRIVE_CALLS" "-s GARBAGE shell settings put global zen_mode"

# A pull that fails must cost its own segment, not the whole run. Under set -e an
# unguarded pull aborts inside stop_segment, the EXIT trap fires, and cleanup()
# deletes the workdir along with every segment already pulled, so the observable
# is the one the driver acts on: which device's segment is missing afterwards.
# The stub writes the destination on a successful pull, so the warning names
# exactly the device whose pull failed and no other.
NOPULL_PAIR='SER1  device usb:1-1
NOPULL  device usb:1-2'
drive "$NOPULL_PAIR" "$DEMO" --serial SER1 --serial-2 NOPULL --no-narration \
  --steps "$SIMPLE_STEPS" --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
NOPULL_WD="$(kept_workdir "$DRIVE_OUT")"
expect "the failing device's segment is reported missing, by name" \
  "$(printf '%s\n' "$DRIVE_OUT" | grep -c '==> WARNING: segment 0 for device 2 was not pulled to')" "1"
expect_no_contains "and the device that did pull is not reported missing" \
  "$DRIVE_OUT" "device 1 was not pulled"
expect "the run still got past the pull loop" \
  "$(printf '%s\n' "$DRIVE_OUT" | grep -c '==> Normalizing')" "1"
[ -f "$NOPULL_WD/video/seg_0_1.mp4" ] \
  && note "the device that did pull keeps its footage" \
  || bail "the device that did pull lost its segment"
[ -f "$NOPULL_WD/video/seg_0_2.mp4" ] \
  && bail "the device whose pull failed still has a segment file" \
  || note "the failed pull left no segment file behind"

# With the stub writing the destination on every successful pull, a run where
# every pull works has nothing to report. This is what keeps the warning above
# meaningful: a stub that never wrote the file would make it fire for every
# device in every run, and then the failing case would be indistinguishable.
drive 'SER1  device usb:1-1
SER2  device usb:1-2' "$DEMO" --serial SER1 --serial-2 SER2 --no-narration \
  --steps "$SIMPLE_STEPS" --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect_no_contains "a run whose every pull succeeds reports nothing" \
  "$DRIVE_OUT" "==> WARNING: segment"
CLEAN_WD="$(kept_workdir "$DRIVE_OUT")"
expect "both segments landed on disk" \
  "$(ls "$CLEAN_WD/video" 2>/dev/null | grep -c 'seg_0_[12]\.mp4' || true)" "2"

# Every entry point must move the cursor, or a step can run on whichever device
# the previous one left behind. The three call sites are what make the recorded
# assertions above hold, so count them in that run's trace. Five steps dispatch
# across the two entry points (two top-level leaves, the if, its else-arm leaf,
# and the last leaf), so five step_device calls, and the two device-2 steps are
# the two that land on use_device 2.
expect "every recorded step calls step_device" \
  "$(count_calls "$RECORDED_TRACE" '^+ step_device ')" "5"
expect "its device 2 steps move the cursor to 2" \
  "$(count_calls "$RECORDED_TRACE" '^+ use_device 2$')" "2"

# A single-device run still records, and still names the file per device, so the
# suffix is the same shape rather than a two-device-only convention. It runs
# SIMPLE_STEPS, which names no device at all: MIXED_STEPS is refused here, by the
# step_device check asserted above.
drive 'SER1  device usb:1-1' "$DEMO" --serial SER1 --no-narration --steps "$SIMPLE_STEPS" \
  --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect "a single-device run records device 1" \
  "$(count_calls "$DRIVE_CALLS" 'shell screenrecord')" "1"
expect_contains "and still names its segment per device" "$DRIVE_CALLS" \
  "video/seg_0_1.mp4"
expect_no_contains "with no second device's segment anywhere" "$DRIVE_CALLS" "seg_0_2.mp4"

# perform_action reads the bare APP_ID/ACTIVITY, which use_device has already
# swapped for the cursor's device, so it needs no change of its own. Assert what
# that buys: a device 2 step acts on device 2's app, at device 2's component.
drive "$PHONE_AND_EMULATOR" "$DEMO" --serial SER1 --app-id-2 com.other.app \
  --activity-2 .Custom --no-narration --steps "$APP2_STEPS" \
  --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect_contains "a device 2 launch stops device 2's app" "$DRIVE_CALLS" \
  "-s emulator-5554 shell am force-stop com.other.app"
# Twice: launch and reopen both read the cursor's activity.
expect "launch and reopen both start device 2's own component" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell am start -n com.other.app/.Custom')" "2"
expect "and only ever device 2's, never device 1's" \
  "$(count_calls "$DRIVE_CALLS" 'am start -n')" "2"
expect "pm_clear clears device 2's app" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell pm clear com.other.app')" "1"
expect_no_contains "and device 1's app is never acted on by a device 2 step" \
  "$DRIVE_CALLS" "force-stop com.example.app"
expect_no_contains "nor is device 1 ever the target of these three actions" \
  "$DRIVE_CALLS" "-s SER1 shell am "

# ------------------------------------------------------------- spec driver paths
# The demo driver above always passes --serial, so the spec driver's own copy of
# the primary auto-detect, its duplicate refusal and its two-others warning are
# only reachable here.
drive "$PHONE_AND_EMULATOR" "$SPEC" --scenarios "$EMPTY_SCENARIOS"
expect "the spec driver runs two devices" "$DRIVE_RC" "0"
expect_contains "the spec driver adopts the lone emulator" \
  "$DRIVE_OUT" "==> running 2 devices: SER1 and emulator-5554"
expect "the spec driver reads device 2's screen size" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell wm size')" "1"
expect_contains "and resolves device 2's activity on device 2, on the same app by default" \
  "$DRIVE_CALLS" "-s emulator-5554 shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.example.app"
expect_contains "the spec driver's own auto-detect picks the phone" \
  "$DRIVE_OUT" "entries, device SER1 (com.example.app)"

drive '' "$SPEC" --scenarios "$EMPTY_SCENARIOS"
expect "the spec driver with nothing attached is fatal" "$DRIVE_RC" "1"
expect_contains "and says nothing is connected" "$DRIVE_OUT" "no device connected over USB"

drive "$TWO_PHONES_AND_EMULATOR" "$SPEC" --scenarios "$EMPTY_SCENARIOS"
expect "the spec driver with several phones and no --serial is fatal" "$DRIVE_RC" "1"
expect_contains "and names the flag that disambiguates" \
  "$DRIVE_OUT" "2 devices connected; pass one with --serial"

drive 'SER1  device usb:1-1' "$SPEC" --serial SER1 --serial-2 SER1 \
  --scenarios "$EMPTY_SCENARIOS"
expect "the spec driver refuses a duplicate --serial-2" "$DRIVE_RC" "1"
expect_contains "and names the clash" \
  "$DRIVE_OUT" "--serial-2 is the same device as --serial (SER1)"

drive "$TWO_PHONES_AND_EMULATOR" "$SPEC" --serial SER1 --scenarios "$EMPTY_SCENARIOS"
expect "the spec driver with two others runs single-device" "$DRIVE_RC" "0"
expect_contains "and reports them without guessing" "$DRIVE_OUT" \
  "2 other devices are attached but --serial-2 was not given; running device 1 only"
expect_contains "listing them to pick from" "$DRIVE_OUT" "SER2  device usb:1-2"
expect_no_contains "no two-device banner without --serial-2" "$DRIVE_OUT" "running 2 devices"
expect_no_contains "and neither unchosen device is contacted" "$DRIVE_CALLS" "-s SER2 "
expect_no_contains "the emulator is not contacted either" "$DRIVE_CALLS" "emulator-5554"

drive 'SER1  device usb:1-1' "$SPEC" --serial SER1 --app-id-2 com.other.app/.MainActivity \
  --scenarios "$EMPTY_SCENARIOS"
expect "the spec driver refuses a component in --app-id-2" "$DRIVE_RC" "1"
expect_contains "and names the flag and its own fix" "$DRIVE_OUT" \
  "--app-id-2 takes a bare package id"

# Its own device-2 slots, with an absolute --activity-2 that must survive
# composition unchanged.
TRACED=1
drive "$PHONE_AND_EMULATOR" "$SPEC" --serial SER1 --serial-2 SER2 \
  --app-id-2 com.other.app --activity-2 com.other.app/.Custom \
  --scenarios "$EMPTY_SCENARIOS"
unset TRACED
expect "an absolute --activity-2 runs the spec driver" "$DRIVE_RC" "0"
expect_contains "the spec driver adopts the serial it was given" \
  "$DRIVE_OUT" "==> running 2 devices: SER1 and SER2"
expect_match "its screen width lands in slot 2" "$DRIVE_OUT" '^\+* SCREEN_W_BY_DEV\[1\]=720$'
expect_match "its screen height lands in slot 2" "$DRIVE_OUT" '^\+* SCREEN_H_BY_DEV\[1\]=1600$'
expect_match "its app lands in slot 2" "$DRIVE_OUT" '^\+* APP_BY_DEV\[1\]=com\.other\.app$'
expect_match "its absolute activity lands in slot 2 un-re-prefixed" \
  "$DRIVE_OUT" '^\+* ACTIVITY_BY_DEV\[1\]=com\.other\.app/\.Custom$'
expect_no_contains "and no query was needed" \
  "$DRIVE_CALLS" "-s SER2 shell cmd package resolve-activity"

# resolve_activity_for's two fallbacks, reached by making the package manager
# answer with no matching component. The launch step is what shows the component
# the driver settled on.
FAKE_RESOLVE="No activity found"
drive 'SER1  device usb:1-1' "$SPEC" --serial SER1 --scenarios "$LAUNCH_SCENARIOS"
expect "an empty resolve answer still runs" "$DRIVE_RC" "0"
expect_contains "and falls back to the conventional .MainActivity" "$DRIVE_CALLS" \
  "shell am start -n com.example.app/.MainActivity"

FAKE_RESOLVE="com.other.vendor/.DeepLink"
drive 'SER1  device usb:1-1' "$SPEC" --serial SER1 --scenarios "$LAUNCH_SCENARIOS"
expect "a non-matching resolve answer still runs" "$DRIVE_RC" "0"
expect_contains "and takes the one component that came back" "$DRIVE_CALLS" \
  "shell am start -n com.other.vendor/.DeepLink"
unset FAKE_RESOLVE

# ------------------------------------------------- spec per-step device dispatch
# The spec driver reaches a device only through the cursor, so "the step named
# device 2" is only true if the driver moved that cursor before dispatching. The
# adb call log is what settles it: every step in MIXED_SCENARIOS does something
# distinguishable, and each is placed where inheriting the previous step's device
# would move its command to a different serial and break a count. Traced as well,
# so the same run also says how many steps went through step_device, which nothing
# else exposes.
TRACED=1
drive "$PHONE_AND_EMULATOR" "$SPEC" --serial SER1 --app-id-2 com.other.app \
  --scenarios "$MIXED_SCENARIOS"
unset TRACED
SPEC_TRACE="$DRIVE_OUT"
expect "a spec run with per-step devices passes" "$DRIVE_RC" "0"

# The device 2 leaves. Each asserts the wrong serial too, since a step that ran on
# both would satisfy the first half alone.
expect "a device 2 step reaches device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent KEYCODE_HOME')" "1"
expect "and never device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent KEYCODE_HOME')" "0"
expect "the if's own device is what routes its condition" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell uiautomator dump')" "1"
expect "and device 1 is not read for it" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell uiautomator dump')" "0"
# perform_action reads the bare APP_ID/ACTIVITY, which use_device has swapped for
# the cursor's device, so a device 2 step acts on device 2's app without
# perform_action knowing anything about devices.
expect "a device 2 step acts on device 2's own app" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell pm clear com.other.app')" "1"
expect "a step naming no device acts on device 1's own app" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell pm clear com.example.app')" "1"
expect_no_contains "and no device 2 step ever touched device 1's app" \
  "$DRIVE_CALLS" "-s emulator-5554 shell pm clear com.example.app"
expect_no_contains "nor device 1's step touched device 2's app" \
  "$DRIVE_CALLS" "-s SER1 shell pm clear com.other.app"
# A step that follows a device 2 step must not stay on device 2. s3's
# dismiss_keyboard names no device and lands between two device 2 steps, so an
# inherited cursor sends it to emulator-5554 instead of SER1.
expect "a step with no device field runs on the first, not the last step's device" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input keyevent 111')" "1"
expect "and no such step reached device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input keyevent 111')" "0"
# A step inside a branch dispatches on its own device, not the if's. Both branch
# directions are pinned, because one of them on its own could pass by luck:
#   s1.else names device 1 while its if named device 2, so an if-only dispatch
#        sends this tap to device 2
#   s4.else names device 2 while its if named device 2, so only the step's own
#        field puts it there. It runs at all only if the if read device 2's EMPTY
#        exec slot, since s2's exec ran on device 1.
# The untaken arms are asserted absent, so the two runs cannot be told apart by
# the wrong branch having quietly run.
expect "a branch step on device 1 runs there, though its if named device 2" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input tap 7 8')" "1"
expect "and never on the if's device" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input tap 7 8')" "0"
expect "a branch step on device 2 runs there too" \
  "$(count_calls "$DRIVE_CALLS" '-s emulator-5554 shell input tap 11 12')" "1"
expect "and never on device 1" \
  "$(count_calls "$DRIVE_CALLS" '-s SER1 shell input tap 11 12')" "0"
expect "the untaken then arm's home_button is the only one that ran" \
  "$(count_calls "$DRIVE_CALLS" 'shell input keyevent KEYCODE_HOME')" "1"
expect "and the untaken else arm's launch never ran at all" \
  "$(count_calls "$DRIVE_CALLS" 'shell am force-stop')" "0"
# The last if takes its then arm because s5 ran an exec on device 2; that arm's
# step names device 2, so the count above pins the branch that ran as much as the
# device it ran on. Read the decision off the run's own output lines rather than
# the trace, since bash -x echoes each line a second time behind a "+ ".
expect "an if on device 2 reads that device's exec output and takes the then arm" \
  "$(printf '%s\n' "$DRIVE_OUT" | grep -c '(condition met -> then-branch)' \
     | awk '{print int($1 / 2)}')" "1"
# Both exec steps read the DEMO_* context of the device they name, and one of them
# names no device, so an inherited cursor or a hardcoded serial shows up as a
# second serial in the run's own output (do_exec_step prefixes it with "     | ").
expect "an exec step reads the exec context of the device it names" \
  "$(printf '%s\n' "$DRIVE_OUT" | sed -n 's/^ *| exec ran on //p' | sort -u | tr '\n' ',')" \
  "emulator-5554,SER1,"
# Every step goes through step_device, or one runs on whichever device the step
# before it left behind. Thirteen steps dispatch in this run: nine top-level
# steps, the two branch steps, and the second scenario's one step. Seven of them
# name device 2 (the three ifs, the device 2 exec, the two device 2 branch steps
# and the device 2 pm_clear), and those seven are the use_device 2 calls.
expect "every spec step calls step_device" \
  "$(count_calls "$SPEC_TRACE" '^+ step_device ')" "13"
expect "and the device 2 steps move the cursor to 2" \
  "$(count_calls "$SPEC_TRACE" '^+ use_device 2$')" "7"
expect_contains "the step echo names the device a step routed to" "$DRIVE_OUT" \
  "-- step 7: pm_clear  [device 2]"
expect_no_contains "and a step naming no device carries no device marker" "$DRIVE_OUT" \
  "-- step 8: pm_clear  ["
expect_contains "and the branch's step echo names its own" "$DRIVE_OUT" \
  "-- step 4.e.0: tap_xy  [device 2]"
expect_contains "and an if's own echo names its device" "$DRIVE_OUT" \
  "-- step 4: if  [device 2]"
expect_contains "and so does an exec step's" "$DRIVE_OUT" \
  "-- step 5: exec  [device 2]"

# A device the run never attached is refused before anything is asked of it, and
# the refusal costs its own scenario rather than the run: MIXED_SCENARIOS' second
# scenario still executes and passes, and the first is reported as the failure.
drive 'SER1  device usb:1-1' "$SPEC" --serial SER1 --app-id-2 com.other.app \
  --scenarios "$MIXED_SCENARIOS"
expect "a device 2 step in a single-device spec run is refused" "$DRIVE_RC" "1"
expect_contains "and the refusal names the flag that would add the device" \
  "$DRIVE_OUT" "--serial-2"
expect_contains "the failing scenario is reported, with its step" "$DRIVE_OUT" \
  "routes each step to its device -- failed at step 1 (if)"
expect_contains "and the scenario after it still ran" "$DRIVE_OUT" \
  "runs after a failed scenario"
expect "which passed, rather than being skipped or failed" \
  "$(printf '%s\n' "$DRIVE_OUT" | grep -c '=> PASS')" "1"
# Only s0 ran. s1 names device 2 and is refused before its condition is read, so
# nothing was ever asked of the absent device, and no adb call carries an empty
# serial (which is how a refusal that came too late would look).
expect "the refused step's condition was never read anywhere" \
  "$(count_calls "$DRIVE_CALLS" 'shell uiautomator dump')" "0"
expect "and the one step before it still ran" \
  "$(count_calls "$DRIVE_CALLS" 'shell input keyevent KEYCODE_BACK')" "2"
expect "nothing was asked of a device with no serial" \
  "$(serials_touched "$DRIVE_CALLS")" "$SERIAL_A,"

# ---------------------------------------------------------------- summary
echo
echo "bash tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]