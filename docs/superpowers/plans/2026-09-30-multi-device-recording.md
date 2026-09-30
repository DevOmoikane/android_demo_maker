# Multi-device side-by-side recording: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional second phone or emulator that is recorded through the same beat timeline as the first and composited side by side into one MP4, with each step naming the device it runs on.

**Architecture:** `android-ui-lib.sh` gains a device cursor. Callers populate an indexed `SERIALS` array plus `DEVICE_COUNT`, and the library owns `ADB()`/`ADB_FOR()`, so its existing functions need no signature changes. Per-device state (screen size, last exec output, auto-rotate snapshot) lives in indexed arrays that `use_device` swaps into the bare names the library already reads. A new `android-compose-lib.sh` holds the compositing arithmetic as pure functions, so the filter graph is testable without ffmpeg or devices. A single-device run produces a byte-identical filter graph.

**Tech Stack:** bash 3.2 (no associative arrays, no `mapfile`), `adb`, `jq`, `ffmpeg`/`ffprobe`, Python 3.8 stdlib only (no pip packages), vanilla JS frontend, `unittest` for the backend, a hand-rolled assert-based bash suite.

**Spec:** `docs/superpowers/specs/2026-09-30-multi-device-recording-design.md`

## Global Constraints

- Never emit the em dash character. Use a comma, colon, semicolon, period, parentheses, or a hyphen.
- No comments unless the surrounding code already carries explanatory comments for a non-obvious *why*. Match the existing density: these scripts comment decisions, not mechanics.
- bash 3.2 is the floor (macOS system bash). **No associative arrays. No `mapfile`/`readarray`. No `${var,,}`.** Indexed arrays only.
- Python must stay stdlib-only. No new imports beyond what a file already uses.
- Single-device behavior must not regress. For `DEVICE_COUNT=1` the filter string is byte-for-byte what the current code produces.
- Update `android-ui-lib.sh`'s header contract comment in the same commit as any change to it.
- Every task ends with both suites green: `.venv/bin/python -m unittest discover -s tests` and `tests/run_bash_tests.sh`.
- Never commit `.DS_Store`, `output/`, or `piper-voices/` (already in `.gitignore`).
- Run every shell command in this plan under **bash**, never an interactive zsh. bash arrays are 0-indexed and zsh's are 1-indexed, so `SERIALS[$((d - 1))]` and `APP_BY_DEV[$i]` silently resolve to the wrong element under zsh while looking perfectly correct. `tests/run_bash_tests.sh` has a `#!/usr/bin/env bash` shebang, so invoking it as `tests/run_bash_tests.sh` is safe; use an explicit `bash file` for any ad hoc snippet.

## File Structure

| File | Responsibility after this plan |
| --- | --- |
| `android-ui-lib.sh` | Shared adb/uiautomator driving. Owns the device cursor (`ADB`, `ADB_FOR`, `use_device`) and per-device state arrays. |
| `android-compose-lib.sh` | **New.** Pure video-compositing arithmetic: pane geometry and `-filter_complex` construction. No adb, no sleeps, no device access. |
| `android-demo.sh` | Demo driver. Multi-device CLI flags, per-step device dispatch, per-device segments, phase 4 wiring. |
| `android-spec-test.sh` | Spec driver. Multi-device CLI flags and per-step device dispatch. No video. |
| `demo_maker/steps.py` | Step schema and validation, including the new `device` field. |
| `demo_maker/spec.py` | Scenario schema (inherits demo actions) and `build_spec_argv`. |
| `demo_maker/config.py` | Settings schema and persistence. |
| `demo_maker/runner.py` | `build_argv` for demo runs. |
| `web/index.html` | App tab markup, including the opt-in companion block. |
| `web/app.js` | Slot-parameterized device/app wiring. |
| `tests/run_bash_tests.sh` | Bash suite. Rewritten to stub raw `adb` rather than `ADB`. |
| `tests/test_studio.py` | Python suite. |
| `example-steps.json` | Sample tour; gains a `device` step. |

## Task order and why

Task 1 is a prerequisite for everything. Task 2 must precede 4, 5, and 7, which all consume the cursor. Task 4 must precede 5 and 7, which need `SERIALS[1]` and `APP_ID_2`. Task 6 must follow 5, which produces the per-device segment files. Task 3 is independent of shell work but is placed early so the UI task has a field to render.

---

### Task 1: De-duplicate the drivers

`android-demo.sh` carries its own copy of 26 functions that also live in `android-ui-lib.sh`. All 26 bodies are byte-identical. Replace them with one `source` line. No behavior change.

**Files:**
- Modify: `android-demo.sh` (delete 4 contiguous blocks, add 1 `source` line)
- Test: `tests/run_bash_tests.sh` (unchanged, must stay green)

**Interfaces:**
- Consumes: nothing.
- Produces: `android-demo.sh` sources `android-ui-lib.sh`, so the library's 26 functions are in scope for the demo driver. The contract is unchanged at this task: the caller still defines `ADB()`.

- [ ] **Step 1: Record the baseline**

Run: `.venv/bin/python -m unittest discover -s tests 2>&1 | tail -3` then `tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: `OK` and `bash tests: 32 passed, 0 failed`.

- [ ] **Step 2: Add the `source` line**

In `android-demo.sh`, immediately after `WORKDIR="$(mktemp -d /tmp/android-demo-XXXXXX)"` (line 334) and before the `# ---- device hygiene` comment at line 336, insert:

```bash
# The driving primitives (uiautomator lookup, gestures, exec, condition
# evaluation, device hygiene) live in android-ui-lib.sh, shared with
# android-spec-test.sh so both drive the UI the exact same way. This file
# only adds what is specific to a narrated recording: the beat clock, the
# screenrecord segment pump, and the TTS pipeline. The library needs ADB(),
# WORKDIR and SCREEN_W/SCREEN_H (all defined above) and nothing else.
source "${SCRIPT_DIR}/android-ui-lib.sh"
```

The `source` must sit **before** the `autorotate_snapshot` call on line 361, because the library initializes `AUTOROTATE_AT_START` at source time and a later `source` would wipe the snapshot.

- [ ] **Step 3: Delete the four duplicated blocks**

Remove these ranges exactly as they stand. Verify each with `sed -n` before deleting, since deleting shifts later line numbers.

| Lines | Contents |
| --- | --- |
| 342-372 | `autorotate_snapshot`, `autorotate_restore`, `device_is_usb` |
| 399-663 | `dump_ui` through `find_and_tap_desc` |
| 674-778 | `xml_unescape` through `maybe_type` |
| 790-871 | `do_exec_step`, `eval_condition` |

Keep, because they exist in neither the library nor anywhere else: `usage` (209-253), `load_env_file` (254-341), `cleanup` (373-398), `assert_text_present` (664-673), `narr_id_to_file` (779-789), `synthesize_line` (872-882), and everything from `perform_action` (883) to end of file.

Keep the comment block at 336-340, which explains why auto-rotate is snapshotted, and keep the bare `autorotate_snapshot` call on line 361. Those are call-site commentary, not duplicated function bodies.

- [ ] **Step 4: Verify the driver still works end to end**

Run: `bash -n android-demo.sh && bash -n android-spec-test.sh && bash -n android-ui-lib.sh`
Expected: no output, exit 0.

Run: `./android-demo.sh --help >/dev/null && ./android-spec-test.sh --help >/dev/null`
Expected: exit 0 for both.

Run: `./android-demo.sh --nope 2>&1 | head -1`
Expected: `ERROR: unknown option: --nope`. The `source` must not have broken the early-argument exits: `SCRIPT_DIR` is set at line 189 and arg parsing is at 216-233, both before the `source` at 334.

- [ ] **Step 5: Run both suites**

Run: `.venv/bin/python -m unittest discover -s tests 2>&1 | tail -3 && tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: `OK` and `bash tests: 32 passed, 0 failed`. Identical to the baseline.

- [ ] **Step 6: Commit**

```bash
git add android-demo.sh
git commit -m "Source the shared UI library from the demo driver

android-demo.sh carried its own copy of 26 functions that also live in
android-ui-lib.sh, where all 26 bodies are byte-identical. INSTRUCTIONS.md
already claimed the demo script sourced the library; it did not, which is
how the device-hygiene guards in the previous commit ended up written twice.

Sourcing it is a pure deletion plus one line. The 7 library functions the
demo never used become available, which is additive. Both suites unchanged."
```

---

### Task 2: Device cursor in the shared library

Make `android-ui-lib.sh` own `ADB()`/`ADB_FOR()` and add `use_device`, so every existing library function keeps its signature and reaches the device only through the cursor.

**Files:**
- Modify: `android-ui-lib.sh` (header contract, new cursor block, `dump_ui`, `device_is_usb`, `autorotate_*`, `do_exec_step`)
- Modify: `android-demo.sh` (drop its `ADB()`, seed the arrays)
- Modify: `android-spec-test.sh` (same)
- Test: `tests/run_bash_tests.sh` (rewrite the `adb` stub, add cursor tests)

**Interfaces:**
- Consumes: Task 1's `source` line.
- Produces, for both drivers and the test harness:
  - `SERIALS` indexed array of serials, `SERIALS[0]` is device 1.
  - `DEVICE_COUNT` integer, 1 or 2.
  - `CUR_DEV` integer, the device the next action targets.
  - `ADB()` and `ADB_FOR <device> ...`
  - `use_device <1|2>`
  - `SCREEN_W_BY_DEV` / `SCREEN_H_BY_DEV` indexed arrays of integers.
  - `AUTOROTATE_AT_START` indexed array; element `d-1` is `""`, `"0"`, or `"1"`.
  - `LAST_EXEC_STATUS` / `LAST_EXEC_OUTPUT` indexed arrays, plus bare-name mirrors of the current device's value.
  - `APP_BY_DEV` / `ACTIVITY_BY_DEV` indexed arrays (optional; when absent `use_device` leaves `APP_ID` / `ACTIVITY` alone).

- [ ] **Step 1: Rewrite the test stub to intercept raw `adb`**

In `tests/run_bash_tests.sh`, replace the block from `export SERIAL="SER1"` (line 50) through `. "$LIB"` (line 81) with the following. The library now owns `ADB()`, so the harness must stub the binary instead; that also makes the target serial visible for the cursor assertions.

```bash
SERIAL_A="SER1"
SERIAL_B="SER2"
FAKE_USB_A=1
FAKE_USB_B=1
FAKE_DEVICES_A="SER1  device usb:2-2 product:raven model:Pixel_6_Pro device:raven transport_id:2"
FAKE_DEVICES_B="SER2  device usb:2-4 product:cuttlefish model:sdk_gphone64 device:cuttlefish transport_id:4"
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
    if [ "$FAKE_USB_A" = 1 ] && [ "$FAKE_USB_B" = 1 ]; then
      printf '%s\n%s\n' "$FAKE_DEVICES_A" "$FAKE_DEVICES_B"
    else
      printf '%s\n' "$FAKE_DEVICES_A"
    fi
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
```

Delete the old `adb()`, `ADB()`, `SLEPT`/`TYPED`/`ROT_FILE`, and old `trap` lines that this replaces.

- [ ] **Step 2: Run the suite and watch it fail**

Run: `tests/run_bash_tests.sh 2>&1 | tail -6`
Expected: the old assertions still reference `$ROT_FILE` and the old `ADB()` stub, so the autorotate and radio-guard tests fail. The syntax checks still pass. The point is that the suite is red before the library change.

- [ ] **Step 3: Add the cursor to the library**

In `android-ui-lib.sh`, replace the header contract block (lines 8-11) with:

```bash
# Callers must define, before sourcing this file:
#   SERIALS          indexed array of serials; SERIALS[d-1] is device d
#   DEVICE_COUNT     how many entries of SERIALS are live (1 or 2)
#   WORKDIR          scratch dir (this file writes $WORKDIR/dump_$CUR_DEV.xml)
#   SCREEN_W_BY_DEV  indexed array of device pixel widths
#   SCREEN_H_BY_DEV  indexed array of device pixel heights
# Optional, read by use_device() only to give exec steps the right context:
#   APP_BY_DEV       indexed array of package names, one per device
#   ACTIVITY_BY_DEV  indexed array of launch activities, one per device
# A caller that sets only SERIAL and SCREEN_W/SCREEN_H gets single-device
# behavior: SERIALS is seeded from SERIAL and DEVICE_COUNT stays 1.
```

Then, immediately after that comment block and before `dump_ui`, insert:

```bash
# ---------------------------------------------------------------- device cursor
# SERIALS[d-1] is the adb serial for device d. Everything below reaches the
# device only through ADB(), so a multi-device caller is a matter of setting
# the cursor, not of threading a device argument through 26 functions.
: "${DEVICE_COUNT:=1}"
if [ "${#SERIALS[@]}" -eq 0 ]; then
  SERIALS=("${SERIAL:-}" "")
