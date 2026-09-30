# Multi-device recording design

Date: 2026-09-30

## Problem

Demo Maker drives exactly one Android device. `ADB()` in each driver is a
one-serial funnel, `android-demo.sh` runs one `screenrecord` stream per
segment, and the concat filter is a single temporal join, so the output MP4 is
always one screen.

Some apps need a second device. A chat app that sends a message to a phone on
the other side of the table, a companion app that confirms on a second handset,
an authenticator app on a second phone. The tour has to show both screens at
once, otherwise the viewer cannot follow what the narration is describing.

Goal: add an optional second phone or emulator. Both are recorded through the
same beat timeline and composited side by side into one MP4. Steps say which
device they run on. A single-device run behaves exactly as it does today.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Step to device binding | Optional `"device": 1\|2` field per step | No action-namespace pollution, works inside `if.then/else`, backwards compatible |
| Companion app config | Its own `--app-id-2` / `--activity-2` | The two devices often host different apps; defaulting to the same app when unset covers the rest |
| Layout | `hstack`, side by side, configurable height | What was asked for |
| Driver coverage | Demo and spec test both | Spec scenarios need cross-device assertions too |
| Code duplication | De-duplicate the drivers first | One device-aware implementation instead of two copies |
| Device stickiness | Explicit; absent means device 1 | No hidden state; a step means the same thing wherever it sits in the file |
| App tab UI | Opt-in checkbox reveals a second slot | The common single-device case stays uncluttered |

## Out of scope

- More than two devices. The internals are array-shaped so N is a later
  increment, but the CLI, config, and UI expose exactly two.
- Cross-device assertions where one device's action depends on coordinates
  read from the other's UI. Actions run on one device at a time; a shared
  `dump.xml` would be a problem here, which is why the dump path is
  per-device anyway.
- Concurrent runners. `Runner.start()` still raises on a second run.
- Voiceover per device. One narration track over the composite, unchanged.

## Part 1: de-duplicate the drivers

`android-demo.sh` currently carries its own inlined copy of 26 functions that
also exist in `android-ui-lib.sh`. `android-spec-test.sh` sources the library;
the demo script does not, despite what `INSTRUCTIONS.md` claims.

Measured facts:

- 26 functions appear in both `android-demo.sh` and `android-ui-lib.sh`.
- All 26 bodies are byte-identical. Zero drift.
- The only top-level names defined in both are `AUTOROTATE_AT_START`,
  `LAST_EXEC_STATUS`, and `LAST_EXEC_OUTPUT`, each initialized to `""`.
- The library's documented contract is four caller globals: `ADB()`,
  `WORKDIR`, `SCREEN_W`, `SCREEN_H`. The demo script defines all four.
- The demo script's 15 unique functions are all genuinely demo-specific:
  `assert_text_present`, `begin_beat`, `cleanup`, `dry_run_steps`, `end_beat`,
  `load_env_file`, `narr_id_to_file`, `perform_action`, `run_leaf_step`,
  `run_steps`, `start_segment`, `stop_segment`, `synthesize_line`, `usage`,
  `walk_and_synthesize`. None of them exists in the library.

Change: `android-demo.sh` sources `android-ui-lib.sh` at the point where the
duplicated block starts, and the duplicated block is deleted. The source point
must precede the first call to any library function, which currently happens at
the `autorotate_snapshot` call.

The 7 library functions the demo never used (`assert_signed_in`,
`find_and_tap_desc_contains`, `wait_gone`, `_bounds_for_desc_contains`,
`_checked_for_desc`, `_checked_for_text`) become available to the demo. That is
additive, not a behavior change, because nothing calls them.

Risk: low. It is a deletion of identical text plus one `source` line. Both
existing test suites continue to run unchanged, and `tests/run_bash_tests.sh`
already `bash -n` parses all three scripts and exercises library functions
through a stubbed `adb`.

This lands as its own commit before any multi-device work, so the multi-device
diff stays reviewable on its own.

## Part 2: device model in the shell

### The cursor

Both drivers hold an indexed array of serials. Indexed arrays work in bash 3.2,
which is what macOS ships, unlike associative arrays.

```bash
SERIALS=("" "")        # SERIALS[0] is device 1, SERIALS[1] is device 2
CUR_DEV=1              # the device the next action runs against
DEVICE_COUNT=1         # 1 or 2
```

```bash
ADB()     { adb -s "${SERIALS[$((CUR_DEV - 1))]}" "$@"; }
ADB_FOR() { local d="$1"; shift; adb -s "${SERIALS[$((d - 1))]}" "$@"; }
```

