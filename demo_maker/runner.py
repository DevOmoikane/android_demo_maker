"""Runs the demo or spec-test script, buffers output, reports progress."""
import json
import os
import shlex
import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import List, Optional

DONE_MARKER = "==> Done: "


class Runner:
    def __init__(self):
        self._lock = threading.Lock()
        self._proc: Optional[subprocess.Popen] = None
        self._lines: List[str] = []
        self.exit_code: Optional[int] = None
        self.mp4_path: Optional[str] = None
        self.started_at: Optional[float] = None
        self.command: str = ""
        self.kind: str = "demo"
        self.report_path: str = ""
        self._report_cache: Optional[dict] = None

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self, argv: List[str], cwd: str, kind: str = "demo",
              report_path: str = "") -> None:
        with self._lock:
            if self.running:
                raise RuntimeError("a run is already in progress")
            self._lines = []
            self.exit_code = None
            self.mp4_path = None
            self.kind = kind
            self.report_path = report_path
            self._report_cache = None
            self.started_at = time.time()
            self.command = " ".join(shlex.quote(a) for a in argv)
            # start_new_session puts the script and its children (screenrecord,
            # ffmpeg) in their own process group so cancel can SIGINT the whole
            # group; android-demo.sh's cleanup trap then restores DND settings.
            self._proc = subprocess.Popen(
                argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, start_new_session=True)
            threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        proc = self._proc
        assert proc is not None and proc.stdout is not None
        for line in proc.stdout:
            text = line.rstrip("\n")
            with self._lock:
                self._lines.append(text)
                if text.startswith(DONE_MARKER) and not self.mp4_path:
                    self.mp4_path = text[len(DONE_MARKER):].strip()
        code = proc.wait()
        with self._lock:
            self.exit_code = code

    def status(self, since: int = 0) -> dict:
        with self._lock:
            lines = self._lines[since:]
            done = self.exit_code is not None
            payload = {
                "running": self.running,
                "offset": len(self._lines),
                "lines": lines,
                "exit_code": self.exit_code,
                "mp4_path": self.mp4_path,
                "started_at": self.started_at,
                "command": self.command,
                "kind": self.kind,
            }
        if done and self.kind == "spec" and self.report_path:
            report = self._load_report()
            if report is not None:
                payload["spec_report"] = report
        return payload

    def _load_report(self) -> Optional[dict]:
        """Parse the --report JSON once after a spec run finishes."""
        if self._report_cache is not None:
            return self._report_cache
        try:
            raw = Path(self.report_path).read_text()
            parsed = json.loads(raw)
        except (OSError, ValueError):
            parsed = {"error": "report file unreadable: %s" % self.report_path}
        self._report_cache = parsed
        return parsed

    def cancel(self) -> bool:
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return False
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGINT)
        except (ProcessLookupError, PermissionError):
            try:
                proc.terminate()
            except ProcessLookupError:
                pass
        return True


RUNNER = Runner()


def build_argv(settings: dict, mode: str = "normal"):
    """Translate settings into an android-demo.sh invocation.

    Returns (argv, errors); errors is non-empty when required pieces are
    missing or files do not exist.
    """
    from .config import PROJECT_DIR  # local import avoids a cycle at load

    errors = []
    script = str(settings.get("script_path") or "")
    if not script or not Path(script).is_file():
        errors.append("android-demo.sh not found: %s" % (script or "<unset>"))
        script = str(PROJECT_DIR / "android-demo.sh")

    app_id = str(settings.get("app_id") or "").strip()
    if not app_id:
        errors.append("no app selected")

    steps = str(settings.get("steps_path") or "").strip()
    if not steps or not Path(steps).is_file():
        errors.append("steps file not found: %s" % (steps or "<unset>"))

    serial = str(settings.get("serial") or "").strip()
    if not serial:
        errors.append("no device selected")

    if settings.get("second_device"):
        serial_2 = str(settings.get("serial_2") or "").strip()
        if not serial_2:
            errors.append("second device enabled but no second serial selected")
        elif serial_2 == serial:
            errors.append("second device is the same device as the main one")

    if errors:
        return [], errors

    argv = [script, "--app-id", app_id, "--serial", serial]
    activity = str(settings.get("activity") or "").strip()
    if activity:
        argv += ["--activity", activity]
    if settings.get("second_device"):
        # --app-id-2 and --activity-2 fall back to the primary, so the common
        # "same app on a phone and an emulator" case needs only a second serial.
        argv += ["--serial-2", str(settings.get("serial_2") or "").strip(),
                 "--app-id-2",
                 str(settings.get("app_id_2") or "").strip() or app_id]
        activity_2 = str(settings.get("activity_2") or "").strip() or activity
        if activity_2:
            argv += ["--activity-2", activity_2]
    argv += ["--steps", steps]

    engine = settings.get("engine") or "piper"
    if engine == "none":
        argv.append("--no-narration")
    else:
        argv += ["--tts", engine]
        if engine == "say":
            voice = str(settings.get("voice") or "").strip()
            if voice:
                argv += ["--voice", voice]
            rate = str(settings.get("rate") or "").strip()
            if rate:
                argv += ["--rate", rate]
        elif engine == "piper":
            model = str(settings.get("piper_model") or "").strip()
            if model:
                argv += ["--piper-model", model]
            piper_bin = str(settings.get("piper_bin") or "").strip()
            if piper_bin:
                argv += ["--piper-bin", piper_bin]

    # --out must always be a .mp4 FILE path: android-demo.sh only applies its
    # own default when --out is unset, so handing it a bare directory makes
    # ffmpeg fail after the whole recording has already been captured.
    out_dir = str(settings.get("out_dir") or "").strip() \
        or str(PROJECT_DIR / "output")
    out_name = str(settings.get("out_name") or "").strip()
    if not out_name:
        out_name = time.strftime("android-demo-%Y%m%d-%H%M%S.mp4")
    if not out_name.endswith(".mp4"):
        out_name += ".mp4"
    out = str(Path(out_dir) / out_name)
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    argv += ["--out", out]

    segment = int(settings.get("segment_seconds") or 150)
    argv += ["--segment-seconds", str(max(10, segment))]

    if settings.get("second_device"):
        # The composite is the only thing --compose-height sizes, and only a
        # second device produces one.
        height = int(settings.get("compose_height") or 1080)
        argv += ["--compose-height", str(max(240, height))]

    if mode == "dry":
        argv.append("--dry-run")
    if settings.get("keep_workdir"):
        argv.append("--keep-workdir")
    return argv, []
