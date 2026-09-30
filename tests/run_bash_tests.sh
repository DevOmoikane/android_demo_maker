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
# android-ui-lib.sh expects SERIAL and ADB() to be provided by the caller.
# The ADB stub keeps device state in files here because the library calls it
# inside command substitutions (subshells), where plain variable writes would
# be lost.
export SERIAL="SER1"
FAKE_USB=1
FAKE_DEVICES_USB="SER1  device usb:2-2 product:raven model:Pixel_6_Pro device:raven transport_id:2"
FAKE_DEVICES_WIFI="SER1  device product:raven model:Pixel_6_Pro device:raven transport_id:2"
SLEPT=()
TYPED=()
ROT_FILE="$(mktemp)"
printf '0\n' > "$ROT_FILE"
trap 'rm -f "$ROT_FILE"' EXIT

adb() { # only `adb devices -l` is used by device_is_usb
  if [ "${1:-}" = "devices" ] && [ "${2:-}" = "-l" ]; then
    if [ "$FAKE_USB" = "1" ]; then printf '%s\n' "$FAKE_DEVICES_USB"; else printf '%s\n' "$FAKE_DEVICES_WIFI"; fi
  fi
}

ADB() { # mirrors the `adb -s $SERIAL "$@"` wrapper the drivers export
  local args="$*"
  case "$args" in
    "shell settings get system accelerometer_rotation")
      cat "$ROT_FILE" ;;
    "shell settings put system accelerometer_rotation "*)
      printf '%s\n' "${@: -1}" > "$ROT_FILE" ;;
    "shell input text "*)
      TYPED+=("${@: -1}") ;;
  esac
}

sleep() { SLEPT+=("${1:-}"); }

# shellcheck source=/dev/null
. "$LIB"

# ---------------------------------------------------------------- autorotate
printf '0\n' > "$ROT_FILE"
AUTOROTATE_AT_START=""
GUARD_AUTOROTATE=true
autorotate_snapshot
expect "autorotate_snapshot records the setting" "$AUTOROTATE_AT_START" "0"
printf '1\n' > "$ROT_FILE"
out="$(autorotate_restore 2>&1)"
expect "autorotate_restore puts the setting back" "$(cat "$ROT_FILE")" "0"
expect_contains "autorotate_restore reports the change" "$out" "restored"

GUARD_AUTOROTATE=false
AUTOROTATE_AT_START=""
printf '1\n' > "$ROT_FILE"
autorotate_snapshot
expect "GUARD_AUTOROTATE=false skips the snapshot" "$AUTOROTATE_AT_START" ""
GUARD_AUTOROTATE=true

# ---------------------------------------------------------------- device_is_usb
FAKE_USB=1
device_is_usb && rc=0 || rc=1
expect "device_is_usb says USB over a USB transport" "$rc" "0"
FAKE_USB=0
device_is_usb && rc=0 || rc=1
expect "device_is_usb says not USB over wireless" "$rc" "1"

# ---------------------------------------------------------------- exec radio guard
GUARD_RADIO_TOGGLE_USB_ONLY=true
FAKE_USB=0
radio_step='{"command": "svc wifi disable", "on_fail": "continue"}'
rc=0
out="$(do_exec_step "$radio_step" 2>&1)" || rc=$?
expect "radio toggle is refused off-USB" "$rc" "1"
expect_contains "refusal names the USB requirement" "$out" "not on USB"

FAKE_USB=1
rc=0
out="$(do_exec_step "$radio_step" 2>&1)" || rc=$?
expect "radio toggle runs when USB (on_fail=continue swallows svc 127)" "$rc" "0"
expect_no_grep "guard does not fire over USB" <(printf '%s' "$out") "not on USB"

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
expect_grep "demo sources the shared library" "$DEMO" 'source "${SCRIPT_DIR}/android-ui-lib.sh"'
expect_grep "spec-test snapshots auto-rotate before steps" "$SPEC" "autorotate_snapshot"
expect_grep "spec-test restores auto-rotate on exit" "$SPEC" "autorotate_restore; rm -rf"

# ---------------------------------------------------------------- summary
echo
echo "bash tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]