fi
CUR_DEV=1

ADB() { adb -s "${SERIALS[$((CUR_DEV - 1))]}" "$@"; }
ADB_FOR() { local d="$1"; shift; adb -s "${SERIALS[$((d - 1))]}" "$@"; }

# Loads device d's state into the bare names the rest of this file reads, so
# nothing below has to know how many devices are attached. Call it once per
# step, before dispatching that step's action.
use_device() {
  local d="${1:-1}" i=$(( ${1:-1} - 1 ))
  CUR_DEV="$d"
  SCREEN_W="${SCREEN_W_BY_DEV[$i]:-1080}"
  SCREEN_H="${SCREEN_H_BY_DEV[$i]:-2400}"
  LAST_EXEC_STATUS="${LAST_EXEC_STATUS[$i]}"
  LAST_EXEC_OUTPUT="${LAST_EXEC_OUTPUT[$i]}"
  if [ "${#APP_BY_DEV[@]}" -gt 0 ]; then
    APP_ID="${APP_BY_DEV[$i]:-$APP_ID}"
    ACTIVITY="${ACTIVITY_BY_DEV[$i]:-$ACTIVITY}"
  fi
  export DEMO_SERIAL="${SERIALS[$i]}" DEMO_APP_ID="$APP_ID" \
         DEMO_ACTIVITY="$ACTIVITY" DEMO_SCREEN_W="$SCREEN_W" \
         DEMO_SCREEN_H="$SCREEN_H"
}

# Records the auto-rotate setting of every live device before any step can move
# it. Per device: an if step on device 2 must read device 2's slot, and a
# restore must never touch a device it did not snapshot.
autorotate_snapshot() {
  [ "${GUARD_AUTOROTATE:-true}" = "true" ] || return 0
  local d i v
  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    i=$((d - 1))
    v="$(ADB_FOR "$d" shell settings get system accelerometer_rotation 2>/dev/null | tr -d '\r\n')"
    case "$v" in
      0|1) AUTOROTATE_AT_START[$i]="$v" ;;
      *)   AUTOROTATE_AT_START[$i]="" ;;
    esac
  done
}

# Puts the setting back if the run moved it, and says so: a silent restore
# would hide the next tool that starts flipping it.
autorotate_restore() {
  local d i now
  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    i=$((d - 1))
    [ -n "${AUTOROTATE_AT_START[$i]}" ] || continue
    now="$(ADB_FOR "$d" shell settings get system accelerometer_rotation 2>/dev/null | tr -d '\r\n')"
    [ "$now" = "${AUTOROTATE_AT_START[$i]}" ] && continue
    ADB_FOR "$d" shell settings put system accelerometer_rotation \
      "${AUTOROTATE_AT_START[$i]}" >/dev/null 2>&1
    echo "==> device ${d} auto-rotate had been changed during this run (${AUTOROTATE_AT_START[$i]} -> ${now}); restored to ${AUTOROTATE_AT_START[$i]}" >&2
  done
}

# True when device d is attached over USB. Radio toggles are refused otherwise:
# on wireless debugging, disabling wifi cuts adb's own transport and the device
# is left unreachable with its radios off.
device_is_usb() {
  local d="${1:-$CUR_DEV}"
  adb devices -l | awk -v s="${SERIALS[$((d - 1))]}" '$1 == s' | grep -q ' usb:'
}
```

Delete the old `AUTOROTATE_AT_START=""` / `autorotate_snapshot` / `autorotate_restore` / `device_is_usb` block that this replaces (the "device hygiene" section, currently lines 460-498). Declare `AUTOROTATE_AT_START=("" "")` just above the new `autorotate_snapshot`.

**Convert the two remaining scalar initializers to arrays in the same edit.** The library currently has `LAST_EXEC_STATUS=""` and `LAST_EXEC_OUTPUT=""` at lines 507-508, before `do_exec_step`. Both must become `LAST_EXEC_STATUS=("" "")` and `LAST_EXEC_OUTPUT=("" "")`, or `use_device`'s `${LAST_EXEC_STATUS[$i]}` reads an element of a non-array and the whole file misbehaves. `TEXT_VALUE=""` and `TEXT_BOUNDS=""` at lines 405-406 stay scalars: they are pure scratch within a single lookup and never carry state across steps.

Declare all three arrays at library source time, not lazily. `tests/run_bash_tests.sh` runs under `set -u`, and `${ARR[$i]}` on a declared-but-empty element is fine while an entirely undeclared array is an unbound-variable error.

- [ ] **Step 4: Make `dump_ui` per-device and `do_exec_step` write back**

Replace the `dump_ui` body:

```bash
dump_ui() {
  ADB shell uiautomator dump /sdcard/_android_demo_dump.xml >/dev/null 2>&1 || true
  ADB pull /sdcard/_android_demo_dump.xml "$WORKDIR/dump_${CUR_DEV}.xml" >/dev/null 2>&1 || true
}
```

In `do_exec_step`, the two globals are set near the end of the function. After the existing `LAST_EXEC_STATUS=...` and `LAST_EXEC_OUTPUT=...` assignments, add:

```bash
  # Keep this device's slot current, so a following if step that names a
  # different device reads that device's output rather than this one's.
  local i=$((CUR_DEV - 1))
  LAST_EXEC_STATUS[$i]="$LAST_EXEC_STATUS"
  LAST_EXEC_OUTPUT[$i]="$LAST_EXEC_OUTPUT"
```

The radio guard's existing `device_is_usb` call site needs no change: the function now defaults to `$CUR_DEV`, which is the device the exec step is running against.

- [ ] **Step 5: Update both drivers to seed the arrays**

In `android-demo.sh`, replace `ADB() { adb -s "$SERIAL" "$@"; }` with:

```bash
SERIALS=("$SERIAL" "")
DEVICE_COUNT=1
```

Then, after the primary `SCREEN_W`/`SCREEN_H` are read (currently lines 387-390), add:

```bash
SCREEN_W_BY_DEV=("$SCREEN_W" "")
SCREEN_H_BY_DEV=("$SCREEN_H" "")
APP_BY_DEV=("$APP_ID" "")
ACTIVITY_BY_DEV=("$ACTIVITY" "")
use_device 1
```

Make the same edits in `android-spec-test.sh`: drop its `ADB()` definition, seed `SERIALS`/`DEVICE_COUNT` where it was, and add the `SCREEN_W_BY_DEV` block plus `use_device 1` after its `SCREEN_H` assignment and `source` of the library.

Remove the now-redundant `export DEMO_SERIAL=...` block from both drivers; `use_device` does that export.

- [ ] **Step 6: Add the cursor assertions to the bash suite**

In `tests/run_bash_tests.sh`, replace the old `autorotate` and `device_is_usb` sections with:

```bash
# ---------------------------------------------------------------- device cursor
ADB_LOG=""
use_device 2
expect "use_device sets the cursor" "$CUR_DEV" "2"
expect "use_device loads device 2 screen size" "$SCREEN_W/$SCREEN_H" "720/1600"
expect "use_device loads device 2 app context" "$APP_ID" "com.other.app"
ADB shell echo hi >/dev/null
expect "ADB targets the cursor's device" "$ADB_LOG" "$SERIAL_B|shell echo hi;"
ADB_FOR 1 shell echo hi >/dev/null
expect "ADB_FOR targets an explicit device" \
  "$ADB_LOG" "$SERIAL_B|shell echo hi;$SERIAL_A|shell echo hi;"
use_device 1
expect "use_device back to 1 reloads device 1" "$SCREEN_W/$SCREEN_H" "1080/2400"

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
```

Replace the exec radio guard section with one that uses the new flag names and adds a device-2 case:

```bash
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
```

Add this section after the type-focus section. The comment matters: it deliberately avoids `$(...)` because that is a subshell and would discard the globals.

```bash
# ---------------------------------------------------------------- exec slots
# Not captured in a command substitution: that is a subshell, and do_exec_step's
# whole purpose here is to leave the result in the calling shell's globals.
GUARD_RADIO_TOGGLE_USB_ONLY=false
LAST_EXEC_STATUS=("0" "0")
LAST_EXEC_OUTPUT=("" "")
use_device 2
do_exec_step '{"command": "echo hello", "shell": "bash", "on_fail": "continue"}' \
  >/dev/null 2>&1
expect "device 2 slot holds the output" "${LAST_EXEC_OUTPUT[1]}" "hello"
expect "device 2 bare mirror is current" "$LAST_EXEC_OUTPUT" "hello"
expect "device 1 slot untouched" "${LAST_EXEC_OUTPUT[0]}" ""
use_device 1
expect "switching back reloads device 1's empty output" "$LAST_EXEC_OUTPUT" ""
GUARD_RADIO_TOGGLE_USB_ONLY=true
```

- [ ] **Step 7: Run both suites**

Run: `bash -n android-ui-lib.sh && bash -n android-demo.sh && bash -n android-spec-test.sh && bash -n tests/run_bash_tests.sh`
Expected: silent, exit 0.

Run: `tests/run_bash_tests.sh`
Expected: `0 failed`, and a higher pass count than the 32 at baseline. The exact count is not a gate; the number that matters is that nothing that passed before now fails.

Run: `.venv/bin/python -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`.

- [ ] **Step 8: Commit**

```bash
git add android-ui-lib.sh android-demo.sh android-spec-test.sh tests/run_bash_tests.sh
git commit -m "Give the shared UI library a device cursor

ADB() and ADB_FOR() now live in the library instead of each driver, and
SERIALS holds one serial per device. Because ADB() was already the single
choke point every library function reached the device through, none of their
signatures changed: a multi-device caller sets SERIALS/DEVICE_COUNT and calls
use_device before each step, and the rest of the library is unaware.

Per-device state is indexed rather than per-scalar, and use_device swaps the
entry into the bare name the library already reads:
- SCREEN_W/SCREEN_H, so gesture geometry follows the cursor
- LAST_EXEC_STATUS/LAST_EXEC_OUTPUT, with do_exec_step writing back to the
  slot so an if step naming another device reads that device's output
- AUTOROTATE_AT_START, snapshotted and restored per device
- APP_ID/ACTIVITY plus the DEMO_* exec context, for launch/pm_clear

autorotate_* and device_is_usb take an explicit device rather than following
the cursor, since cleanup and the EXIT trap run with it at an arbitrary value.