`ADB()` keeps its exact current meaning from the caller's point of view, so
every one of the library's functions keeps its signature and its body. This is
the single decision that keeps the change small.

### Per-device state

State the library reads as a bare global is loaded by `use_device` when the
cursor moves, and written back when the device's action completes.

```bash
use_device() {
  CUR_DEV="$1"
  SCREEN_W="${SCREEN_W_$1}"
  SCREEN_H="${SCREEN_H_$1}"
  LAST_EXEC_STATUS="${LAST_EXEC_STATUS_$1}"
  LAST_EXEC_OUTPUT="${LAST_EXEC_OUTPUT_$1}"
}
```

Names `SCREEN_W_1`, `SCREEN_W_2`, `LAST_EXEC_STATUS_1`, and so on are plain
variables, so `${SCREEN_W_$1}` needs no `eval`.

`TEXT_VALUE` and `TEXT_BOUNDS` are pure scratch within a single lookup and are
deliberately left shared. They never carry state across steps.

### Library changes

Exactly three, all in `android-ui-lib.sh`:

1. `dump_ui` pulls to `$WORKDIR/dump_$CUR_DEV.xml` instead of `$WORKDIR/dump.xml`.
   Sequential actions would be fine either way, but per-device files make a
   future cross-device step possible without a rewrite, and cost one directory
   entry.
2. `do_exec_step` writes `LAST_EXEC_STATUS` and `LAST_EXEC_OUTPUT` back to the
   `LAST_EXEC_STATUS_$CUR_DEV` / `LAST_EXEC_OUTPUT_$CUR_DEV` slots before
   returning.
3. `autorotate_snapshot` and `autorotate_restore` loop over devices using
   `ADB_FOR` rather than the cursor, storing into `AUTOROTATE_AT_START_$d`.
   They are called from `cleanup` and from an `EXIT` trap, where the cursor's
   value is arbitrary, so they must not depend on it.

### Per-device hygiene

DND (`zen_mode`) is snapshotted and set per device, since a second device is
also recording and also must stay silent. Each device keeps its own
`ORIGINAL_ZEN_MODE_$d` and its own restore in `cleanup`.

### CLI surface

New flags, identical on both drivers:

- `--serial-2 <serial>`
- `--app-id-2 <package>`
- `--activity-2 <activity>`

`--app-id-2` defaults to `--app-id` when omitted, so the common case of the
same app on two devices needs only `--serial-2`.

Auto-detect relaxes. Today `android-demo.sh:271-275` and
`android-spec-test.sh:176-180` treat more than one attached device as fatal.
New behavior:

- No `--serial`: keep today's behavior exactly, including the fatal error when
  more than one device is attached.
- `--serial` given, `--serial-2` omitted, exactly two devices attached: use the
  one that is not `--serial`.
- `--serial-2` given but equal to `--serial`: fatal, with a clear message.

## Part 3: steps schema

Optional `"device"` on any leaf step, integer `1` or `2`. Absent means `1`,
with no inheritance from earlier steps.

```json
{
  "steps": [
    { "action": "launch" },
    { "action": "tap_text", "text": "Chats", "narration": "Open the chat." },
    { "action": "tap_text", "text": "Dana", "device": 2,
      "narration": "On the second phone, open the same conversation." },
    { "action": "tap_text", "text": "Hi, demo day", "device": 2,
      "type": "Hi, demo day" },
    { "action": "back", "device": 2 },
    { "action": "tap_text", "text": "Looks good", "narration": "Back on the first phone." }
  ]
}
```

Behavior by action on a `device: 2` step:

- `launch`, `reopen`, `pm_clear` resolve against `APP_ID_2` / `ACTIVITY_2`.
- Every tap, swipe, type, and key event is sent to device 2.
- `assert_text` and the `if` condition evaluator dump and read device 2's UI.
- `exec` runs on device 2, with `DEMO_SERIAL` exported as device 2's serial.
  `DEMO_APP_ID` and `DEMO_ACTIVITY` are device 2's.
- Narration is unchanged. One voiceover over the composite.

### Documented footgun

Each device has its own `LAST_EXEC_*` slot. An `if` step that reads
`last_command` must carry the same `device` as the `exec` step it follows:

```json
{ "action": "exec", "command": "getprop ro.serialno", "device": 2 },
{ "action": "if", "condition": "$LAST_EXEC_OUTPUT contains 2", "device": 2,
  "then": [ ... ] }
```

An `if` without `device` reads device 1's slot and sees a stale or empty
value. This is a consequence of the explicit-over-sticky choice and is called
out here, in `INSTRUCTIONS.md`, and in the tree editor's field help.

