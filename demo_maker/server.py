"""HTTP server: static UI plus JSON API, all behind a per-launch token path."""
import json
import platform
import re
import shutil
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import adb, config, spec, steps, tts
from .runner import RUNNER, build_argv

try:
    from . import __version__
except ImportError:  # pragma: no cover
    __version__ = "0.0.0"

PROJECT_DIR = config.PROJECT_DIR
WEB_DIR = PROJECT_DIR / "web"
AUDIO_NAME_RE = re.compile(r"^[\w.-]+\.wav$")

TOKEN = ""
DEBUG = False

STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
}


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------- handlers

def api_state(handler, query, body):
    settings = config.load_settings()
    tools = {}
    for name in ("adb", "jq", "ffmpeg", "ffprobe", "say"):
        tools[name] = shutil.which(name) is not None
    tools["piper"] = tts.resolve_piper_bin(settings) is not None
    steps_path = str(settings.get("steps_path") or "")
    script_path = str(settings.get("script_path") or "")
    return {
        "version": __version__,
        "python": platform.python_version(),
        "platform": sys.platform,
        "darwin": sys.platform == "darwin",
        "script_ok": bool(script_path) and Path(script_path).is_file(),
        "steps_exists": bool(steps_path) and Path(steps_path).is_file(),
        "tools": tools,
        "piper_models": tts.piper_voices(settings),
        "running": RUNNER.running,
        "settings": settings,
    }


def api_devices(handler, query, body):
    return {"devices": adb.devices()}


def api_apps(handler, query, body):
    serial = (query.get("serial") or [""])[0]
    if not serial:
        raise ApiError(400, "serial parameter required")
    scope = (query.get("scope") or ["user"])[0]
    needle = (query.get("q") or [""])[0].lower()
    names = adb.packages(serial, scope if scope in ("user", "all") else "user")
    if needle:
        names = [n for n in names if needle in n.lower()]
    return {"packages": [{"package": n} for n in names]}


def api_activity(handler, query, body):
    serial = str(body.get("serial") or "")
    package = str(body.get("package") or "")
    if not serial or not package:
        raise ApiError(400, "serial and package are required")
    return {"activity": adb.resolve_activity(serial, package)}


def api_tts_voices(handler, query, body):
    engine = (query.get("engine") or [""])[0]
    settings = config.load_settings()
    out = {}
    if engine in ("", "say"):
        out["say"] = tts.say_voices() if sys.platform == "darwin" else []
    if engine in ("", "piper"):
        out["piper"] = tts.piper_voices(settings)
        out["piper_binary"] = tts.resolve_piper_bin(settings)
    return out


def api_tts_catalog(handler, query, body):
    force = (query.get("refresh") or ["0"])[0] == "1"
    return tts.fetch_piper_catalog(force=force)


def api_tts_download(handler, query, body):
    key = str(body.get("key") or "")
    try:
        return tts.start_voice_download(key)
    except tts.TtsError as exc:
        if "already in progress" in str(exc):
            raise ApiError(409, str(exc))
        raise


def api_tts_download_status(handler, query, body):
    return tts.voice_download_status()


def api_tts_sample(handler, query, body):
    engine = str(body.get("engine") or "")
    if engine not in ("say", "piper"):
        raise ApiError(400, "engine must be 'say' or 'piper'")
    wav = tts.synth_sample(
        engine,
        voice=str(body.get("voice") or ""),
        rate=str(body.get("rate") or ""),
        model=str(body.get("model") or ""),
        piper_bin=str(body.get("piper_bin") or ""),
        text=str(body.get("text") or ""),
    )
    return {"url": "%s/tts/audio/%s" % (handler.token_prefix(), wav.name)}


def api_browse(handler, query, body):
    raw = (query.get("path") or [""])[0] or str(Path.home())
    show_files = (query.get("show_files") or ["0"])[0] == "1"
    target = Path(raw).expanduser()
    if not target.exists():
        raise ApiError(404, "no such directory: %s" % target)
    if not target.is_dir():
        target = target.parent
    dirs, files = [], []
    try:
        for entry in sorted(target.iterdir(), key=lambda p: p.name.lower()):
            if entry.name.startswith("."):
                continue
            if entry.is_dir():
                dirs.append(entry.name)
            elif show_files:
                files.append(entry.name)
    except PermissionError:
        raise ApiError(403, "permission denied: %s" % target)
    return {"path": str(target), "parent": str(target.parent),
            "dirs": dirs, "files": files}