The bash suite now stubs raw adb rather than ADB, which also lets it assert
which serial a command reached."
```

---

### Task 3: The `device` field in the step schema

Add an optional `device` field to every action in both registries, validated as 1 or 2.

**Files:**
- Modify: `demo_maker/steps.py:22-27` (common field list) and `demo_maker/steps.py:164-171` (the common-field loop)
- Test: `tests/test_studio.py` (`StepsValidationTests`)

**Interfaces:**
- Consumes: nothing.
- Produces: every action in `ACTIONS` and (through `spec._demo_action`) `SPEC_ACTIONS` gains a field spec named `device`, type `select`, options `["1", "2"]`, default `None`. The editor renders it as a dropdown with no frontend change, because `buildStepFields` reads `spec.options`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_studio.py`, inside `class StepsValidationTests`, add:

```python
    def test_device_field_accepted(self):
        for value in (1, 2, "1", "2"):
            errors = steps.validate_steps(
                [{"action": "tap_text", "text": "Chats", "device": value}])
            self.assertEqual([], errors, "device=%r should validate" % (value,))

    def test_device_field_rejects_out_of_range(self):
        for value in (0, 3, -1, "two", 1.5):
            errors = steps.validate_steps(
                [{"action": "tap_text", "text": "Chats", "device": value}])
            self.assertTrue(errors, "device=%r should be rejected" % (value,))
            self.assertIn("device", errors[0]["message"])

    def test_device_absent_means_device_one(self):
        self.assertEqual([], steps.validate_steps([{"action": "launch"}]))

    def test_spec_registry_also_accepts_device(self):
        errors = spec.validate_doc(
            [{"name": "s", "steps": [{"action": "tap_text", "text": "x",
                                      "device": 2}]}])
        self.assertEqual([], errors)
```

- [ ] **Step 2: Run and watch it fail**

Run: `.venv/bin/python -m unittest tests.test_studio.StepsValidationTests 2>&1 | tail -12`
Expected: `test_device_field_rejects_out_of_range` fails, because an unknown `device` key is currently ignored entirely. `test_device_field_accepted` passes for the same reason, which is exactly why the rejection test is the one that proves the field is wired up.

- [ ] **Step 3: Add the common field**

In `demo_maker/steps.py`, define the field above the common-field loop that starts at line 170, and extend that loop:

```python
# Device applies to every action, attached here alongside narration so the
# editor forms always offer it. A select rather than a plain int so the editor
# renders a dropdown and validation rejects anything but 1 or 2. Omitting it
# means device 1, with no inheritance from earlier steps, so a step reads the
# same wherever it sits in the file.
_DEVICE_FIELD = _f("device", "select", False, None,
                   options=["1", "2"],
                   help_text="which device this step runs on; 1 is the main "
                             "phone, 2 the second phone or emulator. An if step "
                             "reading last_command must name the same device as "
                             "the exec step it follows, since each device keeps "
                             "its own exec output.")

for _action in ACTIONS.values():
    _action["fields"].extend(_NARRATION)
    _action["fields"].append(_DEVICE_FIELD)
```

Leave the existing `_NARRATION` definition at lines 22-27 as it is.

- [ ] **Step 4: Verify the select validation path really applies**

Read `demo_maker/steps.py:264-281`. The `missing` computation is `value is None or (isinstance(value, str) and not value.strip())`, so a `0` value counts as present and falls through to the select branch, where `str(0) not in ["1", "2"]` fails. No edit needed. If that check ever changes, `device: 0` would silently pass, so this is worth a comment rather than an assumption.

One more case to confirm: `_f(..., default=None)` means `default_step()` (lines 343-347) will not add a `device` key, so a newly created step starts device-agnostic. That is what we want.

- [ ] **Step 5: Run the tests**

Run: `.venv/bin/python -m unittest tests.test_studio.StepsValidationTests 2>&1 | tail -4`
Expected: `OK`.

Run: `.venv/bin/python -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, with the count higher than the 60 at baseline (the four new validator tests).

- [ ] **Step 6: Verify the editor will render it**

Run: `.venv/bin/python -c "from demo_maker import steps, json; print(json.dumps(steps.ACTIONS['tap_text']['fields'][-1]))"`
Expected: `{"name": "device", "type": "select", "required": false, "default": null, "help": "...", "options": ["1", "2"]}`

- [ ] **Step 7: Commit**

```bash
git add demo_maker/steps.py tests/test_studio.py
git commit -m "Add the optional device field to the step schema

Every action in both registries gains a device select with options 1 and 2,
attached in the same single place narration already is, so the editor forms
pick it up with no frontend change. Absent means device 1, with no inheritance
from earlier steps, so a step means the same thing wherever it sits in the
file.

The field help spells out the one sharp edge: each device keeps its own
LAST_EXEC_OUTPUT, so an if step reading last_command has to name the same
device as the exec step it follows."
```

---

### Task 4: Second-device CLI flags and resolution

Add `--serial-2`, `--app-id-2`, `--activity-2` to both drivers, plus `--compose-height` on the demo driver, and relax auto-detection so a second attached device is usable.

**Files:**
- Modify: `android-demo.sh` (usage comment, defaults, arg parse, autodetect block, activity resolution, screen sizes)
- Modify: `android-spec-test.sh` (same, minus `--compose-height`)
- Test: `tests/run_bash_tests.sh`

**Interfaces:**
- Consumes: `SERIALS`, `DEVICE_COUNT`, `SCREEN_W_BY_DEV`, `SCREEN_H_BY_DEV`, `APP_BY_DEV`, `ACTIVITY_BY_DEV`, `use_device` from Task 2.
- Produces: both scripts accept `--serial-2 <s>`, `--app-id-2 <p>`, `--activity-2 <a>`. The demo driver also accepts `--compose-height <n>`, stored in `COMPOSE_HEIGHT` (default 1080). With no `--serial-2`, a single other attached device is adopted automatically.

- [ ] **Step 1: Add usage lines and defaults to the demo driver**

In `android-demo.sh`'s leading comment block, after the `--loose` line, add:

```bash
#   ./android-demo.sh --serial-2 SERIAL --app-id-2 com.other.app   # record a second phone/emulator and composite both side by side
#   ./android-demo.sh --compose-height 1440                       # taller composite frame (default 1080)
```

In the defaults block after `SERIAL=""` (line 194), add:

```bash
SERIAL_2=""
APP_ID_2=""
ACTIVITY_OVERRIDE_2=""
COMPOSE_HEIGHT=1080
```

In the arg parser, after the `--serial)` case, add:

```bash
    --serial-2) shift; SERIAL_2="${1:-}" ;;
    --app-id-2) shift; APP_ID_2="${1:-}" ;;
    --activity-2) shift; ACTIVITY_OVERRIDE_2="${1:-}" ;;
    --compose-height) shift; COMPOSE_HEIGHT="${1:-1080}" ;;
```

- [ ] **Step 2: Replace the auto-detect block**

Replace the whole `if [ -z "$SERIAL" ]; then ... fi` block through the `ADB()`/`SERIALS` lines added in Task 2 with:

```bash
# Primary device: unchanged, including the fatal error when several are
# attached and no --serial says which one.
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

# Second device. Emulators count here even though the primary auto-detect
# skips them: "the same app on a phone and an emulator" is exactly the case
# this exists for. An explicit --serial-2 is taken as given; without one, a
# single other attached device is adopted, and anything else (none, or two or
# more) leaves this a single-device run.
if [ -n "$SERIAL_2" ]; then
  if [ "$SERIAL_2" = "$SERIAL" ]; then
    echo "ERROR: --serial-2 is the same device as --serial ($SERIAL)." >&2
    echo "       Pick a different phone or emulator, or drop --serial-2." >&2
    exit 1
  fi
  SERIALS[1]="$SERIAL_2"
  DEVICE_COUNT=2
else
  OTHERS="$(adb devices | awk -v s="$SERIAL" '$2 == "device" && $1 != s {print $1}')"
  other_count="$(printf '%s\n' "$OTHERS" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$other_count" -eq 1 ]; then
    SERIALS[1]="$(printf '%s\n' "$OTHERS" | head -n 1)"
    DEVICE_COUNT=2
  elif [ "$other_count" -gt 1 ]; then
    echo "==> $other_count other devices are attached but --serial-2 was not given; recording device 1 only" >&2
    adb devices | tail -n +2 >&2
  fi
fi