### Validation

`demo_maker/steps.py` and `demo_maker/spec.py` accept `device` as an optional
integer and reject anything other than 1 or 2. Rejecting a `device: 2` step
when no second device is configured happens in the same validation pass, so
the tree editor flags it before the run instead of the shell failing midway.

## Part 4: recording and compositing

### Segment files

| | device 1 | device 2 |
| --- | --- | --- |
| on device | `/sdcard/_android_demo_seg_${s}_1.mp4` | `/sdcard/_android_demo_seg_${s}_2.mp4` |
| local | `$WORKDIR/video/seg_${s}_1.mp4` | `$WORKDIR/video/seg_${s}_2.mp4` |

`REC_PID` becomes `REC_PID_$d`.

### Keeping the panes aligned

Three rules, in order of importance:

1. **Signal both devices before waiting for either.** `stop_segment` sends
   `pkill -INT screenrecord` to every device first, then waits, then pulls.
   Signalling and waiting device 1 before even signalling device 2 would give
   device 2 several extra seconds of capture per cut, and the composite would
   freeze device 1's last frame for the remainder of the segment.
2. **Start all recorders, then sleep once.** `start_segment` launches every
   `screenrecord` in the background and only then does the existing 1s sleep.
   Sequential per-device sleeps would offset the panes by a second at the head
   of every segment.
3. **Rebase each stream.** `setpts=PTS-STARTPTS` per device per segment
   removes whatever start offset remains.

`SEG_ELAPSED` accounting is unchanged, and the cut condition stays a pure
function of the single global elapsed clock, so both devices always cut on the
same boundary.

### Filter graph as a pure function

`build_concat_filter <device_count> <segment_count>` emits the
`-filter_complex` string. It reads no global state, so
`tests/run_bash_tests.sh` can assert on the exact string without ffmpeg or
devices.

For two devices and `S` segments, with input index for `(segment s, device d)`
equal to `s * 2 + (d - 1)`:

```
[0:v]scale=486:1080:force_original_aspect_ratio=decrease,pad=486:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[a0]
[1:v]scale=486:1080:force_original_aspect_ratio=decrease,pad=486:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS,fps=30[b0]
[a0][b0]hstack=inputs=2[hs0]
[2:v]...[a1]
[3:v]...[b1]
[a1][b1]hstack=inputs=2[hs1]
[hs0][hs1]concat=n=2:v=1:a=0[outvraw]
[outvraw]fps=30,format=yuv420p[outv]
```

Per element:

- `scale` / `pad` to that device's own pane width at the common height. The
  `force_original_aspect_ratio=decrease` plus centered `pad` is belt and
  braces against a device whose aspect changes mid-run; the primary arithmetic
  is `w = round_up_even(screen_w * height / screen_h)`.
- `setsar=1` so the panes do not inherit a non-square pixel aspect.
- `setpts=PTS-STARTPTS` to rebase.
- `fps=30` to match the existing constant-rate output.
- `hstack=inputs=2` produces the composite pane for that segment.

No padding filter is needed. `hstack` is framesync-based with
`repeatlast=1` by default, so when one device's stream runs out its last frame
is held while the other finishes, and the composite runs to the longer of the
two. Verified on this machine: hstacking a 5s stream with a 3s stream yields a
5.000s output whose shorter pane still shows the 3s stream's final color at
t=4s. That is also the right behavior, since a device that has nothing to show
should visibly idle rather than vanish from the frame.

### Output geometry

`--compose-height` (default 1080, even-rounded for h264). Each device's pane
width is `round_up_even(screen_w * height / screen_h)`, minimum 2. Output width
is the sum. Two 1080x2400 phones at height 1080 give two 486-wide panes and a
972x1080 output, which is a near-square frame. That is the honest consequence
of putting two portrait screens side by side, and `--compose-height` is the
knob for it.

### Single device is untouched

`DEVICE_COUNT = 1` takes the existing code path with no scale, no `hstack`, no
`setpts`, and no new ffmpeg flags. The filter string is byte-for-byte what it is
today. Existing single-device output is unaffected, and the multi-device code
cannot regress the common case.

`hstack` requires equal input heights, which the common `--compose-height`
provides.

## Part 5: config, backend, UI

### Settings

`demo_maker/config.py` `DEFAULTS` gains:

| Key | Type | Default |
| --- | --- | --- |
| `second_device` | bool | `False` |
| `serial_2` | str | `""` |
| `app_id_2` | str | `""` |
| `activity_2` | str | `""` |
| `compose_height` | int | `1080` |