def api_steps_get(handler, query, body):
    settings = config.load_settings()
    path = (query.get("path") or [str(settings.get("steps_path") or "")])[0]
    doc = steps.load_steps_file(path)
    config.add_recent(path)
    return {"path": path, "steps": doc, "errors": steps.validate_steps(doc),
            "recents": config.load_settings()["recents"]}


def api_steps_put(handler, query, body):
    incoming = body.get("steps")
    if not isinstance(incoming, list):
        raise ApiError(400, "body must contain a 'steps' array")
    settings = config.load_settings()
    path = str(body.get("path") or settings.get("steps_path") or "")
    if not path:
        raise ApiError(400, "no steps path configured")
    errors = steps.save_steps_file(path, incoming)
    if errors:
        handler.send_json({"errors": errors}, status=422)
        return None
    config.update_settings({"steps_path": path})
    config.add_recent(path)
    return {"ok": True, "path": path, "errors": []}


def _device_count(settings) -> int:
    """How many device slots the current settings give a run.

    A step naming a slot past this has no serial and no app behind it, so the
    tree editor has to know the count to flag it before the run rather than
    leaving it to the shell to trip over mid-recording.
    """
    return 2 if settings.get("second_device") else 1


def api_steps_validate(handler, query, body):
    registry = spec.SPEC_ACTIONS \
        if str(body.get("registry") or "") == "spec" else None
    return {"errors": steps.validate_steps(
        body.get("steps"), registry,
        device_count=_device_count(config.load_settings()))}


def api_spec_validate(handler, query, body):
    return {"errors": steps.validate_steps(
        body.get("steps"), spec.SPEC_ACTIONS,
        device_count=_device_count(config.load_settings()))}


def api_schema(handler, query, body):
    return {"actions": steps.schema(),
            "default_order": list(steps.schema().keys()),
            "spec_actions": spec.SPEC_ACTIONS,
            "spec_default_order": list(spec.SPEC_ACTIONS.keys())}


def api_spec_file_get(handler, query, body):
    raw = (query.get("path") or [""])[0]
    if not raw:
        raise ApiError(400, "path parameter required")
    target = Path(raw).expanduser()
    if not target.is_file():
        raise ApiError(404, "no such file: %s" % target)
    try:
        doc = json.loads(target.read_text())
    except ValueError as exc:
        raise ApiError(400, "%s is not valid JSON: %s" % (target, exc))
    if not isinstance(doc, list):
        raise ApiError(400, "%s must contain a JSON array" % target)
    return {"path": str(target), "doc": doc}


def _error_summary(problems, limit=4):
    head = ["%s %s" % (p["path"], p["message"]) for p in problems[:limit]]
    extra = len(problems) - limit
    text = "; ".join(head)
    return text + ("; ...%d more" % extra if extra > 0 else "")


def api_spec_file_put(handler, query, body):
    incoming = body.get("doc")
    path = str(body.get("path") or "").strip()
    if not path:
        raise ApiError(400, "path is required")
    if not isinstance(incoming, list):
        raise ApiError(400, "body must contain a 'doc' array")
    problems = spec.validate_doc(incoming)
    if problems:
        handler.send_json({"errors": problems,
                           "error": _error_summary(problems)}, status=422)
        return None
    target = Path(path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(incoming, indent=2) + "\n")
    tmp.rename(target)
    config.add_recent(str(target))
    return {"ok": True, "path": str(target), "errors": []}


def api_settings_put(handler, query, body):
    return {"settings": config.update_settings(body)}


def _merged_settings(body):
    overrides = body.get("settings") or {}
    if not isinstance(overrides, dict):
        raise ApiError(400, "'settings' must be an object")
    merged = config.load_settings()
    for key, value in overrides.items():
        if key in config.DEFAULTS:
            merged[key] = value
    return merged