# The second device hosts the same app unless told otherwise, which covers the
# common "same app on two phones" case with only --serial-2.
[ -n "$APP_ID_2" ] || APP_ID_2="$APP_ID"
```

- [ ] **Step 3: Share one activity resolver and fill device 2's geometry**

Replace the existing inline activity resolution (currently lines 283-295) with a function both devices use, so there is no second copy to drift:

```bash
# Resolves the launchable activity for a package: an explicit override wins,
# otherwise ask the package manager for the MAIN/LAUNCHER intent handler, and
# fall back to the conventional ".MainActivity" if that comes up empty.
resolve_activity_for() {
  local serial="$1" pkg="$2" override="$3" brief act
  if [ -n "$override" ]; then
    case "$override" in
      */*) printf '%s' "$override" ;;
      *)   printf '%s' "${pkg}/${override}" ;;
    esac
    return 0
  fi
  brief="$(adb -s "$serial" shell cmd package resolve-activity --brief \
            -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
            "$pkg" 2>/dev/null | tr -d '\r')"
  act="$(printf '%s\n' "$brief" | grep "^${pkg}/" | head -n 1)"
  [ -n "$act" ] || act="$(printf '%s\n' "$brief" | grep -m1 '/' || true)"
  printf '%s' "${act:-${pkg}/.MainActivity}"
}

ACTIVITY="$(resolve_activity_for "$SERIAL" "$APP_ID" "$ACTIVITY_OVERRIDE")"
```

Extend the geometry block from Task 2 so device 2 gets its own entries:

```bash
SCREEN_W_BY_DEV=("$SCREEN_W" "")
SCREEN_H_BY_DEV=("$SCREEN_H" "")
APP_BY_DEV=("$APP_ID" "")
ACTIVITY_BY_DEV=("$ACTIVITY" "")

if [ "$DEVICE_COUNT" -eq 2 ]; then
  APP_BY_DEV[1]="$APP_ID_2"
  ACTIVITY_BY_DEV[1]="$(resolve_activity_for "${SERIALS[1]}" "$APP_ID_2" "$ACTIVITY_OVERRIDE_2")"
  read -r w2 h2 < <(adb -s "${SERIALS[1]}" shell wm size 2>/dev/null | grep -o '[0-9]\+x[0-9]\+' | tail -1 | tr 'x' ' ')
  SCREEN_W_BY_DEV[1]="${w2:-1080}"
  SCREEN_H_BY_DEV[1]="${h2:-2400}"
  echo "==> recording 2 devices: ${SERIALS[0]} and ${SERIALS[1]}" >&2
fi
use_device 1
```

- [ ] **Step 4: Apply the same flags to the spec driver**

In `android-spec-test.sh`: add `SERIAL_2`, `APP_ID_2`, `ACTIVITY_OVERRIDE_2` to the defaults; add the three `--*-2` cases to its parser (no `--compose-height`, there is no video); replace its autodetect block with the same primary/second-device logic; add the same `resolve_activity_for` function and call it for the primary and, when `DEVICE_COUNT` is 2, the second device; and fill `SCREEN_W_BY_DEV[1]` / `SCREEN_H_BY_DEV[1]` from device 2's `wm size`. Its existing `source` of the library and `use_device 1` stay where they are.

- [ ] **Step 5: Test the flag wiring**

Add to `tests/run_bash_tests.sh`, in the demo-driver smoke section:

```bash
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

expect_grep "demo seeds SERIALS" "$DEMO" 'SERIALS=("$SERIAL" "")'
expect_grep "spec seeds SERIALS" "$SPEC" 'SERIALS=("$SERIAL" "")'
expect_grep "demo rejects a duplicate second serial" "$DEMO" "--serial-2 is the same device"
```

- [ ] **Step 6: Run both suites**

Run: `bash -n android-demo.sh && bash -n android-spec-test.sh && tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: `0 failed`, with the pass count above the previous task's.

- [ ] **Step 7: Commit**

```bash
git add android-demo.sh android-spec-test.sh tests/run_bash_tests.sh
git commit -m "Add second-device flags to both drivers

--serial-2, --app-id-2 and --activity-2 on android-demo.sh and
android-spec-test.sh, plus --compose-height on the demo driver. --app-id-2
defaults to --app-id, so the common 'same app on a phone and an emulator' case
needs only --serial-2.

Auto-detection keeps its current behavior when --serial is absent, including
the fatal error for multiple attached devices. With --serial given, a single
other attached device is adopted as device 2; two or more others prints which
ones and continues single-device rather than guessing. Emulators count as
candidates for device 2 even though the primary auto-detect skips them, since
recording alongside an emulator is the case this exists for.

Activity resolution moved into resolve_activity_for() so both devices share
one code path instead of a second copy that could drift."
```

---

### Task 5: Per-step device dispatch and per-device segments in the demo driver

Make each step run against the device it names, and record every device segment by segment.

**Files:**
- Modify: `android-demo.sh` (`step_device` helper, `run_leaf_step`, `run_steps` if-branch, `dry_run_steps`, `start_segment`, `stop_segment`, segment filenames)
- Test: `tests/run_bash_tests.sh`

**Interfaces:**
- Consumes: `SERIALS`, `DEVICE_COUNT`, `use_device` from Task 2; `SERIALS[1]`, `APP_BY_DEV`, `ACTIVITY_BY_DEV` from Task 4.
- Produces:
  - `step_device <step-json>` returns 0 and points the cursor at the step's device, or returns 1 after printing an error for a `device` value that is not 1 or 2.
  - `segment_path <device> [index]` prints the local path of a segment file.
  - `start_segment` / `stop_segment` record and pull every live device per segment.
  - Segment files: `$WORKDIR/video/seg_<s>_1.mp4`, `$WORKDIR/video/seg_<s>_2.mp4`.

- [ ] **Step 1: Write the failing dispatch test**

Add to `tests/run_bash_tests.sh`:

```bash
# ---------------------------------------------------------------- step dispatch
# step_device lives in the demo driver, which cannot be sourced (it executes on
# load), so lift the function out of the file text. Same technique the suite
# already uses via expect_grep.
eval "$(sed -n '/^step_device() {/,/^}/p' "$DEMO")"
ADB_LOG=""
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
```

- [ ] **Step 2: Run and watch it fail**

Run: `tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: failures, because `step_device` does not exist yet, so `eval` defines nothing and the calls fail with 127.

- [ ] **Step 3: Add `step_device` and call it from every entry point**

In `android-demo.sh`, just above `run_leaf_step`, add:

```bash
# Points the device cursor at the step's own device. Absent means device 1 and
# never inherits from an earlier step, so a step reads the same wherever it
# sits in the file. Called from all three step entry points (leaf, if branch,
# dry run) so no path can miss it.
step_device() {
  local d
  d="$(jq -r '.device // 1' <<<"$1")"
  case "$d" in
    1|2) use_device "$d" ;;
    *) echo "ERROR: step 'device' must be 1 or 2 (got '$d')" >&2; return 1 ;;
  esac
}
```

In `run_leaf_step` (currently line 1266), insert `step_device "$step" || return 1` after the `local` declarations and before the `action=` read, so the step is echoed with the right device context.

In `run_steps`'s `if)` branch (currently line 1295), insert `step_device "$step" || return 1` right after the `echo "-- step ${id}: if..."` line. The condition evaluator reads device state, so it must run against the step's device.

In `dry_run_steps`, insert the same call at the top of its per-step body, and name the device in its `echo` so a dry run makes the routing visible:

```bash
  dev="$(jq -r '.device // empty' <<<"$step")"
  echo "-- dry step ${id}: ${action}${dev:+  [device ${dev}]}"
```

- [ ] **Step 4: Make the segment pump cover every device**

Replace the `SEG_INDEX`/`SEG_ELAPSED`/`REC_PID` initialization (currently lines 1144-1146) with:

```bash
SEG_INDEX=0
SEG_ELAPSED="0"
REC_PID_1=""
REC_PID_2=""
```

Replace `start_segment` and `stop_segment` (currently lines 1148-1176) with:

```bash
# Segment files are per (segment, device): seg_0_1.mp4, seg_0_2.mp4. A second
# recorder's pull must never overwrite the first's.
segment_path() {  # segment_path <device> [index]
  printf '%s/video/seg_%s_%s.mp4' "$WORKDIR" "${2:-$SEG_INDEX}" "$1"
}

# Every recorder is launched before the sleep, and every recorder is signalled
# before any of them is waited on. Winding device 1 down before device 2 is even
# signalled would leave device 2 recording extra seconds at every cut, so its
# pane would drift further behind on every segment.
start_segment() {
  local d
  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    adb -s "${SERIALS[$((d - 1))]}" shell screenrecord --bit-rate 8000000 \
      "/sdcard/_android_demo_seg_${SEG_INDEX}_${d}.mp4" &
    case "$d" in
      1) REC_PID_1=$! ;;
      2) REC_PID_2=$! ;;
    esac
  done
  sleep 1
}

stop_segment() {
  local d pid waited

  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    adb -s "${SERIALS[$((d - 1))]}" shell pkill -INT screenrecord >/dev/null 2>&1 || true
  done

  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    case "$d" in
      1) pid="$REC_PID_1" ;;
      2) pid="$REC_PID_2" ;;
    esac
    [ -n "$pid" ] || continue
    # kill -INT on the LOCAL "adb shell screenrecord &" pid does not reliably
    # propagate to the REMOTE screenrecord process; adb doesn't forward signals
    # through a plain (non-PTY) shell session, so the local wrapper can sit
    # blocked on the device's output stream forever. Signal the on-device
    # process directly over a fresh adb call instead; that's what actually makes
    # it finalize the mp4 and close the stream the local wrapper is waiting on.
    # Bound the subsequent wait and fall back to a hard kill so a genuinely
    # wedged wrapper can never hang the whole run.
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 8 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  sleep 1

  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    adb -s "${SERIALS[$((d - 1))]}" pull \
      "/sdcard/_android_demo_seg_${SEG_INDEX}_${d}.mp4" \
      "$(segment_path "$d")" >/dev/null 2>&1
    adb -s "${SERIALS[$((d - 1))]}" shell rm -f \
      "/sdcard/_android_demo_seg_${SEG_INDEX}_${d}.mp4" >/dev/null 2>&1 || true
  done

  REC_PID_1=""
  REC_PID_2=""
}
```

The three loops are signal-all, then wait-all, then pull-all. Do not merge them; the ordering is the correctness argument for pane alignment.

- [ ] **Step 5: Prove `perform_action` follows the cursor**

No edit is needed inside `perform_action`: `use_device` has already swapped `APP_ID` and `ACTIVITY`, and the `launch`/`reopen`/`pm_clear` cases read those bare names. Add an assertion so a future edit cannot quietly hardcode a device:

```bash
expect_grep "launch uses the cursor's app id" "$DEMO" 'am force-stop "$APP_ID"'
expect_grep "launch uses the cursor's activity" "$DEMO" 'am start -n "$ACTIVITY"'
```

- [ ] **Step 6: Run both suites**

Run: `bash -n android-demo.sh && tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: `0 failed`, with the pass count above the previous task's.

- [ ] **Step 7: Commit**

```bash
git add android-demo.sh tests/run_bash_tests.sh
git commit -m "Dispatch each step to its device and record every device

A step_device helper reads the step's device field and points the cursor,
defaulting to 1 with no inheritance. It is called from all three step entry
points (leaf, if branch, dry run) so no path can forget. perform_action needs
no change: use_device has already swapped APP_ID and ACTIVITY, so launch,
reopen and pm_clear on a device 2 step act on that device's app.

Segments are now per (segment, device), and the recorder pump runs in three
ordered phases: signal every device, then wait for every device, then pull
every device. Collapsing those would be the bug the ordering exists to
prevent. Winding device 1 down before device 2 is even signalled leaves
device 2 recording extra seconds at every cut, so its pane drifts further
behind on every segment.

Note the internal workdir layout gains a _1 suffix on single-device runs
(seg_0.mp4 becomes seg_0_1.mp4). Only visible with --keep-workdir."
```

---

### Task 6: Side-by-side compositing

A new pure-function library plus phase 4 wiring.

**Files:**
- Create: `android-compose-lib.sh`
- Modify: `android-demo.sh` (source the new lib, replace the phase 4 input loop and filter construction)
- Test: `tests/run_bash_tests.sh`

**Interfaces:**
- Consumes: `DEVICE_COUNT`, `SCREEN_W_BY_DEV`, `SCREEN_H_BY_DEV`, `COMPOSE_HEIGHT`.
- Produces:
  - `pane_width_for <screen_w> <screen_h> <height>` prints an even pane width, minimum 2.
  - `build_compose_geometry <height>` sets `COMPOSE_W` and `COMPOSE_H`.
  - `build_concat_filter <segment_count>` prints the full `-filter_complex` string. For `DEVICE_COUNT=1` this is byte-identical to today's output.

- [ ] **Step 1: Write the failing tests**

Add a new section to `tests/run_bash_tests.sh`, after the poll-knobs section and before the demo-driver smoke section:

```bash
# ---------------------------------------------------------------- compositing
# Sourced directly: the composing functions are pure and touch no device, which
# is the whole reason they live in their own file.
COMPOSE_HEIGHT=1080
# shellcheck source=/dev/null
. "$ROOT/android-compose-lib.sh"

DEVICE_COUNT=1
expect "single device filter is unchanged" \
  "$(build_concat_filter 3)" \
  "[0:v][1:v][2:v]concat=n=3:v=1:a=0[outvraw];[outvraw]fps=30,format=yuv420p[outv]"
expect "single device, single segment" \
  "$(build_concat_filter 1)" \
  "[0:v]concat=n=1:v=1:a=0[outvraw];[outvraw]fps=30,format=yuv420p[outv]"

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
expect_contains "device 1 pane is scaled to its width" "$f2" "[s0d1]scale=486:1080"
expect_contains "device 2 pane is scaled to its width" "$f2" "[s0d2]scale=486:1080"
expect_contains "hstack joins the two panes" "$f2" "[s0d1][s0d2]hstack=inputs=2[s0h]"
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
```

The last assertion is the important one: device 2 is 720x1600, so its pane is `720 * 1080 / 1600 = 486` while device 1's is also 486, and the differing input heights are absorbed by the `force_original_aspect_ratio=decrease` plus centered `pad`. Add one more device pair where the widths genuinely differ, so a future hardcoded pane width fails:

```bash
SCREEN_W_BY_DEV=(1080 1920)
SCREEN_H_BY_DEV=(2400 1080)
expect "a landscape second device gets its own pane width" \
  "$(printf '%s' "$(build_concat_filter 1)" | grep -o 'scale=[0-9]*:1080' | tr '\n' ' ')" \
  "scale=486:1080 scale=1920:1080 "
```

- [ ] **Step 2: Run and watch it fail**

Run: `tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: failures, because `android-compose-lib.sh` does not exist. The `.` of a missing file makes the suite exit at that point.

- [ ] **Step 3: Write the compositing library**

Create `android-compose-lib.sh`:

```bash
#!/usr/bin/env bash
# Video compositing arithmetic for multi-device recordings. Pure functions:
# they read device geometry from the arrays below, print a filter graph, and
# touch no device, no file and no clock. That is what makes the filter graph
# testable without ffmpeg, and it is why the geometry lives here instead of in
# android-demo.sh next to the segment pump.
#
# android-demo.sh sets, before sourcing this file:
#   DEVICE_COUNT      1 or 2
#   SCREEN_W_BY_DEV   indexed array of per-device pixel widths
#   SCREEN_H_BY_DEV   indexed array of per-device pixel heights
#   COMPOSE_HEIGHT    pane height for the composite, default 1080

# Pane width for one device at a common height. h264 with yuv420p needs even
# dimensions, and an odd pane width makes the encoder round silently, so round
# up here rather than discovering it as a one-pixel asymmetry between panes.
pane_width_for() {  # pane_width_for <screen_w> <screen_h> <height>
  awk -v sw="$1" -v sh="$2" -v h="$3" 'BEGIN {
    w = (sh > 0) ? (sw * h / sh) : h
    w = int(w)
    if (w % 2) w++
    if (w < 2) w = 2
    printf "%d", w
  }'
}

# Sets COMPOSE_W and COMPOSE_H for the whole composite. Every pane is the same
# height because hstack requires it; the output width is the sum of the pane
# widths. Two 1080x2400 phones at 1080 give 972x1080, which is a near-square
# frame: that is the honest consequence of putting two portrait screens side by
# side, and COMPOSE_HEIGHT is the knob for it.
build_compose_geometry() {  # build_compose_geometry <height>
  local h="$1" d i w=0
  h=$(( h - (h % 2) ))
  [ "$h" -ge 16 ] || h=16
  for ((d = 1; d <= DEVICE_COUNT; d++)); do
    i=$((d - 1))
    w=$(( w + $(pane_width_for "${SCREEN_W_BY_DEV[$i]}" "${SCREEN_H_BY_DEV[$i]}" "$h") ))
  done
  COMPOSE_W="$w"
  COMPOSE_H="$h"
}

# Prints the -filter_complex string for SEGMENT_COUNT segments.
#
# One device keeps the historical graph exactly: a plain temporal concat, no
# scaling, no hstack. Two devices get each segment's panes normalized to a
# common height, rebased, and joined with hstack, then the composites are
# concat in segment order.
#
# hstack needs no explicit padding for a pane that runs out early: it is
# framesync-based with repeatlast=1, so the last frame of the shorter input is
# held while the longer one finishes. Verified locally, 5s hstacked with 3s
# gives 5.000s with the shorter pane's final color still showing at t=4s. That
# is also the behavior we want: a device with nothing to show should idle
# visibly rather than vanish from the frame.
build_concat_filter() {  # build_concat_filter <segment_count>
  local seg_count="$1" s d i idx chain="" join pane_w h

  if [ "${DEVICE_COUNT:-1}" -le 1 ]; then
    for ((s = 0; s < seg_count; s++)); do
      chain="${chain}[${s}:v]"
    done
    chain="${chain}concat=n=${seg_count}:v=1:a=0[outvraw]"
    printf '%s;[outvraw]fps=30,format=yuv420p[outv]' "$chain"
    return 0
  fi

  build_compose_geometry "${COMPOSE_HEIGHT:-1080}"
  h="$COMPOSE_H"

  for ((s = 0; s < seg_count; s++)); do
    for ((d = 1; d <= DEVICE_COUNT; d++)); do
      i=$((d - 1))
      idx=$((s * DEVICE_COUNT + i))
      pane_w="$(pane_width_for "${SCREEN_W_BY_DEV[$i]}" "${SCREEN_H_BY_DEV[$i]}" "$h")"
      chain="${chain}[${idx}:v]scale=${pane_w}:${h}:force_original_aspect_ratio=decrease,pad=${pane_w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s${s}d${d}]"
    done
    join=""
    for ((d = 1; d <= DEVICE_COUNT; d++)); do
      join="${join}[s${s}d${d}]"
    done
    chain="${chain}${join}hstack=inputs=${DEVICE_COUNT}[s${s}h]"
  done

  for ((s = 0; s < seg_count; s++)); do
    chain="${chain}[s${s}h]"
  done
  chain="${chain}concat=n=${seg_count}:v=1:a=0[outvraw]"
  printf '%s;[outvraw]fps=30,format=yuv420p[outv]' "$chain"
}
```

Note the input index arithmetic: `idx = s * DEVICE_COUNT + i`, so inputs arrive segment-major, which is the order the `-i` flags in the driver are added.

- [ ] **Step 4: Wire it into the demo driver**

In `android-demo.sh`, add `source "${SCRIPT_DIR}/android-compose-lib.sh"` immediately after the `source` of the UI library from Task 1.

Then replace the phase 4 input loop and filter construction (currently lines 1402-1417) with:

```bash
args=()
for s in $(seq 0 $((SEG_COUNT - 1))); do
  for d in $(seq 1 "$DEVICE_COUNT"); do
    args+=(-i "$(segment_path "$d" "$s")")
  done
done
filter="$(build_concat_filter "$SEG_COUNT")"
```

Keep the surrounding comment block about why every run re-encodes, the `SEG_COUNT` line, the `fps_mode cfr` / `-g 60` / `-keyint_min 30` / `-sc_threshold 0` flags, and the `ffmpeg` invocation itself exactly as they are. Only the input loop and the filter construction are replaced.

- [ ] **Step 5: Run both suites**

Run: `bash -n android-compose-lib.sh && bash -n android-demo.sh && tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: `0 failed`, with the pass count above the previous task's.

- [ ] **Step 6: Verify the filter graph actually runs through ffmpeg**

This is the one claim in the plan that a stubbed bash test cannot prove, so prove it with real ffmpeg on synthetic clips. Two portrait-shaped inputs, one 3s and one 2s, hstacked:

Run:
```bash
cd "$(mktemp -d)" && \
ffmpeg -y -loglevel error -f lavfi -i "color=c=red:s=486x1080:d=3" -pix_fmt yuv420p a.mp4 && \
ffmpeg -y -loglevel error -f lavfi -i "color=c=blue:s=486x1080:d=2" -pix_fmt yuv420p b.mp4 && \
ffmpeg -y -loglevel error -i a.mp4 -i b.mp4 -filter_complex "[0:v]scale=486:1080:force_original_aspect_ratio=decrease,pad=486:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s0d1];[1:v]scale=486:1080:force_original_aspect_ratio=decrease,pad=486:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[s0d2];[s0d1][s0d2]hstack=inputs=2[s0h];[s0h]concat=n=1:v=1:a=0[outvraw];[outvraw]fps=30,format=yuv420p[outv]" -map "[outv]" -fps_mode cfr -c:v libx264 -preset veryfast -crf 20 -g 60 -keyint_min 30 -sc_threshold 0 out.mp4 && \
ffprobe -v error -show_entries stream=width,height -of default=noprint_wrappers=1 out.mp4
```
Expected: `width=972` and `height=1080`, exit 0, no filter errors.

Then confirm the shorter pane is held rather than truncated:
```bash
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 out.mp4
```
Expected: about `3.0`, not `2.0`.

- [ ] **Step 7: Commit**

```bash
git add android-compose-lib.sh android-demo.sh tests/run_bash_tests.sh
git commit -m "Composite two devices side by side

A new android-compose-lib.sh holds the compositing arithmetic as pure
functions: pane geometry from each device's screen size, and the
-filter_complex string for a run's segments. Neither touches a device, a file
or a clock, which is what makes the filter graph assertable in the bash suite
without ffmpeg or hardware.

One device keeps the historical graph byte for byte: a plain temporal concat,
no scaling, no hstack. Two devices normalize each pane to a common height,
rebase it with setpts so a slow start does not offset the pair, and join with
hstack. Input indices run segment-major, matching the order the -i flags are
added.

hstack needs no padding filter for a pane that runs out early. It is
framesync-based with repeatlast=1, so the last frame of the shorter input is
held while the longer finishes; verified locally, 5s hstacked with 3s gives
5.000s with the shorter pane intact at t=4s. A device with nothing to show
should idle visibly rather than vanish from the frame."
```

---

### Task 7: Per-step device dispatch in the spec driver

**Files:**
- Modify: `android-spec-test.sh` (`run_step_list`, dry-run equivalent if any)
- Test: `tests/run_bash_tests.sh`

**Interfaces:**
- Consumes: `use_device`, `SERIALS`, `APP_BY_DEV`, `ACTIVITY_BY_DEV` from Tasks 2 and 4.
- Produces: spec scenarios honor `"device": 1|2` on any step, including inside `if.then/else`.

- [ ] **Step 1: Add the assertion**

Add to `tests/run_bash_tests.sh`:
```bash
expect_grep "spec dispatches per step" "$SPEC" 'step_device "\$step"'
expect_grep "spec dispatches on the if branch" "$SPEC" 'step_device "\$step" || return 1'
```

- [ ] **Step 2: Run and watch it fail**

Run: `tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: both new assertions fail, since `android-spec-test.sh` has no `step_device` call.

- [ ] **Step 3: Dispatch per step in the spec driver**

In `android-spec-test.sh`, add a `step_device` copy just above `run_step_list` (currently line 438). It is the same three lines as the demo driver's, and the duplication is deliberate: the demo driver cannot source anything at that point without a circular dependency on itself, and three lines is cheaper than a new shared file for one function.

```bash
# Points the device cursor at the step's own device. Absent means device 1.
step_device() {
  local d
  d="$(jq -r '.device // 1' <<<"$1")"
  case "$d" in
    1|2) use_device "$d" ;;
    *) echo "ERROR: step 'device' must be 1 or 2 (got '$d')" >&2; return 1 ;;
  esac
}
```

In `run_step_list`, insert `step_device "$step" || return 1` right after `id="${prefix}${i}"` (currently line 447), before the `if [ "$action" = "if" ]` branch. Placing it there covers the `if` step's condition evaluation, the `exec` special case, and the `perform_action` dispatch in one line, so no path can miss it.

Also add the device to the step echo so a spec run log says which device each step hit:

```bash
  dev="$(jq -r '.device // empty' <<<"$step")"
```
and append `${dev:+ [device ${dev}]}` to the two existing `echo` lines that print a step.

- [ ] **Step 4: Run both suites**

Run: `bash -n android-spec-test.sh && tests/run_bash_tests.sh 2>&1 | tail -3`
Expected: `0 failed`, with the pass count above the previous task's.

- [ ] **Step 5: Commit**

```bash
git add android-spec-test.sh tests/run_bash_tests.sh
git commit -m "Honor the device field in spec scenarios

A spec scenario can now assert against the second phone, for the case where
the app under test is only verifiable once something happens on the companion.
One step_device call sits right after the id is computed, above the if/exec/
perform_action split, so the condition evaluator, the exec special case and
the action dispatch are all covered by the same line.

The step_device copy is deliberate: the demo driver cannot source the spec
driver, and three lines is cheaper than a shared file for one function."
```

---

### Task 8: Settings, and the two argv builders

**Files:**
- Modify: `demo_maker/config.py:34-61` (`DEFAULTS`, `_BOOL_KEYS`, `_INT_KEYS`)
- Modify: `demo_maker/runner.py:115-191` (`build_argv`)
- Modify: `demo_maker/spec.py:223-264` (`build_spec_argv`)
- Test: `tests/test_studio.py`

**Interfaces:**
- Consumes: nothing from the shell side; this is what makes the new flags reachable from the studio.
- Produces settings keys `second_device` (bool, default `False`), `serial_2` (str), `app_id_2` (str), `activity_2` (str), `compose_height` (int, default `1080`).

- [ ] **Step 1: Write the failing tests**

In `tests/test_studio.py`, inside `class CommandBuilderTests`, add:

```python
    def test_second_device_off_emits_nothing(self):
        argv, errors = self.argv_for(self.base_settings(), "dry")
        self.assertEqual([], errors)
        joined = " ".join(argv)
        for flag in ("--serial-2", "--app-id-2", "--activity-2",
                     "--compose-height"):
            self.assertNotIn(flag, joined)

    def test_second_device_on_emits_flags(self):
        argv, errors = self.argv_for(self.base_settings(
            second_device=True, serial_2="SER2",
            app_id_2="com.other.app", activity_2="com.other.app/.MainActivity",
            compose_height=1440), "dry")
        self.assertEqual([], errors)
        joined = " ".join(argv)
        self.assertIn("--serial-2 SER2", joined)
        self.assertIn("--app-id-2 com.other.app", joined)
        self.assertIn("--activity-2 com.other.app/.MainActivity", joined)
        self.assertIn("--compose-height 1440", joined)

    def test_second_device_app_defaults_to_primary(self):
        argv, errors = self.argv_for(self.base_settings(
            second_device=True, serial_2="SER2"), "dry")
        self.assertEqual([], errors)
        joined = " ".join(argv)
        self.assertIn("--app-id-2 com.example.app", joined)
        self.assertIn("--serial SER1 --serial-2 SER2", joined)

    def test_second_device_activity_defaults_to_primary(self):
        argv, _ = self.argv_for(self.base_settings(
            second_device=True, serial_2="SER2",
            activity="com.example.app/.MainActivity"), "dry")
        self.assertIn("--activity-2 com.example.app/.MainActivity",
                      " ".join(argv))

    def test_second_device_requires_a_serial(self):
        _, errors = self.argv_for(self.base_settings(
            second_device=True, serial_2=""), "dry")
        self.assertTrue(any("second device" in e for e in errors), errors)

    def test_second_device_rejects_the_same_serial(self):
        _, errors = self.argv_for(self.base_settings(
            second_device=True, serial_2="SER1"), "dry")
        self.assertTrue(any("same device" in e for e in errors), errors)
```

Add a spec-side equivalent inside `class SpecScenarioTests`, next to the existing `test_argv_*` methods:

```python
    def test_spec_argv_second_device(self):
        settings = dict(config.DEFAULTS)
        settings.update({
            "spec_script": self.script,
            "spec_scenarios_dir": self.tmp.name,
            "spec_app_id": "com.example.app",
            "serial": "SER1",
        })
        settings.update(overrides)
        argv, errors = spec.build_spec_argv(settings)
        return " ".join(argv), errors
```

plus three cases: off emits no second-device flags; on with `serial_2="SER2"` emits `--serial-2 SER2`; and `serial_2 == serial` errors with "same device". Use the same `self.script` / `self.tmp.name` fixture names that class already sets up; read its `setUp` before writing these.

- [ ] **Step 2: Run and watch it fail**

Run: `.venv/bin/python -m unittest tests.test_studio.CommandBuilderTests tests.test_studio.SpecScenarioTests 2>&1 | tail -12`
Expected: the new cases fail. `second_device` is not in `DEFAULTS`, so `base_settings` silently drops it and no flags are emitted.

- [ ] **Step 3: Add the settings keys**

In `demo_maker/config.py`, add to `DEFAULTS` after the `serial` entry:

```python
    "second_device": False,
    "serial_2": "",
    "app_id_2": "",
    "activity_2": "",
    "compose_height": 1080,
```

and update the type classes:

```python
_BOOL_KEYS = {"keep_workdir", "no_narration", "second_device"}
_INT_KEYS = {"segment_seconds", "compose_height"}
```

These keys are a hard gate: `load_settings` copies only keys present in `DEFAULTS`, and both `update_settings` and `server._merged_settings` drop anything else, so the keys must land before the frontend can send them.

- [ ] **Step 4: Teach `build_argv` about the second device**

In `demo_maker/runner.py`, add validation alongside the existing `serial` check (currently lines 137-139):

```python
    if settings.get("second_device"):
        serial_2 = str(settings.get("serial_2") or "").strip()
        if not serial_2:
            errors.append("second device enabled but no second serial selected")
        elif serial_2 == serial:
            errors.append("second device is the same device as the main one")
```

Then, after the existing `--activity` append (line 147), add:

```python
    if settings.get("second_device"):
        # --app-id-2 and --activity-2 fall back to the primary so the common
        # "same app on two phones" case needs only --serial-2.
        argv += ["--serial-2", str(settings.get("serial_2") or "").strip(),
                 "--app-id-2",
                 str(settings.get("app_id_2") or "").strip() or app_id]
        activity_2 = str(settings.get("activity_2") or "").strip() or activity
        if activity_2:
            argv += ["--activity-2", activity_2]
```

and, after the `--segment-seconds` append (line 185), add:

```python
    if settings.get("second_device"):
        argv += ["--compose-height",
                 str(max(240, int(settings.get("compose_height") or 1080)))]
```

- [ ] **Step 5: Teach `build_spec_argv` the same**

In `demo_maker/spec.py`, add the same validation after its `serial` check (currently lines 241-243), and after the `--activity` append (line 259) add:

```python
    if settings.get("second_device"):
        argv += ["--serial-2", str(settings.get("serial_2") or "").strip(),
                 "--app-id-2",
                 str(settings.get("app_id_2") or "").strip() or app_id]
        activity_2 = str(settings.get("activity_2") or "").strip() or activity
        if activity_2:
            argv += ["--activity-2", activity_2]
```

No `--compose-height` here: spec runs record nothing.

- [ ] **Step 6: Run the tests**

Run: `.venv/bin/python -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, with the count higher than before (the six new argv cases).

- [ ] **Step 7: Verify the flag order the tests assert on**

Run: `.venv/bin/python -c "
from demo_maker import runner, config, tempfile, pathlib, os
t = tempfile.mkdtemp()
p = pathlib.Path(t)
(p/'s.sh').write_text('x'); (p/'j.json').write_text('[]')
s = dict(config.DEFAULTS, script_path=str(p/'s.sh'), steps_path=str(p/'j.json'),
         out_dir=t, serial='SER1', app_id='com.example.app',
         second_device=True, serial_2='SER2')
print(' '.join(runner.build_argv(s, 'dry')[0]))
"`
Expected: the command contains `--serial SER1 --serial-2 SER2 --app-id-2 com.example.app`, in that order.

- [ ] **Step 8: Commit**

```bash
git add demo_maker/config.py demo_maker/runner.py demo_maker/spec.py tests/test_studio.py
git commit -m "Wire the second device through settings and both argv builders

Five new settings keys: second_device, serial_2, app_id_2, activity_2 and
compose_height. These are a hard gate, since load_settings, update_settings
and _merged_settings all drop keys absent from DEFAULTS.

build_argv and build_spec_argv emit --serial-2/--app-id-2/--activity-2 when
second_device is set, and the demo builder adds --compose-height. app_id_2
and activity_2 fall back to the primary, so 'the same app on a phone and an
emulator' needs only a second serial. The spec builder gets no compose
height, because spec runs record nothing.

Validation rejects a second device with no serial and a second serial equal to
the first, both with messages naming the problem."
```

---

### Task 9: The studio UI

Opt-in companion block in the App tab, keyed package lists, and the settings the run needs.

**Files:**
- Modify: `web/index.html:33-63` (App tab markup)
- Modify: `web/app.js:311-417` (`loadPackages`, `renderAppOptions`, `filteredPackages`, `renderAppSuggestions`, `highlightSuggestion`, `closeAppSuggestions`, `pickApp`, `resolveActivity`), `web/app.js:173-241` (`bindAppTab`), `web/app.js:1385-1404` (`effectiveSettings`)
- Modify: `web/style.css` (only if the second block needs spacing the existing `.row`/`.hint` rules do not give)

**Interfaces:**
- Consumes: settings keys from Task 8; the `device` field spec from Task 3.
- Produces: `#second-device-toggle` (checkbox), `#device-select-2`, `#app-input-2`, `#app-suggestions-2`, `#app-filter-2`, `#app-resolve-2`, `#activity-input-2`, `#apps-hint-2`, and a `#second-device-block` wrapper. JS: `State.packagesBySerial` (object keyed by serial, replacing `State.packages`), `SLOTS` (a two-entry map from slot number to DOM ids and settings keys), and slot-parameterized `loadPackages`, `filteredPackages`, `renderAppSuggestions`, `highlightSuggestion`, `closeAppSuggestions`, `pickApp`, `resolveActivity`.

- [ ] **Step 1: Add the markup**

In `web/index.html`, inside `#tab-app`, add a checkbox to the Device card after the `device-refresh` row:

```html
      <label class="inline"><input type="checkbox" id="second-device-toggle"> record a second device side by side</label>
```

Then add a second card after the existing Application card, before `</section>`:

```html
  <div class="card" id="second-device-block" hidden>
    <h2>Second device</h2>
    <div class="row">
      <select id="device-select-2"></select>
      <span class="hint">appears on the right of the recording</span>
    </div>
    <div class="row">
      <input id="app-filter-2" type="search" placeholder="filter package list (clear to see all)">
    </div>
    <div class="row">
      <div class="app-input-wrap">
        <input id="app-input-2" placeholder="com.example.app (defaults to the main app)"
               autocomplete="off" spellcheck="false">
        <ul id="app-suggestions-2" class="suggest" hidden></ul>
      </div>
      <button id="app-resolve-2" class="ghost">Resolve activity</button>
    </div>
    <div class="row">
      <input id="activity-input-2" placeholder="launch activity (auto)">
    </div>
    <p class="hint" id="apps-hint-2"></p>
  </div>
```

- [ ] **Step 2: Introduce the slot map and key the package lists**

In `web/app.js`, replace `packages: []` in the `State` object (line 17) with `packagesBySerial: {}`.

Add the slot map near the top of the file, after the `State` declaration:

```js
/* The App tab has two identical device/app slots. Slot 1 is the main device and
   has always existed; slot 2 appears when "record a second device" is checked.
   Everything that used to hardcode #app-input and State.packages takes a slot
   number instead, so the two slots cannot drift apart. */
const SLOTS = {
  1: {device: "#device-select", app: "#app-input", sug: "#app-suggestions",
      filter: "#app-filter", act: "#activity-input", hint: "#apps-hint",
      appKey: "app_id", actKey: "activity", serialKey: "serial"},
  2: {device: "#device-select-2", app: "#app-input-2", sug: "#app-suggestions-2",
      filter: "#app-filter-2", act: "#activity-input-2", hint: "#apps-hint-2",
      appKey: "app_id_2", actKey: "activity_2", serialKey: "serial_2"},
};
```

Replace `loadPackages` (lines 311-326) with a slot-aware version:

```js
async function loadPackages(slot) {
  const s = SLOTS[slot];
  const serial = State.settings[s.serialKey];
  const hint = $(s.hint);
  if (!serial) { hint.textContent = "connect a device first"; return; }
  hint.textContent = "loading packages...";
  try {
    const scope = State.settings.scope || "user";
    const data = await api("/api/apps?serial=" + encodeURIComponent(serial) +
                           "&scope=" + scope);
    State.packagesBySerial[serial] = (data.packages || []).map((p) => p.package);
    hint.textContent = State.packagesBySerial[serial].length + " packages";
    renderAppOptions(slot);
  } catch (err) {
    hint.textContent = err.message;
  }
}
```

Keying by serial rather than by slot is what stops switching devices from discarding the other slot's list, which the current flat `State.packages` does.

Replace the five suggestion helpers (lines 328-397) with slot-aware versions:

```js
function renderAppOptions(slot) {
  // Kept as the refresh entry point: re-render the suggestion dropdown if it
  // is currently visible (e.g. after the package list or filter changes).
  if (!$(SLOTS[slot].sug).hidden) renderAppSuggestions(slot);
}

function packagesFor(slot) {
  const serial = State.settings[SLOTS[slot].serialKey];
  return State.packagesBySerial[serial] || [];
}

function filteredPackages(slot) {
  const needle = ($(SLOTS[slot].filter).value || "").trim().toLowerCase();
  const pool = packagesFor(slot);
  return needle
    ? pool.filter((p) => p.toLowerCase().includes(needle))
    : pool.slice();
}

function renderAppSuggestions(slot) {
  const box = $(SLOTS[slot].sug);
  const typed = ($(SLOTS[slot].app).value || "").trim().toLowerCase();
  let items = filteredPackages(slot);
  if (typed) {
    const matches = items.filter((p) => p.toLowerCase().includes(typed));
    items = matches.length ? matches : filteredPackages(slot);
  }
  Suggest[slot] = {items: items.slice(0, 300), active: -1};
  box.innerHTML = "";
  if (!packagesFor(slot).length) {
    box.append(el("li", {class: "hint", text: "no packages loaded yet"}));
    box.hidden = false;
    return;
  }
  for (const pkg of Suggest[slot].items) {
    box.append(el("li", {text: pkg,
                         onmousedown: (event) => {
                           event.preventDefault();  // keep input focus
                           pickApp(slot, pkg);
                         }}));
  }
  if (!Suggest[slot].items.length) {
    box.append(el("li", {class: "hint", text: "no installed package matches"}));
  }
  box.hidden = false;
}

function highlightSuggestion(slot) {
  const lis = $$(SLOTS[slot].sug + " li:not(.hint)");
  const active = Suggest[slot].active;
  lis.forEach((li, i) => li.classList.toggle("active", i === active));
  if (lis[active] && lis[active].scrollIntoView) {
    lis[active].scrollIntoView({block: "nearest"});
  }
}

function closeAppSuggestions(slot) {
  $(SLOTS[slot].sug).hidden = true;
  Suggest[slot] = {items: [], active: -1};
}

function pickApp(slot, pkg) {
  const s = SLOTS[slot];
  $(s.app).value = pkg;
  closeAppSuggestions(slot);
  saveSettings({[s.appKey]: pkg});
  resolveActivity(slot);
}
```

Note the object-literal computed key `{[s.appKey]: pkg}`. It is ES2015, already assumed by this file, and it is what keeps the two slots from needing a duplicated save call.

Replace `const Suggest = {items: [], active: -1};` (line 339) with `const Suggest = {1: {items: [], active: -1}, 2: {items: [], active: -1}};`.

Replace `resolveActivity` (lines 399-417) with:

```js
async function resolveActivity(slot) {
  const s = SLOTS[slot];
  const serial = State.settings[s.serialKey];
  const pkg = $(s.app).value.trim();
  if (!serial || !pkg) return;
  $(s.act).placeholder = "resolving...";
  try {
    const data = await api("/api/activity", {
      method: "POST",
      body: {serial, package: pkg},
    });
    $(s.act).value = data.activity;
    $(s.act).placeholder = "launch activity (auto)";
    saveSettings({[s.appKey]: pkg, [s.actKey]: data.activity});
    toast("resolved: " + data.activity, "ok");
  } catch (err) {
    $(s.act).placeholder = "launch activity (auto)";
    toast("could not resolve activity: " + err.message, "error");
  }
}
```

- [ ] **Step 3: Update `bindAppTab` and add the companion bindings**

In `bindAppTab` (lines 173-241), thread slot 1 through every call: `loadPackages(1)`, `renderAppOptions(1)`, `highlightSuggestion(1)`, `closeAppSuggestions(1)`, and `resolveActivity(1)`. The `device-select` change handler becomes:

```js
  $("#device-select").addEventListener("change", async () => {
    const serial = $("#device-select").value;
    await saveSettings({serial});
    updateDeviceChip();
    if (serial) loadPackages(1);
  });
```

Add a `bindCompanionDevice()` function after `bindAppTab`, called from `boot()` next to the existing `bindAppTab()` call:

```js
function bindCompanionDevice() {
  const toggle = $("#second-device-toggle");
  toggle.checked = !!State.settings.second_device;
  $("#activity-input-2").value = State.settings.activity_2 || "";

  const apply = () => {
    const on = toggle.checked;
    $("#second-device-block").hidden = !on;
    if (!on) {
      closeAppSuggestions(2);
      return;
    }
    const sel = $("#device-select-2");
    sel.innerHTML = "";
    if (!State.devices.length) {
      sel.append(el("option", {value: "", text: "no devices found"}));
    }
    for (const dev of State.devices) {
      const label = dev.model
        ? dev.serial + "  (" + dev.model + ", " + dev.state + ")"
        : dev.serial + "  (" + dev.state + ")";
      sel.append(el("option", {value: dev.serial, text: label}));
    }
    // Never default to the main device's serial: the driver rejects a second
    // device identical to the first, and the failure would surface at run time.
    const saved = State.settings.serial_2;
    sel.value = (saved && State.devices.some((d) => d.serial === saved))
      ? saved
      : (State.devices.find((d) => d.serial !== State.settings.serial) || {}).serial || "";
    if (sel.value) loadPackages(2);
  };

  toggle.addEventListener("change", () => {
    saveSettings({second_device: toggle.checked});
    apply();
  });
  $("#device-select-2").addEventListener("change", async () => {
    const serial = $("#device-select-2").value;
    await saveSettings({serial_2: serial});
    if (serial) loadPackages(2);
  });
  $("#app-filter-2").addEventListener("input", debounce(() => renderAppOptions(2), 200));
  $("#app-input-2").addEventListener("change", () => {
    const pkg = $("#app-input-2").value.trim();
    if (pkg) saveSettings({app_id_2: pkg});
  });
  $("#app-resolve-2").addEventListener("click", () => resolveActivity(2));
  $("#activity-input-2").addEventListener("change", () =>
    saveSettings({activity_2: $("#activity-input-2").value.trim()}));
  $("#app-input-2").addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      highlightSuggestion(2);
    } else if (event.key === "Enter") {
      event.preventDefault();
      if (Suggest[2].items.length) pickApp(2, Suggest[2].items[Suggest[2].active < 0 ? 0 : Suggest[2].active]);
    } else if (event.key === "Escape") {
      closeAppSuggestions(2);
    }
  });

  apply();
}
```

Read the existing `app-input` keydown handler (around lines 197-232) before writing this and mirror its exact behavior, including how it handles Enter with no active suggestion. Do not invent a different interaction.

- [ ] **Step 4: Make `loadDevices` fill the second select, and the chip show both**

`loadDevices` (lines 243-273) fills `#device-select` only. At its end, before the trailing `updateDeviceChip()`, add:

```js
  if (State.settings.second_device) {
    const sel2 = $("#device-select-2");
    if (sel2 && sel2.options.length) {
      const saved2 = State.settings.serial_2;
      if (saved2 && State.devices.some((d) => d.serial === saved2)) {
        sel2.value = saved2;
      }
    } else {
      bindCompanionDevice();
    }
  }
```

Then replace `updateDeviceChip` (lines 275-285) with a version that names both serials when a second device is active:

```js
function updateDeviceChip() {
  const chip = $("#device-chip");
  const primary = State.settings.serial || "no device";
  const second = State.settings.serial_2;
  chip.textContent = (State.settings.second_device && second)
    ? primary + " + " + second
    : primary;
  chip.classList.toggle("stale", !State.devices.some((d) => d.serial === State.settings.serial));
}
```

Read the current body first and keep its `stale` handling identical.

- [ ] **Step 5: Add the settings to `effectiveSettings`**

In `effectiveSettings` (lines 1385-1404), add:

```js
    second_device: $("#second-device-toggle")
      ? $("#second-device-toggle").checked : !!State.settings.second_device,
    serial_2: $("#device-select-2") ? $("#device-select-2").value : "",
    app_id_2: $("#app-input-2") ? $("#app-input-2").value.trim() : "",
    activity_2: $("#activity-input-2") ? $("#activity-input-2").value.trim() : "",
```