`second_device` joins `_BOOL_KEYS`, `compose_height` joins `_INT_KEYS`.

These keys are a hard gate. `load_settings` copies only keys present in
`DEFAULTS`, and both `update_settings` and `server._merged_settings` drop
anything else, so the keys must land before the frontend can send them.

### Backend

No new endpoints. `/api/apps?serial=` and `POST /api/activity {serial}` already
take an arbitrary serial, so the companion's package list and activity resolve
with no backend change at all.

`runner.build_argv` and `spec.build_spec_argv` append, when `second_device` is
set:

```
--serial-2 S --app-id-2 P [--activity-2 A] [--compose-height N]
```

with `P` defaulting to `app_id` and `A` defaulting to `activity`. Validation
errors: `second_device` set but no `serial_2` and not exactly two devices
attached; `serial_2 == serial`; no resolvable `app_id_2`. The existing
single-device errors are unchanged.

### Frontend

The App tab's Device card gains a `Record a second device` checkbox, persisted
through the existing `saveSettings` path. Checked reveals a second device select
(`#device-select-2`), app id (`#app-input-2`), and activity (`#activity-input-2`),
each with its own Resolve button and hint. Unchecked, the second block is hidden
and the tab is exactly as it is today.

`State.packages` becomes `State.packagesBySerial`, keyed by serial, so switching
either device does not discard the other's list. `effectiveSettings()` returns
the five new keys. The Run button's client-side validation and the command
preview pick them up through the existing settings round trip.

`web/app.js` grows a second `bindCompanionDevice()` alongside `bindAppTab()`,
and the device chip shows both serials when a second device is active.

The steps tree editor's schema-driven form gains a device select, driven by the
same `device` field the validators accept, so `"device": 2` is settable and
validated from the UI.

## Part 6: testing

### Bash: `tests/run_bash_tests.sh`

Existing 32 assertions stay. New:

- `use_device` swaps `SCREEN_W`, `SCREEN_H`, and `LAST_EXEC_*` between slots.
- `ADB` and `ADB_FOR` resolve the right serial per device, asserted by the
  stub recording which serial each call was made with.
- Autorotate snapshot and restore cover both devices independently, and
  restoring device 1 does not touch device 2.
- `do_exec_step` on device 2 writes device 2's slot, not device 1's.
- The radio guard refuses a device 2 exec step when device 2 is off USB.
- `build_concat_filter 1 3` equals today's filter string for 3 segments.
- `build_compose_geometry` returns 972x1080 for two 1080x2400 devices at height
  1080, and even values for odd screen widths.
- `build_concat_filter 2 2` emits two `hstack` filters, four inputs in
  `(segment, device)` order, the padding and rebasing elements, and the
  trailing `fps=30,format=yuv420p`.

### Python: `tests/`

- `build_argv` with `second_device` on emits `--serial-2`, `--app-id-2`, and
  `--compose-height`; with it off, emits none of them and is byte-identical to
  today's output.
- `app_id_2` and `activity_2` default to `app_id` and `activity` when empty.
- Missing `serial_2`, or `serial_2 == serial`, produces a validation error.
- `build_spec_argv` gains the same behavior.
- The five new settings keys survive a save and load round trip, with correct
  bool and int coercion.
- The step validators accept `device: 1` and `device: 2`, and reject `0`, `3`,
  and a string.
- `effectiveSettings` in the browser returns the new keys; covered by the
  existing frontend-facing settings tests where they exist, otherwise by a
  backend `PUT /api/settings` round trip.

## Documentation

`README.md` gains a multi-device row in the tab table and a short section.
`INSTRUCTIONS.md` documents the `device` step field, the second-device CLI
flags, and the `LAST_EXEC_*` footgun.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| De-dup breaks the demo script | Identical text plus a contract the demo already satisfies; both suites run before and after; the de-dup is its own commit |
| Pane drift across a long run | Signal all devices before waiting any; single `setpts` rebase; `hstack` holds the last frame of a shorter pane, so a fast pull cannot truncate |
| The narration track no longer matches the video | The timeline math is device-independent and unchanged; the composite is the concatenation of the same segments in the same order |
| `--compose-height` produces an unusable frame | Exposed as a flag with a sane default; two portrait phones genuinely give a near-square frame and that is visible in the command preview |
| `LAST_EXEC_*` confusion | Per-device slots by design; the rule is documented in three places and in the field help |
| Pull cost per cut roughly doubles | Accepted. Cuts happen at most every `segment_seconds` (default 150s), and the per-segment file names already disambiguate |