def _prepare_run(body, persist):
    mode = str(body.get("mode") or "normal")
    if mode not in ("normal", "dry"):
        mode = "normal"
    merged = _merged_settings(body)
    argv, errors = build_argv(merged, mode)
    if errors:
        raise ApiError(400, "; ".join(errors))
    if persist:
        persisted = {k: v for k, v in merged.items() if k in config.DEFAULTS}
        config.save_settings(persisted)
    return argv, mode


def api_command(handler, query, body):
    argv, _ = _prepare_run(body, persist=False)
    return {"argv": argv, "command": " ".join(_quote(a) for a in argv)}


def _quote(text):
    return "'" + text.replace("'", "'\\''") + "'" \
        if re.search(r"[^\w@%+=:,./-]", text) else text


def api_run(handler, query, body):
    argv, mode = _prepare_run(body, persist=True)
    RUNNER.start(argv, cwd=str(PROJECT_DIR))
    return {"ok": True, "mode": mode}


def api_run_status(handler, query, body):
    try:
        since = int((query.get("since") or ["0"])[0])
    except ValueError:
        since = 0
    status = RUNNER.status(max(0, since))
    status["mode_supported"] = True
    return status


def api_run_cancel(handler, query, body):
    return {"cancelled": RUNNER.cancel()}


def api_spec_state(handler, query, body):
    settings = config.load_settings()
    dir_path = str(settings.get("spec_scenarios_dir") or "").strip()
    files, error = [], ""
    if not dir_path:
        error = "no scenarios directory configured"
    else:
        try:
            files = [spec.inspect_file(p)
                     for p in spec.list_scenario_files(dir_path)]
        except spec.SpecError as exc:
            error = str(exc)
    return {
        "dir": dir_path,
        "error": error,
        "files": files,
        "totals": spec.summarize(files),
        "app_id": settings.get("spec_app_id") or "",
        "activity": settings.get("spec_activity") or "",
        "serial": settings.get("serial") or "",
        "script_ok": Path(str(settings.get("spec_script") or "")).is_file(),
    }


def api_spec_run(handler, query, body):
    overrides = body.get("settings") or {}
    if not isinstance(overrides, dict):
        raise ApiError(400, "'settings' must be an object")
    merged = config.load_settings()
    for key, value in overrides.items():
        if key in config.DEFAULTS:
            merged[key] = value
    target = None
    file_hint = str(body.get("file") or "").strip()
    if file_hint:
        candidate = Path(file_hint).expanduser()
        if not candidate.is_absolute():
            base = Path(str(merged.get("spec_scenarios_dir") or ""))
            candidate = base / candidate
        target = str(candidate)
    only = str(body.get("only") or "").strip() or None
    report_path = str(config.cache_root() / "last-spec-report.json")
    argv, errors = spec.build_spec_argv(
        merged, target=target, only=only, report_path=report_path)
    if errors:
        raise ApiError(400, "; ".join(errors))
    config.save_settings({k: v for k, v in merged.items()
                          if k in config.DEFAULTS})
    RUNNER.start(argv, cwd=str(PROJECT_DIR), kind="spec",
                 report_path=report_path)
    return {"ok": True}


GET_ROUTES = {
    "/api/state": api_state,
    "/api/devices": api_devices,
    "/api/apps": api_apps,
    "/api/schema": api_schema,
    "/api/steps": api_steps_get,
    "/api/browse": api_browse,
    "/api/run/status": api_run_status,
    "/api/spec/state": api_spec_state,
    "/api/spec/file": api_spec_file_get,
    "/tts/voices": api_tts_voices,
    "/tts/catalog": api_tts_catalog,
    "/tts/download/status": api_tts_download_status,
}

POST_ROUTES = {
    "/api/activity": api_activity,
    "/api/steps/validate": api_steps_validate,
    "/api/spec/validate": api_spec_validate,
    "/api/settings": api_settings_put,
    "/api/command": api_command,
    "/api/run": api_run,
    "/api/run/cancel": api_run_cancel,
    "/api/spec/run": api_spec_run,
    "/tts/sample": api_tts_sample,
    "/tts/download": api_tts_download,
}

PUT_ROUTES = {
    "/api/settings": api_settings_put,
    "/api/steps": api_steps_put,
    "/api/spec/file": api_spec_file_put,
}