`compose_height` is not in this function: the Output tab owns `segment_seconds`, so add its input there instead. Add to `web/index.html`'s Output card, next to the segment-seconds input:

```html
      <input id="compose-height" type="number" min="240" step="20" value="1080">
```
with a label reading "composite height (two devices)", and add to `effectiveSettings`:
```js
    compose_height: Number($("#compose-height").value) || 1080,
```

- [ ] **Step 6: Add the spec-run settings too**

`runSpec` (lines 1791-1814) builds its own settings object. Add the same five keys so a spec run can use a second device:

```js
      second_device: $("#second-device-toggle")
        ? $("#second-device-toggle").checked : !!State.settings.second_device,
      serial_2: $("#device-select-2") ? $("#device-select-2").value : "",
      app_id_2: $("#app-input-2") ? $("#app-input-2").value.trim() : "",
      activity_2: $("#activity-input-2") ? $("#activity-input-2").value.trim() : "",
```

- [ ] **Step 7: Verify the settings round trip**

Run: `./run.sh` in a terminal, open the printed URL, tick "record a second device", pick a device, then reload the page.
Expected: the checkbox is still ticked, the second device select still shows that serial, and the second block is still visible. This exercises the `PUT /api/settings` path and confirms the Task 8 keys survive.

Then untick it, reload, and confirm it is unticked and the block is hidden.

