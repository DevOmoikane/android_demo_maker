"""Settings persistence and platform-aware directories."""
import json
import os
import sys
from pathlib import Path
from typing import Dict

PROJECT_DIR = Path(__file__).resolve().parent.parent


def app_support_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "demo-maker"
    root = os.environ.get("XDG_CONFIG_HOME")
    base = Path(root) if root else Path.home() / ".config"
    return base / "demo-maker"


def cache_root() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "demo-maker"
    root = os.environ.get("XDG_CACHE_HOME")
    base = Path(root) if root else Path.home() / ".cache"
    return base / "demo-maker"


def tts_cache_dir() -> Path:
    return cache_root() / "tts"


SETTINGS_FILE = app_support_dir() / "settings.json"

_DEFAULT_SPEC_DIR = PROJECT_DIR / "android-spec-tests"
DEFAULTS: Dict[str, object] = {
    "script_path": str(PROJECT_DIR / "android-demo.sh"),
    "steps_path": str(PROJECT_DIR / "android-demo-steps.json"),
    "spec_script": str(PROJECT_DIR / "android-spec-test.sh"),
    "spec_scenarios_dir": str(_DEFAULT_SPEC_DIR) if _DEFAULT_SPEC_DIR.is_dir()
    else "",
    "spec_app_id": "",
    "spec_activity": "",
    "out_dir": str(PROJECT_DIR),
    "out_name": "",
    "segment_seconds": 150,
    "engine": "piper",
    "voice": "",
    "rate": "",
    "piper_model": "",
    "piper_bin": "",
    "serial": "",
    "app_id": "",
    "activity": "",
    "scope": "user",
    "keep_workdir": False,
    "no_narration": False,
    "recents": [],
}

_BOOL_KEYS = {"keep_workdir", "no_narration"}
_INT_KEYS = {"segment_seconds"}
_LIST_KEYS = {"recents"}


def load_settings() -> Dict[str, object]:
    settings = dict(DEFAULTS)
    try:
        raw = SETTINGS_FILE.read_text()
        stored = json.loads(raw)  # noqa: F821
    except FileNotFoundError:
        return settings
    except (ValueError, OSError):
        return settings
    if isinstance(stored, dict):
        for key, value in stored.items():
            if key not in DEFAULTS:
                continue
            if key in _BOOL_KEYS:
                settings[key] = bool(value)
            elif key in _INT_KEYS:
                try:
                    settings[key] = int(value)
                except (TypeError, ValueError):
                    pass
            elif key in _LIST_KEYS:
                settings[key] = value if isinstance(value, list) else []
            else:
                settings[key] = "" if value is None else value
    return settings


def save_settings(settings: Dict[str, object]) -> None:
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(settings, indent=2) + "\n")
    tmp.rename(SETTINGS_FILE)


def update_settings(partial: Dict[str, object]) -> Dict[str, object]:
    settings = load_settings()
    clean = {}
    for key, value in partial.items():
        if key not in DEFAULTS:
            continue
        if key in _BOOL_KEYS:
            clean[key] = bool(value)
        elif key in _INT_KEYS:
            try:
                clean[key] = int(value)
            except (TypeError, ValueError):
                continue
        elif key == "recents":
            clean[key] = value if isinstance(value, list) else []
        elif key == "scope":
            clean[key] = value if value in ("user", "all") else "user"
        else:
            clean[key] = "" if value is None else str(value)
    settings.update(clean)
    save_settings(settings)
    return settings


def add_recent(path: str, limit: int = 8) -> None:
    settings = load_settings()
    recents = [p for p in settings["recents"] if p != path]
    recents.insert(0, path)
    settings["recents"] = recents[:limit]
    save_settings(settings)
