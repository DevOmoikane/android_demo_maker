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

expect_grep() { # expect_grep <desc> <file> <fixed-pattern>
  if grep -q -- "$3" "$2"; then note "$1"; else bail "$1 (no match: $3 in $(basename "$2"))"; fi
}

expect_no_grep() { # expect_no_grep <desc> <file> <fixed-pattern>
  if grep -q -- "$3" "$2"; then bail "$1 (unexpected match: $3 in $(basename "$2"))"; else note "$1"; fi
}

# ---------------------------------------------------------------- syntax
for f in "$DEMO" "$SPEC" "$LIB"; do
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
trap 'rm -f "$ROT_A" "$ROT_B"' EXIT

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

# ---------------------------------------------------------------- demo driver smoke
help_out="$("$DEMO" --help 2>&1)"
expect_contains "--loose is documented in --help" "$help_out" "--loose"
rc=0
"$DEMO" --loose --help >/dev/null 2>&1 || rc=$?
expect "--loose is accepted by the parser" "$rc" "0"

expect_grep "phase-4 concat forces cfr frame rate" "$DEMO" "-fps_mode cfr"
expect_grep "phase-4 concat normalizes to 30fps" "$DEMO" "fps=30"
expect_grep "phase-4 concat forces keyframes" "$DEMO" "keyint_min 30"
expect_grep "TIGHT pacing is configurable" "$DEMO" "TIGHT_OPT"
# The demo driver sources the library, so these guards are checked where they
# now live rather than against a copy that no longer exists in the demo.
expect_grep "autorotate guard wired into the shared library" "$LIB" "GUARD_AUTOROTATE"
expect_grep "radio guard wired into the shared library" "$LIB" "GUARD_RADIO_TOGGLE_USB_ONLY"
expect_grep "type settle wired into the shared library" "$LIB" "TYPE_FOCUS_SETTLE_SECONDS"
expect_grep "shared library poll_bounds honors knobs" "$LIB" "POLL_MAX_ATTEMPTS"
expect_grep "demo sources the shared library" "$DEMO" '^source "\${SCRIPT_DIR}/android-ui-lib\.sh"$'
expect_grep "spec-test snapshots auto-rotate before steps" "$SPEC" "autorotate_snapshot"
expect_grep "spec-test restores auto-rotate on exit" "$SPEC" "autorotate_restore; rm -rf"

# ---------------------------------------------------------------- summary
echo
echo "bash tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]