- [ ] **Step 8: Check the step editor offers the device dropdown**

Run: `./run.sh`, open the Steps tab, open any existing step for editing.
Expected: the form has a "device" dropdown with "1" and "2", and the help text below it explains that omitting it means device 1. This comes from the Task 3 field spec with no frontend work, so this step is a confirmation that it renders.

- [ ] **Step 9: Commit**

```bash
git add web/index.html web/app.js web/style.css
git commit -m "Add an opt-in second device to the App tab

A checkbox reveals a second device/app block. Off, the tab is byte-for-byte
what it was, and a run is unchanged.

The App tab's two slots are now described by one SLOTS map, and every function
that used to hardcode #app-input and the single package list takes a slot
number instead. State.packages becomes State.packagesBySerial, keyed by
serial, so switching either device no longer discards the other slot's list.
That was the one place the old flat list would have thrashed on every
device change.

The second select defaults to the first device that is not the main one, and
never to the main serial, since the driver rejects a second device identical
to the first and the failure would otherwise only surface at run time."
```

---

### Task 10: Documentation and a worked example

**Files:**
- Modify: `README.md` (tab table, layout block, a short multi-device section)
- Modify: `INSTRUCTIONS.md` (the `device` step field, the second-device flags, the `last_command` footgun)
- Modify: `example-steps.json` (a companion step, and a matching `device` field on the steps around it)

**Interfaces:**
- Consumes: everything above.
- Produces: no new code. The example file is the thing a reader copies from, so it has to actually exercise the feature.

- [ ] **Step 1: Add a companion step to the example tour**

