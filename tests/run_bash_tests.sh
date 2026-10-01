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
cleanup_test_tmp() {
  rm -rf "${STUB_DIR:-/nonexistent}" "${CALLS:-/nonexistent}" \
         "${EMPTY_STEPS:-/nonexistent}" "${EMPTY_SCENARIOS:-/nonexistent}" \
         "${LAUNCH_SCENARIOS:-/nonexistent}" "${MIXED_STEPS:-/nonexistent}" \
         "${SIMPLE_STEPS:-/nonexistent}" "${APP2_STEPS:-/nonexistent}" 2>/dev/null
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

expect_contains "--serial-2 is documented" "$help_out" "--serial-2"
expect_contains "--compose-height is documented" "$help_out" "--compose-height"
rc=0
"$DEMO" --serial-2 SER2 --app-id-2 com.other.app --compose-height 1440 --help >/dev/null 2>&1 || rc=$?
expect "second-device flags parse" "$rc" "0"

spec_help="$("$SPEC" --help 2>&1)"
expect_contains "spec documents --serial-2" "$spec_help" "--serial-2"
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
  # Per device, so a test can tell a per-device restore from a hardcoded one:
  # device 1 reports 0 (DND off, must end up off) and every other serial
  # reports 2 (total silence, must be handed back as 2, not flattened to 0).
  # GARBAGE reports something the driver does not recognize, which is a read
  # result and must never be written back.
  *"get global zen_mode"*)
    case "$serial" in
      SER1) echo "0" ;;
      GARBAGE) echo "not-a-zen-mode" ;;
      *) echo "2" ;;
    esac ;;
  *accelerometer_rotation*) echo "1" ;;
  # A serial whose segment pull fails, the way a device that dropped off
  # mid-segment does. Only the pull fails; everything else on that serial works.
  *pull*_android_demo_seg*)
    if [ "$serial" = "NOPULL" ]; then
      echo "adb: error: failed to stat remote object" >&2
      exit 1
    fi ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/adb"
CALLS="$(mktemp)"
EMPTY_STEPS="$(mktemp)"
EMPTY_SCENARIOS="$(mktemp)"
LAUNCH_SCENARIOS="$(mktemp)"
MIXED_STEPS="$(mktemp)"
SIMPLE_STEPS="$(mktemp)"
APP2_STEPS="$(mktemp)"
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

drive() { # drive <fake-devices> <driver> <driver args...>
  local runner
  FAKE_DEVICES="$1"; shift
  runner="$1"; shift
  : > "$CALLS"
  DRIVE_RC=0
  # TRACED=1 traces the driver so the per-device arrays it builds can be read
  # back; nothing else exposes them until step dispatch can target device 2.
  DRIVE_OUT="$(ADB_CALLS="$CALLS" FAKE_DEVICES="$FAKE_DEVICES" \
               FAKE_RESOLVE="${FAKE_RESOLVE:-}" PATH="$STUB_DIR:$PATH" \
               bash ${TRACED:+-x} "$runner" --app-id com.example.app "$@" 2>&1)" || DRIVE_RC=$?
  DRIVE_CALLS="$(cat "$CALLS")"
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

# A `settings get` that answers with something the driver does not recognize is a
# read result, not a setting: writing it straight back would hand the device a
# value nobody chose. The stub's GARBAGE serial answers "not-a-zen-mode".
GARBAGE_PAIR='SER1  device usb:1-1
GARBAGE  device usb:1-2'
drive "$GARBAGE_PAIR" "$DEMO" --serial SER1 --serial-2 GARBAGE --no-narration \
  --steps "$SIMPLE_STEPS" --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect_contains "a device with an unreadable zen mode is still snapshotted" \
  "$DRIVE_CALLS" "-s GARBAGE shell settings get global zen_mode"
expect_contains "and is still muted for the recording" "$DRIVE_CALLS" \
  "-s GARBAGE shell cmd notification set_dnd on"
expect_no_contains "but its unreadable value is never written back" \
  "$DRIVE_CALLS" "-s GARBAGE shell settings put global zen_mode"
expect_contains "while the device that did answer is still restored" \
  "$DRIVE_CALLS" "-s SER1 shell settings put global zen_mode 0"

# A pull that fails must cost its own segment, not the whole run. Under set -e an
# unguarded pull aborts inside stop_segment, the EXIT trap fires, and cleanup()
# deletes the workdir along with every segment already pulled, so the observable
# is that the run gets past the pull loop at all.
NOPULL_PAIR='SER1  device usb:1-1
NOPULL  device usb:1-2'
drive "$NOPULL_PAIR" "$DEMO" --serial SER1 --serial-2 NOPULL --no-narration \
  --steps "$SIMPLE_STEPS" --out "$LAUNCH_SCENARIOS.mp4" --keep-workdir
expect_contains "a device whose pull fails still gets through the pull loop" \
  "$DRIVE_OUT" "==> Normalizing 1 recording segment"
expect_contains "the failure is reported, naming the segment and the device" \
  "$DRIVE_OUT" "==> WARNING: segment 0 for device 2 was not pulled to"
expect_contains "and the device that did pull keeps its footage" "$DRIVE_CALLS" \
  "-s SER1 pull /sdcard/_android_demo_seg_0_1.mp4"

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

# ---------------------------------------------------------------- summary
echo
echo "bash tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]