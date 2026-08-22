"""Thin adb wrappers used by the studio backend."""
import shutil
import subprocess
import time
from typing import List


class AdbError(RuntimeError):
    pass


def adb_path() -> str:
    found = shutil.which("adb")
    if not found:
        raise AdbError("adb not found on PATH")
    return found


def _run(args: List[str], timeout: float = 20) -> str:
    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=timeout)
    except FileNotFoundError:
        raise AdbError("adb not found on PATH")
    except subprocess.TimeoutExpired:
        raise AdbError("adb timed out: " + " ".join(args))
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "adb failed").strip()
        raise AdbError(detail.splitlines()[0] if detail else "adb failed")
    return proc.stdout


def devices() -> List[dict]:
    out = _run([adb_path(), "devices", "-l"])
    result = []
    for attempt in range(2):
        result = _parse_devices(out)
        if result:
            break
        # a cold adb daemon prints only its header while starting up
        time.sleep(0.8)
        out = _run([adb_path(), "devices", "-l"])
    return result


def _parse_devices(out: str) -> List[dict]:
    result = []
    for line in out.replace("\r", "").splitlines()[1:]:
        line = line.strip()
        if not line or line.startswith("*"):
            continue
        parts = line.split()
        entry = {"serial": parts[0],
                 "state": parts[1] if len(parts) > 1 else "?",
                 "model": ""}
        for part in parts[2:]:
            if part.startswith("model:"):
                entry["model"] = part.split(":", 1)[1].replace("_", " ")
        result.append(entry)
    return result


def packages(serial: str, scope: str = "user") -> List[str]:
    args = [adb_path(), "-s", serial, "shell", "pm", "list", "packages"]
    if scope == "user":
        args.append("-3")
    out = _run(args, timeout=45)
    names = []
    for line in out.splitlines():
        line = line.strip().replace("\r", "")
        if line.startswith("package:"):
            names.append(line[len("package:"):])
    return sorted(names)


def resolve_activity(serial: str, package: str) -> str:
    """Mirror android-demo.sh's MAIN/LAUNCHER resolution and fallbacks."""
    brief = _run([adb_path(), "-s", serial, "shell", "cmd", "package",
                  "resolve-activity", "--brief",
                  "-a", "android.intent.action.MAIN",
                  "-c", "android.intent.category.LAUNCHER", package])
    lines = [ln.strip() for ln in brief.replace("\r", "").splitlines()]
    activity = next((ln for ln in lines if ln.startswith(package + "/")), "")
    if not activity:
        activity = next((ln for ln in lines
                         if "/" in ln and not ln.startswith("priority=")), "")
    return activity or (package + "/.MainActivity")


def screen_size(serial: str):
    out = _run([adb_path(), "-s", serial, "shell", "wm", "size"])
    # e.g. "Physical size: 1080x2340"
    for line in out.replace("\r", "").splitlines():
        _, _, dims = line.partition(":")
        dims = dims.strip()
        if "x" in dims:
            w, _, h = dims.partition("x")
            if w.strip().isdigit() and h.strip().isdigit():
                return int(w), int(h)
    return None