In `example-steps.json`, find the first `launch` step and add a second device to the tour. Append a `device: 2` step right after the first `tap_contains` step, and give the launch step itself a matching device-2 launch so the example is runnable as written:

```json
    {
      "action": "launch",
      "device": 2,
      "narration": "The second phone comes up on the same screen."
    },
```

and after the first navigation step:

```json
    {
      "action": "tap_contains",
      "text": "Settings",
      "device": 2,
      "narration": "On the second phone, the same tap lands in its own copy of the app."
    },
    {
      "action": "back",
      "device": 2
    },
```

- [ ] **Step 2: Validate the example still parses**

Run: `.venv/bin/python -c "from demo_maker import steps; print(steps.validate_steps(steps.load_steps_file('example-steps.json')))"`
Expected: `[]`.

- [ ] **Step 3: Document the step field in INSTRUCTIONS.md**

Find the steps-file format section and add:

```markdown
### Choosing the device

Every step takes an optional `device` field, `1` or `2`. It names which phone
or emulator the step runs on. Omitting it means device 1, and it never
inherits from an earlier step, so a step reads the same wherever it sits in
the file.

```json
{ "action": "tap_text", "text": "Chats" },
{ "action": "tap_text", "text": "Chats", "device": 2,
  "narration": "The second phone opens the same conversation." }
```

On a `device: 2` step, `launch`, `reopen` and `pm_clear` act on the second
device's app, and every tap, swipe, type and assertion reads and writes that
device's screen. Narration is unchanged: one voiceover over the composite.

One sharp edge: each device keeps its own last `exec` result, so an `if` step
that reads `last_command` must carry the same `device` as the `exec` step it
follows. An `if` without `device` reads device 1's slot and will see a stale
or empty value.

```json
{ "action": "exec", "command": "getprop ro.serialno", "device": 2 },
{ "action": "if", "device": 2, "condition": "$LAST_EXEC_OUTPUT contains 5554",
  "then": [ ... ] }
```
```

- [ ] **Step 4: Document the second-device flags**

Add a section to INSTRUCTIONS.md:

```markdown
### Recording two devices

Both drivers take a second device. `android-demo.sh` records both through the
same beat timeline and composites them side by side into one MP4;
`android-spec-test.sh` drives both without recording anything.

| Flag | Meaning |
| --- | --- |
| `--serial-2 <serial>` | the second device. Without it, a single other attached device is adopted |
| `--app-id-2 <package>` | its app. Defaults to `--app-id`, so the same app on two phones needs only `--serial-2` |
| `--activity-2 <activity>` | its launch activity. Defaults to `--activity` |
| `--compose-height <n>` | demo only. Pane height for the composite, default 1080 |

Emulators count as candidates for the second device even though the primary
auto-detect skips them, since recording alongside an emulator is a common case.

Two portrait phones side by side give a near-square frame (972x1080 for two
1080x2400 screens at the default height). Lower `--compose-height` for a
shorter output, or raise it for more detail.
```

- [ ] **Step 5: Update the README**

Add a row to the tab table for the App tab's new capability:

```markdown
| App | pick a connected device, optionally add a second phone or emulator to record side by side, list installed packages (user or all), auto-resolve the launch activity |
```

and after the "The tabs" section:

```markdown
## Two devices at once

For apps that need a companion handset (a chat delivered to another phone, a
confirmation on a second device, an authenticator app), tick **record a second
device** in the App tab and pick a second phone or emulator. Both are recorded
through the same timeline, composited side by side into one MP4, and each step
chooses its device with a `"device": 2` field. See
[INSTRUCTIONS.md](INSTRUCTIONS.md#recording-two-devices).
```

- [ ] **Step 6: Commit**

```bash
git add README.md INSTRUCTIONS.md example-steps.json
git commit -m "Document the second device and add a worked example

The example tour now launches and navigates on a second device, so it is
runnable as written rather than needing the reader to invent a companion
step. INSTRUCTIONS.md documents the device field, the second-device flags,
and the one sharp edge: each device keeps its own last exec result, so an if
step reading last_command has to name the same device as the exec it follows."
```

---

## Self-Review

### 1. Spec coverage

| Spec section | Task |
| --- | --- |
| Part 1, de-duplicate the drivers | Task 1 |
| Part 2, the cursor (`SERIALS`, `ADB`, `ADB_FOR`, `use_device`) | Task 2 |
| Part 2, per-device state arrays | Task 2 |
| Part 2, library changes (dump_ui, do_exec_step, autorotate) | Task 2 |
| Part 2, per-device hygiene (zen_mode) | Not covered. See the note below. |
| Part 2, CLI surface and relaxed auto-detect | Task 4 |
| Part 3, steps schema and validation | Task 3 |
| Part 3, the documented `last_command` footgun | Task 3 (field help), Task 10 (docs) |
| Part 4, segment files and the three-phase recorder pump | Task 5 |
| Part 4, the filter graph as a pure function | Task 6 |
| Part 4, output geometry and `--compose-height` | Tasks 4 and 6 |
| Part 4, single device untouched | Task 6 (filter equality test) |
| Part 5, settings schema | Task 8 |
| Part 5, backend argv builders | Task 8 |
| Part 5, frontend | Task 9 |
| Part 6, bash tests | Tasks 2, 4, 5, 6, 7 |
| Part 6, python tests | Tasks 3, 8 |
| Documentation | Task 10 |

**Gap found and closed in this plan:** per-device `zen_mode` (DND) is in the spec but no task covers it. It is folded into Task 5, because the segment pump is where per-device recording is introduced and the DND snapshot is the other per-device host setting. Add to Task 5, right after the `stop_segment` replacement:

```bash
# Muted per device for the recording itself, not dry-run (no sound or video is
# captured there, and a banner is harmless to a fixed-pause dry run). zen_mode 2
# is total silence; each device is restored to whatever it had before, not
# hardcoded back to 0, so a user who already had their own DND setting on a
# given phone does not lose it.
ORIGINAL_ZEN_MODE_1=""
ORIGINAL_ZEN_MODE_2=""
if [ "$DRY_RUN" -eq 0 ]; then
  for d in $(seq 1 "$DEVICE_COUNT"); do
    v="$(adb -s "${SERIALS[$((d - 1))]}" shell settings get global zen_mode 2>/dev/null | tr -d '\r')"
    case "$d" in
      1) ORIGINAL_ZEN_MODE_1="$v" ;;
      2) ORIGINAL_ZEN_MODE_2="$v" ;;
    esac
    adb -s "${SERIALS[$((d - 1))]}" shell cmd notification set_dnd on >/dev/null 2>&1 || true
  done
fi
```

and in `cleanup` (currently lines 373-383), replace the single-device restore with a loop:

```bash
  local d saved
  for d in $(seq 1 "${DEVICE_COUNT:-1}"); do
    case "$d" in
      1) saved="$ORIGINAL_ZEN_MODE_1" ;;
      *) saved="$ORIGINAL_ZEN_MODE_2" ;;
    esac
    [ -n "$saved" ] || continue
    adb -s "${SERIALS[$((d - 1))]}" shell settings put global zen_mode "$saved" >/dev/null 2>&1 || true
  done
```

Add a bash assertion alongside the others:
```bash
expect_grep "DND is snapshotted per device" "$DEMO" 'ORIGINAL_ZEN_MODE_2'
expect_grep "DND is restored per device" "$DEMO" 'ORIGINAL_ZEN_MODE_2="$saved"'
```

This raises Task 5's expected bash count from 65 to 67.

### 2. Placeholder scan

No TBD, no "implement later", no "add appropriate error handling", no "similar to Task N". Every code step contains the actual code. The two spots that defer to reading existing code rather than restating it are deliberate and each says so: Task 8 Step 1 tells the implementer to read the spec test class's `setUp` for its fixture names, and Task 9 Step 3 tells them to mirror the existing `app-input` keydown handler instead of inventing a different interaction.

### 3. Type consistency

Checked across tasks, since a mismatch here is a silent bug:

| Name | Defined in | Used in | Consistent |
| --- | --- | --- | --- |
| `SERIALS`, `DEVICE_COUNT`, `CUR_DEV` | Task 2 | Tasks 4, 5, 6, 7 | yes |
| `use_device` | Task 2 | Tasks 4, 5, 7 | yes |
| `ADB`, `ADB_FOR` | Task 2 | Tasks 2 (tests), 4, 5 | yes |
| `SCREEN_W_BY_DEV`, `SCREEN_H_BY_DEV` | Task 2 | Tasks 4, 6 | yes |
| `AUTOROTATE_AT_START` as an array | Task 2 | Task 2 (tests) | yes |
| `LAST_EXEC_STATUS`, `LAST_EXEC_OUTPUT` arrays plus bare mirrors | Task 2 | Task 2 (tests) | yes |
| `APP_BY_DEV`, `ACTIVITY_BY_DEV` | Task 2 | Task 4 | yes |
| `step_device` | Task 5 (demo), Task 7 (spec copy) | Task 5 (tests) | yes, and the duplication is stated as deliberate |
| `segment_path <device> [index]` | Task 5 | Task 5, Task 6 | yes |
| `pane_width_for`, `build_compose_geometry`, `build_concat_filter` | Task 6 | Task 6 (tests and wiring) | yes |
| `COMPOSE_W`, `COMPOSE_H` | Task 6 | Task 6 | yes |
| `COMPOSE_HEIGHT` | Task 4 | Task 6, Task 9 | yes |
| `second_device`, `serial_2`, `app_id_2`, `activity_2`, `compose_height` | Task 8 | Task 9 | yes |
| `State.packagesBySerial`, `SLOTS` | Task 9 | Task 9 | yes |

One thing to watch during execution: Task 2 changes `AUTOROTATE_AT_START` from a scalar to an array, and `android-spec-test.sh`'s `EXIT` trap calls `autorotate_restore` (currently line 204). That still works, because the new `autorotate_restore` loops over `DEVICE_COUNT` and reads the array. But the trap's `command -v autorotate_restore` guard must stay, because the trap can fire before the library is sourced, when `DEVICE_COUNT` and the array do not exist yet. The `: "${DEVICE_COUNT:=1}"` and `AUTOROTATE_AT_START=("" "")` lines are both at library source time, which is after the trap is installed but before any restore can usefully run. If Task 2's suites come back with an unbound-variable error from the trap, that is the cause.

Suite growth, to catch drift as the tasks land. These are approximate and are a sanity check, not a gate: an exact count would be brittle, since a test that gets written slightly differently can add or lose an assertion. What must hold at every task boundary is `0 failed` in both suites.

| After task | Bash (approx) | Python (approx) | New coverage |
| --- | --- | --- | --- |
| baseline | 32 | 60 | device hygiene, type settle, poll knobs, --loose, cfr pass |
| 1 | 32 | 60 | unchanged, which is the point of task 1 |
| 2 | 47 | 60 | device cursor, per-device autorotate, per-device exec slots, USB guard per device |
| 3 | 47 | 64 | the `device` field in both registries |
| 4 | 55 | 64 | second-device flag parsing and wiring |
| 5 | 64 | 64 | per-step dispatch, per-device DND snapshot and restore |
| 6 | 81 | 64 | geometry arithmetic, the single-device filter equality, the two-device graph |
| 7 | 83 | 64 | spec-side dispatch |
| 8 | 83 | 70 | argv builders, settings keys |
| 9 | 83 | 70 | unchanged; task 9 is frontend and manual |
| 10 | 83 | 70 | unchanged; task 10 is docs and the example file |

If a task's actual count differs from the table by a couple, that is not a problem. If the count goes *down* from the previous row, or if either suite reports a failure, stop and find out why before moving on.
