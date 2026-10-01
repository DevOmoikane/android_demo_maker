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
         "${LAUNCH_SCENARIOS:-/nonexistent}" 2>/dev/null
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
# package manager's whole answer, to reach the resolver's fallbacks;
# FAKE_SIZELESS serial reports a wm size with nothing parseable in it.
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
  *accelerometer_rotation*) echo "1" ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/adb"
CALLS="$(mktemp)"
EMPTY_STEPS="$(mktemp)"
EMPTY_SCENARIOS="$(mktemp)"
LAUNCH_SCENARIOS="$(mktemp)"
printf '[]\n' > "$EMPTY_STEPS"
printf '[]\n' > "$EMPTY_SCENARIOS"
# One scenario that launches, so the resolved activity is visible as the
# component the driver actually asks the device to start.
printf '[{"name":"launches","steps":[{"action":"launch"}]}]\n' > "$LAUNCH_SCENARIOS"

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
expect_no_contains "the unchosen phone is never contacted" "$DRIVE_CALLS" "-s SER2 "
expect_no_contains "and neither is the emulator" "$DRIVE_CALLS" "emulator-5554"

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
expect_no_contains "and neither unchosen device is contacted" "$DRIVE_CALLS" "SER2 "
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