# Demo Maker Web Studio

A local web UI with two ways to drive an Android app on a real device:

- **Video demos** via `android-demo.sh`: pick a device and app, compose
  narration with voice previews, edit the steps JSON in a tree editor, and
  record a narrated MP4 of the tour.
- **Spec tests** via `android-spec-test.sh`: run unattended assertion
  scenarios from JSON files and get pass/fail plus coverage reports.

Everything stays on your machine: the server binds to 127.0.0.1 only, uses a
random per-launch URL token, and has zero third-party Python dependencies.
See [INSTRUCTIONS.md](INSTRUCTIONS.md) for full walkthroughs, the scenario
and steps file formats, and troubleshooting.

## Quick start

```bash
./setup.sh     # one-time: builds .venv, checks tools, offers installs
./run.sh       # launches the studio and opens your browser
```

`setup.sh` finds a suitable Python (3.8+) via uv first, then pyenv, then
system interpreters; it can also install uv (user-local) when nothing else
qualifies. It runs the environment doctor afterwards, which asks before
installing anything missing (adb, jq, ffmpeg) and can download a Piper voice
model on request. Re-run the checks any time with `./setup.sh --check`.

## The tabs

| Tab | What it does |
| --- | --- |
| App | pick a connected device, list installed packages (user or all), auto-resolve the launch activity |
| Narration | engine choice (Piper default / macOS say / none), voice picker with search, rate slider, audio preview of any voice, piper model and binary paths |
| Steps | full tree editor for demo steps JSON and spec scenarios: add/edit/duplicate/delete/reorder, nested if.then/else branches, schema-driven forms with inline help and narration field, validation with per-step highlighting, run/dry-run buttons, open/save/recents |
| Spec Tests | scenarios directory and app id, per-file scenario browser with inline validation, edit scenarios in the tree editor, create files/scenarios, run one/file/all, live log, coverage report table |
| Output & Advanced | output folder and file name, segment seconds, keep-workdir, silent recording override, script path |
| Run | copyable command preview, live log streaming, cancel button, final MP4 path |

Settings persist between sessions (last device, app, engine, voice,
folders, recent steps files).

## Layout

```
android-demo.sh      the demo driver: narrated screen recording
android-spec-test.sh the spec-test driver: unattended assertions + coverage
android-ui-lib.sh    shared adb/uiautomator driving code for both scripts
android-spec-tests/  example scenario file (point the Spec Tests tab here
                     or at your own directory)
setup.sh / run.sh    bootstrap and launcher
demo_maker/          stdlib-only backend package
web/                 static frontend (vanilla JS)
tests/               unittest suite: .venv/bin/python -m unittest discover -s tests
example-steps.json   sample tour exercising most actions
piper-voices/        Piper models used by --tts piper
```

## Platform notes

- macOS: everything works, including the built-in `say` voices.
- Linux: fully supported except the `say` engine (macOS-only). Piper is the
  narration path there and works natively; the doctor offers to download an
  en_US voice (~63 MB) into `piper-voices/`.
- Voice previews are synthesized on demand into your cache directory
  (`~/Library/Caches/demo-maker/tts` or `$XDG_CACHE_HOME`) and played by the
  browser, so no OS audio player is needed.

## Requirements recap

Python 3.8+ (no pip packages), adb, jq, and ffmpeg + ffprobe for demo
recording. Spec testing needs only adb and jq. The doctor checks all of them
and prints the right install command for your platform.

## Troubleshooting

- "no devices found": unlock the phone, accept the USB debugging prompt, or
  press Refresh in the App tab.
- Piper preview fails: check the binary path in the Narration tab; the
  script resolves it from settings, PATH, then pyenv shims.
- A run was cancelled but the phone seems stuck: android-demo.sh restores
  Do-Not-Disturb via its cleanup trap even on Ctrl+C; re-running a demo is
  always safe.