class StudioHandler(BaseHTTPRequestHandler):
    server_version = "DemoMakerStudio/0.1"

    def token_prefix(self):
        return "/" + TOKEN

    def log_message(self, fmt, *args):  # quiet unless --debug
        if DEBUG:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # ---- plumbing ----------------------------------------------------
    def _send_bytes(self, status, ctype, payload, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, obj, status=200):
        self._send_bytes(status, "application/json",
                         json.dumps(obj).encode())

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode())
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    def _route(self, method):
        parsed = urlparse(self.path)
        parts = parsed.path.split("/")
        if len(parts) < 2 or parts[1] != TOKEN:
            return self._send_bytes(404, "text/plain", b"not found")
        tail = "/".join(parts[2:])
        rest = "/" + tail if tail else "/"
        query = parse_qs(parsed.query)

        if method == "GET" and rest.startswith("/tts/audio/"):
            return self.serve_audio(rest[len("/tts/audio/"):])

        routes = {"GET": GET_ROUTES, "POST": POST_ROUTES,
                  "PUT": PUT_ROUTES}.get(method, {})
        fn = routes.get(rest)
        if fn is not None:
            body = self.read_body() if method in ("POST", "PUT") else {}
            result = fn(self, query, body)
            if result is not None:
                self.send_json(result)
            return

        if method == "GET":
            return self.serve_static(rest)
        raise ApiError(404, "unknown endpoint")

    # ---- responses ---------------------------------------------------
    def serve_static(self, rest):
        name = "index.html" if rest in ("", "/") else rest.lstrip("/")
        path = (WEB_DIR / name).resolve()
        if WEB_DIR not in path.parents or not path.is_file():
            return self._send_bytes(404, "text/plain", b"not found")
        ctype = STATIC_TYPES.get(path.suffix, "application/octet-stream")
        self._send_bytes(200, ctype, path.read_bytes())

    def serve_audio(self, name):
        if not AUDIO_NAME_RE.match(name):
            return self._send_bytes(404, "text/plain", b"not found")
        wav = config.tts_cache_dir() / name
        if not wav.is_file():
            return self._send_bytes(404, "text/plain", b"not found")
        data = wav.read_bytes()
        total = len(data)
        rng = self.headers.get("Range") or ""
        match = re.match(r"bytes=(\d*)-(\d*)", rng)
        if match and (match.group(1) or match.group(2)):
            start = int(match.group(1) or 0)
            end = min(int(match.group(2)) if match.group(2) else total - 1,
                      total - 1)
            chunk = data[start:end + 1]
            self._send_bytes(
                206, "audio/wav", chunk,
                extra={"Content-Range": "bytes %d-%d/%d" % (start, end, total),
                       "Accept-Ranges": "bytes"})
        else:
            self._send_bytes(200, "audio/wav", data,
                             extra={"Accept-Ranges": "bytes"})

    # ---- verbs -------------------------------------------------------
    def do_GET(self):
        self._guarded("GET")

    def do_POST(self):
        self._guarded("POST")

    def do_PUT(self):
        self._guarded("PUT")

    def _guarded(self, method):
        try:
            self._route(method)
        except ApiError as exc:
            self.send_json({"error": str(exc)}, status=exc.status)
        except adb.AdbError as exc:
            self.send_json({"error": str(exc)}, status=502)
        except steps.StepError as exc:
            self.send_json({"error": str(exc)}, status=400)
        except spec.SpecError as exc:
            self.send_json({"error": str(exc)}, status=400)
        except tts.TtsError as exc:
            self.send_json({"error": str(exc)}, status=502)
        except Exception as exc:  # noqa: BLE001: last-ditch JSON error
            if DEBUG:
                import traceback
                traceback.print_exc()
            self.send_json({"error": "internal: %s" % exc}, status=500)


def make_server(port: int, token: str, debug: bool = False):
    """Bind 127.0.0.1:port and remember the launch token globally."""
    global TOKEN, DEBUG
    TOKEN = token
    DEBUG = debug
    httpd = ThreadingHTTPServer(("127.0.0.1", port), StudioHandler)
    httpd.daemon_threads = True
    return httpd
