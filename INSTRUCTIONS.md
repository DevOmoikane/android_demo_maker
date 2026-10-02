# Instructions

This project gives you two ways to drive an Android app on a real device,
both usable from the same local web studio and both runnable straight from
the command line.

| Feature | Script | What it does |
| --- | --- | --- |
| Video demo creation | `android-demo.sh` | walks your app through a scripted tour while recording the screen and narrating each step, producing a finished MP4 |
| Spec testing | `android-spec-test.sh` | runs unattended assertion scenarios against your app and reports pass/fail plus spec coverage |

Both scripts share the same driving code (`android-ui-lib.sh`: fresh
uiautomator dumps, polling taps, scroll-to-find), so anything you can express
for one feature works for the other. The web studio (`./run.sh`) is the
friendly front end for writing step files, picking devices and apps, and
watching runs live.

## Contents

1. [Setup](#setup)
2. [The studio at a glance](#the-studio-at-a-glance)
3. [Feature 1: create a narrated video demo](#feature-1-create-a-narrated-video-demo)
4. [Writing a demo steps file](#writing-a-demo-steps-file)
5. [Feature 2: run spec tests](#feature-2-run-spec-tests)
6. [Writing a scenario file](#writing-a-scenario-file)
7. [Action reference](#action-reference)
8. [Command-line usage](#command-line-usage)
9. [Tips and troubleshooting](#tips-and-troubleshooting)

## Setup

```bash
./setup.sh     # one-time: build .venv, check/install tools, offer a Piper voice
./run.sh       # start the studio and open the browser
```

Requirements: Python 3.8+ (stdlib only, no pip packages), adb, jq, and
ffmpeg + ffprobe for recording only. Spec testing needs just adb and jq.
`./setup.sh --check` re-runs the doctor without installing anything.

## The studio at a glance

| Tab | Purpose |
| --- | --- |
| App | pick a connected device, optionally add a second device to record side by side, browse installed packages, auto-resolve the launch activity |
| Narration | TTS engine (macOS say / Piper / none), voice picker, rate, audio preview |
| Steps | tree editor for demo steps JSON and spec scenarios, with validation, recents, and run/dry-run buttons |
| Spec Tests | pick a scenarios directory and app id, browse/edit every scenario, run one/file/all, watch the live log and the coverage report |
| Output & Advanced | output folder/name, segment seconds, composite height (two devices), keep-workdir, silent override, script paths |
| Run | copyable command preview, live log, cancel, final MP4 path |

Settings persist between sessions. The server binds to 127.0.0.1 under a
random per-launch token, so nothing is reachable from the network.

## Feature 1: create a narrated video demo

A demo is one continuous pass through a steps file while the screen is
recorded and each step's `narration` text is spoken over it.

1. **App tab**: connect your phone (accept the USB debugging prompt), select
   the device, then either type the package id or filter the package list and
   click **Resolve activity** so the launcher activity is filled in.
2. **Narration tab**: choose an engine; Piper is the default (offline neural
   voices). The Piper card lists every voice the studio found locally and,
   under *Downloadable voices*, the full HuggingFace catalog: filter or
   scroll, click **Download**, and the model lands in `piper-voices/` and
   appears in the picker when it finishes (progress shown inline; the list
   is cached for a day, **Refresh** re-fetches it). On macOS `say` offers
   system voices with a rate slider and instant previews. Choose *none*
   for a silent video.
3. **Steps tab**: open or compose your steps file (format below). The editor
   validates as you go; red highlights mean fix-before-run. **Validate**
   checks the whole file and reports issues both inline and as a banner;
   **Dry run** and **Run** execute the currently open steps file right from
   this tab. Narration is edited per step: click a step's pencil icon and
   type into the `narration` textarea (plus optional `settle_ms`).
4. **Output & Advanced**: set the output folder and optional file name.
   Segment seconds controls how often screenrecord chunks are rotated;
   150 is a good default.
5. **Run tab**: review the copyable command. Use **Dry run** to execute all
   steps (taps, asserts, everything except recording/narration) without
   capturing video; use **Run demo** for the real thing. Cancel sends a clean
   Ctrl+C; the script restores Do Not Disturb settings on any exit.

The finished MP4 path appears under the log when the run completes
(`==> Done: ...`).

## Writing a demo steps file

A steps file is a single JSON array of step objects. `example-steps.json` is a
working sample that demonstrates two devices: three of its steps carry
`"device": 2`, so it needs a second phone or emulator attached to run as
written. For a single-device run, drop those three steps or turn the second
device on as [Recording two devices](#recording-two-devices) describes.
Every step supports three optional fields on top of its own:

| Field | Meaning |
| --- | --- |
| `narration` | text spoken over this step; the dwell time matches speech length |
| `settle_ms` | extra wait after the action before narration starts (default 600) |
| `device` | `1` or `2`, the device this step runs on (default 1); see [Choosing the device](#choosing-the-device) |

```json
[
  { "action": "launch", "narration": "Welcome to the app" },
  { "action": "tap_text", "text": "Get started", "settle_ms": 900 },
  { "action": "swipe", "direction": "up", "narration": "Scrolling the feed" }
]
```

Core actions: `launch`, `reopen`, `pm_clear`, `tap_text` (+ optional `type`
typed after the tap), `tap_contains`, `tap_contains_optional` (never fails),
`tap_until_gone` (keeps tapping until `watch_for` disappears),
`tap_desc`, `tap_left_of_contains`, `swipe_up_from_contains`,
`swipe_until_contains`, `tap_xy` (last resort), `back`, `home_button`,
`dismiss_keyboard`, `pause`, `swipe`, `assert_text`, `exec`, and `if`.
Gestures: `long_press`, `double_tap`, `swipe_element`, and
`drag_and_drop` (see the [reference](#action-reference)); plain `swipe`
covers up/down/left/right.
See the [reference](#action-reference) for every field.

Two dynamic values work anywhere text is typed or compared:
`{{TIMESTAMP}}` (epoch seconds, evaluated per occurrence) and `{{ENV:NAME}}`
(reads environment variables; a `.env` next to the steps file or the script
is loaded first without clobbering already-exported variables).

`exec` runs a host command (`shell`: bash/sh/lambda, `on_fail`: stop/continue)
and exports `DEMO_SERIAL`, `DEMO_APP_ID`, `DEMO_ACTIVITY`,
`DEMO_SCREEN_W`, `DEMO_SCREEN_H`. `if` branches on the last exec
(`source: last_command`, checks like `output_matches`) or on live screen text
(`source: screen` with `text`, `equals`, `matches`, `timeout_seconds`),
running `then` and/or `else` sub-lists that can nest more ifs.

### Choosing the device

Every step takes an optional `device` field, `1` or `2`. It names which phone
or emulator the step runs on. Omitting it means device 1, and it never
inherits from an earlier step, so a step reads the same wherever it sits in
the file. Scenario steps take the same field, so one assertion file can drive
both phones.

```json
{ "action": "tap_text", "text": "Chats" },
{ "action": "tap_text", "text": "Chats", "device": 2,
  "narration": "The second phone opens the same conversation." }
```

On a `device: 2` step, `launch`, `reopen` and `pm_clear` act on the second
device's app, and every tap, swipe, type and assertion reads and writes that
device's screen. Narration is unchanged: one voiceover over the composite.
`exec` steps still run on this machine; the device they are aimed at is what
`DEMO_SERIAL`, `DEMO_APP_ID` and the rest report.

Two sharp edges, both from the same rule, no inheritance:

- Each device keeps its own last `exec` result, so an `if` step that reads
  `last_command` must carry the same `device` as the `exec` step it follows.
  An `if` without `device` reads device 1's slot and will see a stale or empty
  value.
- The steps inside `then` / `else` are steps like any other, so they need
  their own `device` too. They run on device 1 unless they say otherwise, even
  when the `if` around them is a `device: 2` step.

```json
{ "action": "exec", "device": 2,
  "command": "adb -s \"$DEMO_SERIAL\" shell getprop ro.serialno" },
{ "action": "if", "device": 2, "source": "last_command",
  "output_matches": "^.+$",
  "then": [ { "action": "pause", "device": 2,
              "narration": "That was the second phone." } ] }
```

A step naming device 2 in a single-device run fails before it touches adb,
with a message telling you to attach the second device (see
[Recording two devices](#recording-two-devices)). The studio knows how many
devices its current settings have, so **Validate** flags the step there and
now instead of leaving it to stop the run partway through the recording.

## Feature 2: run spec tests

Spec tests are the assertion counterpart: no recording, no narration, just
"drive the app and verify what is on screen". Scenarios live in ordinary
JSON files inside a scenarios directory (each `*.json` file groups the
scenarios translated from one spec document).

In the studio:

1. **App tab**: pick your device once; spec tests reuse it.
2. **Spec Tests tab**: set the scenarios directory (**Browse...**), enter the
   app id under test, optionally **Resolve** its activity, then hit Reload.
   Every file is listed with its runnable scenarios, step counts, validation
   problems, and not-automated placeholders.
3. Run a single scenario (**Run** on its row, which uses `--only`), one whole
   file (**Run file**), or everything (**Run all files**). The live log
   streams below; when the run finishes you get the summary chips
   (passed / failed / skipped / implemented vs available), a per-scenario
   result table with failed step ids, and the skipped-placeholder details.

Exit code: 0 means every executed scenario passed; 1 means at least one
failed. A structured report is also written to
`~/Library/Caches/demo-maker/last-spec-report.json`.

### Coverage model

Each file accounts for scenarios from its source spec:

- entries with a `name` are implemented and get executed;
- `_skipped` / `_blocked` placeholders mark scenarios deliberately not
  automated, with a `_why` reason;
- `_note` entries carry file-level caveats.

*Available* = implemented + placeholders. *Implemented* = runnable ones.
Pass/fail applies only to scenarios actually executed this run, so adding
placeholders never turns a suite red.

## Writing a scenario file

One JSON array per file. Runnable entries need `name` and `steps`;
steps use the same action language as demos (minus narration, which is
ignored here, minus `tap_contains_optional`) plus the assertion set.

You never have to hand-edit the JSON: every scenario row has an **Edit**
button that opens it in the Steps editor, each file header has
**+ Scenario** to append a new one, and **New file...** creates a file.
While editing, the Steps tab shows the scenario's name (editable inline),
Save writes the whole scenario file back after validating it, and opening
any demo steps file returns the editor to demo mode.

```json
[
  { "_note": "Scenarios translated from specs/auth.md." },

  {
    "_skipped": "AUTH-05: Token refreshes silently",
    "_why": "Not observable from the UI."
  },

  {
    "name": "AUTH-01: Parent signs in with email and password",
    "steps": [
      { "action": "pm_clear" },
      { "action": "launch", "settle_ms": 2000 },
      { "action": "tap_text", "text": "Log in", "settle_ms": 900 },
      { "action": "tap_xy", "x": 720, "y": 1053,
        "type": "{{ENV:TEST_EMAIL}}" },
      { "action": "tap_xy", "x": 720, "y": 1331,
        "type": "{{ENV:TEST_PASSWORD}}" },
      { "action": "dismiss_keyboard" },
      { "action": "tap_text", "text": "Log in", "settle_ms": 2200 },
      { "action": "assert_signed_in" },
      { "action": "assert_text", "text": "Couldn't log you in",
        "comment": "(only in the wrong-password variant)" }
    ]
  }
]
```

Authoring rules that keep suites reliable:

- **Self-contained scenarios.** There is no shared setup or teardown; each
  scenario starts from whatever its own steps produce. Begin with
  `pm_clear` + `launch` (and sign-in steps) whenever state matters.
- **Independent failures.** A failed step fails only that scenario; the run
  continues with the next one.
- **Prefer text over coordinates.** `tap_xy` breaks on layout changes; keep
  it for fields uiautomator cannot see (password inputs), exactly like the
  example above.
- **Polling is built in.** Lookups retry for about 20 seconds by default
  (`POLL_MAX_ATTEMPTS` x `POLL_INTERVAL_SECONDS`), covering slow network
  loads after screen transitions. For genuinely slow waits raise the knobs
  on the specific step (`max_attempts`, `interval_seconds` on
  `assert_text_eventually`, `assert_desc_contains`, `wait_gone`) instead of
  raising global defaults.
- **Assertions accept templates.** `assert_*` and typed text all expand
  `{{TIMESTAMP}}` and `{{ENV:NAME}}`; unset environment variables fail the
  step rather than typing the literal token.
- **Honest placeholders.** If a Then clause cannot be checked from the UI,
  record it as `_skipped` with a reason instead of faking a weaker check.

The `seed_requests` action exists for apps that ship a request-seeding tool:
it calls whatever `SEED_REQUESTS_SCRIPT` points at as
`<script> <child_id> <domain...>`. Prefer a plain `exec` step otherwise.

## Action reference

Fields marked *required* must be present. `nth` is always the 1-based match
index (default 1).

### Driving (demo + spec)

| Action | Fields |
| --- | --- |
| `launch` | force-stops then cold-starts the app |
| `reopen` | foregrounds the existing task |
| `pm_clear` | clears app data (logged-out state) |
| `tap_text` | `text` (required), `nth`, optional `type` typed after the tap |
| `tap_contains` | `text` (required substring), `nth`, `type` |
| `tap_until_gone` | `watch_for` (required), `max_attempts` 15, `interval_seconds` 3 |
| `tap_desc` | `desc` (required), `nth` |
| `tap_left_of_contains` | `text` (required), `offset_x` 59, `nth`; for unlabeled checkboxes left of a label |
| `swipe_up_from_contains` | `text` (required), `delta_y` 500, `nth`; scrolls a clipped container from a label's own position |
| `swipe_element` | `text` (required substring), `direction` up/down/left/right, `delta` 500 px, `nth`; swipes from the element's own center, so it lands inside the right pager/carousel even when the layout shifts |
| `drag_and_drop` | `from_text` (required), `from_nth`; drop target: exactly one of `to_text`, `to_desc`, or `x`+`y` (`to_nth` for text/desc targets); `duration_ms` 800 |
| `long_press` | one locator: `text` (exact) or `contains` (substring) or `desc`, or `x`+`y`; plus `nth`, `duration_ms` 1000 (keep >= ~600 to clear the long-click timeout) |
| `double_tap` | same locators as `long_press` (no duration); both taps fire inside one on-device shell so they land within the double-tap window |
| `swipe_until_contains` | `text` (required), `max_swipes` 6, `nth`; scroll-to-find-and-tap for feeds |
| `tap_xy` | `x`, `y` (required), `type` |
| `back`, `home_button`, `dismiss_keyboard` | none |
| `pause` | none (dwell comes from narration/settle_ms) |
| `swipe` | `direction`: up/down/left/right, screen-center swipe; optional `duration_ms` 400 |
| `assert_text` | `text` (required), `nth`; exact text visible right now |
| `exec` | `command` (required), `shell` bash/sh/lambda, `on_fail` stop/continue |
| `if` | `source` last_command/screen plus the branch fields described above |

### Demo-only

| Field/action | Notes |
| --- | --- |
| `narration` | spoken text; ignored by spec tests |
| `tap_contains_optional` | tap only if present, never fails; not available in scenarios |

### Spec-only assertions (all non-mutating; failure fails the scenario)

| Action | Fields |
| --- | --- |
| `assert_signed_in` | none; checks common signed-in nav destinations |
| `assert_text_eventually` | `text` (required), `nth`, `max_attempts` 25, `interval_seconds` 0.8; polls |
| `assert_contains` | `text` (required), `nth`; substring visible now |
| `assert_desc` | `desc` (required), `nth`; exact content-desc now |
| `assert_desc_contains` | `text` (required), `nth`, `max_attempts`, `interval_seconds`; polls, for variable descs |
| `assert_gone` | `text` (required); exact text must be absent now |
| `assert_contains_gone` | `text` (required), `nth`; substring must be absent |
| `assert_checked` / `assert_unchecked` | `text` or `desc` (one required), `nth`; reads the toggle's own checked state |
| `wait_gone` | `text` (required), `max_attempts` 20, `interval_seconds` 3; polls until gone |
| `tap_desc_contains` | `text` (required substring of content-desc), `nth` |
| `seed_requests` | `child_id` (required), `domains` list; needs `SEED_REQUESTS_SCRIPT` |

## Command-line usage

Everything the studio does maps to plain script invocations.

Demo:

```bash
./android-demo.sh --app-id com.example.app --serial SERIAL \
  --steps my-tour.json --out out-dir-or-file.mp4 --tts say --voice Ava
./android-demo.sh --app-id com.example.app --dry-run --no-narration
./android-demo.sh --help    # full flag list
```

Spec tests:

```bash
./android-spec-test.sh --app-id com.example.app \
  --scenarios android-spec-tests/example.json
./android-spec-test.sh --app-id com.example.app \
  --scenarios ~/my-app/scenarios/          # every *.json, aggregate report
./android-spec-test.sh --app-id com.example.app \
  --scenarios android-spec-tests/auth.json \
  --only "AUTH-01: Parent signs in with email and password" \
  --report results.json
```

Flags: `--serial` targets one device (auto-picks when exactly one is
connected), `--activity` overrides the launch component (default: resolved
via the package manager, falling back to `.MainActivity`), `--scenarios`
takes a file or directory, `--only NAME` filters to one scenario, and
`--report FILE` writes the machine-readable summary:

```json
{
  "summary": {"available": 10, "implemented": 5, "passed": 4,
              "failed": 1, "skipped": 5},
  "results": [{"file": "auth.json", "name": "...", "status": "FAIL",
               "failed_step": "7 (assert_text)", "error": "..."}],
  "skipped": [{"file": "auth.json", "skipped": "AUTH-05",
               "why": "Not observable"}]
}
```

Environment: both scripts load `.env` from beside the input file/directory
and beside the script itself. Exec steps receive `DEMO_*` variables, and
scenario authors can call any host tool via `exec`.

### Recording two devices

Both drivers take a second device. `android-demo.sh` records both through the
same beat timeline and composites them side by side into one MP4;
`android-spec-test.sh` drives both without recording anything. In the studio
the second device is opt-in: tick **record a second device side by side** in
the App tab and a *Second device* card appears with its own device picker,
package field and activity field. Unticked, nothing about the primary device
changes and no second-device flag is passed at all.

| Flag | Meaning |
| --- | --- |
| `--serial-2 <serial>` | the second device. Without it, a single other attached device is adopted |
| `--app-id-2 <package>` | its app. Defaults to `--app-id`, so the same app on two phones needs only `--serial-2` |
| `--activity-2 <activity>` | its launch activity. Unset, it is resolved from that device's own package manager for `--app-id-2` |
| `--compose-height <n>` | demo only. Pane height for the composite, default 1080 |

Emulators count as candidates for the second device even though the primary
auto-detect skips them, since recording alongside an emulator is a common
case. With two or more *other* devices attached and no `--serial-2`, the
driver says so and stays with device 1: the demo prints "recording device 1
only", the spec driver "running device 1 only". Nothing is installed for you:
whatever apps you name have to be on the device that will run them.

**When the two devices run different apps**, `--app-id-2` still defaults to
`--app-id`, so pass it explicitly, and give the second device its own launch
component:

- On the command line, an unset `--activity-2` is resolved from the second
  device's package manager for `--app-id-2`, which is right, so two apps need
  no extra flag.
- In the studio, an empty second activity field sends the **primary's**
  activity as `--activity-2` (demo and spec runs alike), because that is the
  fallback that makes the same-app case need nothing. An explicit override
  wins over the package manager, so with two different apps the second phone
  gets started on the primary's component: it fails where that app is not
  installed, and launches the wrong app where it is. Fill in the second
  device's activity field, or hit **Resolve activity** on it, whenever the two
  apps differ.

Two portrait phones side by side give a near-square frame: `hstack` needs both
panes at the same height, and a portrait screen is about 0.45 as wide as it is
tall, so two of them come to 972x1080 at the default pane height. That shape
comes from the devices, not the flag: `--compose-height` sets the resolution
(540 gives 488x540, 1440 gives 1296x1440), so lower it for a smaller file and
raise it for more readable text. A single-device run is never composited and
ignores `--compose-height`: it passes through at the device's own screen size
(1080x2400). Either way the run prints what it is about to encode, for
example `==> Normalizing 3 recording segments to 972x1080`.

The geometry and the ffmpeg filter graph live in `android-compose-lib.sh`, as
pure functions over each device's screen size, so that is where to look for
how the composite is built and how to change it.

## Tips and troubleshooting

- **Device shows "unauthorized" or missing**: unlock the phone and accept
  the debugging prompt; press Refresh.
- **Assertion fails but the element looks visible**: uiautomator sees Compose
  semantics, not pixels; make sure the text is real content (or a
  contentDescription), not part of an image.
- **Password fields never dump their text**: that is expected; type into them
  via `tap_xy` coordinates.
- **Flaky first tap after a transition**: add `settle_ms`, or switch the
  preceding lookup to a polling action; do not raise global poll defaults.
- **Cancelled demo left the phone odd**: the scripts' cleanup traps restore
  DND and stop screenrecord even on Ctrl+C; simply re-run.
- **Where results live**: videos go to your chosen output folder; the last
  spec report is at `~/Library/Caches/demo-maker/last-spec-report.json`.
