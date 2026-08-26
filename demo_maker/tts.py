"""Voice listing and preview synthesis for the say and Piper engines."""
import hashlib
import json
import re
import shutil
import subprocess
import threading
import time
import urllib.request
from pathlib import Path
from typing import List, Optional

from . import config
from .doctor import download_file, find_piper_binary

PROJECT_DIR = config.PROJECT_DIR
_SAY_LINE = re.compile(r"^(.*\S)\s+([A-Za-z]{2}[-_][A-Za-z]{2,4})$")
PIPER_MODELS_DIR = PROJECT_DIR / "piper-voices"

# Downloadable Piper voices live in the rhasspy/piper-voices HF repo under
# <family>/<locale>/<name>/<quality>/<key>.onnx (+ .onnx.json sidecar).
HF_TREE_API = ("https://huggingface.co/api/models/rhasspy/piper-voices"
               "/tree/main")
HF_RESOLVE_BASE = "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
CATALOG_CACHE_FILE = config.cache_root() / "piper-catalog.json"
CATALOG_TTL_SECONDS = 24 * 3600
QUALITY_ORDER = {"x_low": 0, "low": 1, "medium": 2, "high": 3}

# Shown when neither the network nor a cache copy is reachable; relpath uses
# the canonical repo layout so downloads still work once connectivity returns.
_BUNDLED_VOICE_DIRS = [
    "en/en_US/amy/medium",
    "en/en_US/lessac/medium",
    "en/en_US/ryan/high",
    "en/en_US/hfc_female/medium",
    "en/en_GB/alba/medium",
    "de/de_DE/thorsten/medium",
    "fr/fr_FR/siwis/medium",
    "es/es_ES/sharvard/medium",
    "it/it_IT/riccardo/medium",
    "pt/pt_BR/faber/medium",
]


class TtsError(RuntimeError):
    pass


def parse_say_voices(text: str) -> List[dict]:
    """Parse `say -v ?` output: NAME<spaces>LOCALE  # sample sentence."""
    voices: List[dict] = []
    seen = set()
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        sample = ""
        hash_idx = line.find("#")
        if hash_idx >= 0:
            sample = line[hash_idx + 1:].strip()
            line = line[:hash_idx].rstrip()
        match = _SAY_LINE.match(line)
        if not match:
            continue
        name = match.group(1).strip()
        locale = match.group(2).replace("-", "_")
        key = name + "/" + locale
        if key not in seen:
            seen.add(key)
            voices.append({"name": name, "locale": locale, "sample": sample})
    return voices


def say_voices() -> List[dict]:
    if not shutil.which("say"):
        return []
    proc = subprocess.run(["say", "-v", "?"], capture_output=True, text=True,
                          timeout=15)
    return parse_say_voices(proc.stdout)


def piper_voices(settings: Optional[dict] = None) -> List[dict]:
    """All .onnx models found next to the script plus the configured one."""
    candidates = []
    if PIPER_MODELS_DIR.is_dir():
        candidates.extend(sorted(PIPER_MODELS_DIR.glob("*.onnx")))
    settings = settings or {}
    configured = str(settings.get("piper_model") or "")
    if configured:
        cpath = Path(configured)
        if cpath.is_file() and cpath not in candidates:
            candidates.append(cpath)
    out = []
    for path in candidates:
        out.append({"name": path.stem, "file": str(path)})
    return out


def resolve_piper_bin(settings: Optional[dict] = None) -> Optional[str]:
    settings = settings or {}
    explicit = str(settings.get("piper_bin") or "").strip()
    if explicit and Path(explicit).exists():
        return explicit
    found = find_piper_binary()
    if found:
        return found
    return None


def _cache_path(key_parts: List[str]) -> Path:
    digest = hashlib.sha1("\x00".join(key_parts).encode()).hexdigest()[:20]
    directory = config.tts_cache_dir()
    directory.mkdir(parents=True, exist_ok=True)
    return directory / ("%s.wav" % digest)


def synth_sample(engine: str, voice: str = "", rate: str = "",
                 model: str = "", piper_bin: str = "", text: str = "") -> Path:
    """Synthesize a short preview into the cache and return its path."""
    if engine == "say":
        if not shutil.which("say"):
            raise TtsError("the say engine is macOS-only")
        text = text or ("Hello, this is the %s voice." % (voice or "default"))
        wav = _cache_path(["say", voice, rate, text])
        if wav.exists():
            return wav
        cmd = ["say"]
        if voice:
            cmd += ["-v", voice]
        if rate:
            cmd += ["-r", rate]
        cmd += ["--data-format=LEI16@22050", "-o", str(wav), "--", text]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    elif engine == "piper":
        settings = config.load_settings()
        merged = dict(settings)
        if model:
            merged["piper_model"] = model
        if piper_bin:
            merged["piper_bin"] = piper_bin
        binary = resolve_piper_bin(merged)
        if not binary:
            raise TtsError("piper binary not found (see the Narration tab)")
        model_path = model or str(settings.get("piper_model") or "")
        if not model_path:
            voices = piper_voices(settings)
            if not voices:
                raise TtsError("no Piper voice model available")
            model_path = voices[0]["file"]
        stem = Path(model_path).stem
        text = text or ("Hello, this is the %s voice." % stem)
        wav = _cache_path(["piper", binary, model_path, text])
        if wav.exists():
            return wav
        cmd = [binary, "-m", model_path, "-f", str(wav)]
        config_json = Path(model_path + ".json")
        if config_json.is_file():
            cmd += ["-c", str(config_json)]
        try:
            proc = subprocess.run(cmd, input=text.encode(), timeout=120,
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.PIPE)
        except FileNotFoundError:
            raise TtsError("piper binary is not executable: %s" % binary)
    else:
        raise TtsError("unknown engine: %r" % engine)

    if proc.returncode != 0 or not wav.exists():
        detail = ""
        if getattr(proc, "stderr", None):
            err = proc.stderr
            detail = (err.decode(errors="replace") if isinstance(err, bytes)
                      else str(err)).strip().splitlines()
            detail = detail[0][:200] if detail else ""
        if wav.exists():
            wav.unlink()
        raise TtsError(detail or ("%s exited with status %d"
                                  % (engine, proc.returncode)))
    return wav


# ------------------------------------------------------------ piper catalog

def _entry_from_repo_dir(rel_dir: str, size_bytes: int = 0) -> Optional[dict]:
    """en/en_US/amy/medium -> voice entry with key en_US-amy-medium."""
    parts = [p for p in rel_dir.strip("/").split("/") if p]
    if len(parts) != 4 or any(p in (".", "..") for p in parts):
        return None
    family, locale, name, quality = parts
    key = "%s-%s-%s" % (locale, name, quality)
    return {
        "key": key,
        "locale": locale,
        "name": name,
        "quality": quality,
        "size_bytes": size_bytes,
        "relpath": "%s/%s.onnx" % (rel_dir.strip("/"), key),
    }


def _entry_from_tree_path(path: str, size_bytes: int) -> Optional[dict]:
    """HF tree entry path .../voice.onnx -> catalog entry."""
    if not path.endswith(".onnx") or path.endswith(".onnx.json"):
        return None
    entry = _entry_from_repo_dir(str(Path(path).parent), size_bytes)
    if entry and Path(path).name != entry["key"] + ".onnx":
        return None
    return entry


def _sort_voices(voices: List[dict]) -> List[dict]:
    return sorted(voices, key=lambda v: (
        v["locale"], v["name"], QUALITY_ORDER.get(v["quality"], 9)))


def _bundled_catalog() -> dict:
    voices = _sort_voices(
        e for e in (_entry_from_repo_dir(d) for d in _BUNDLED_VOICE_DIRS)
        if e)
    return {"source": "bundled", "fetched_at": time.time(),
            "voices": voices}


def _read_catalog_cache(max_age: Optional[float]) -> Optional[dict]:
    try:
        data = json.loads(CATALOG_CACHE_FILE.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(
        data.get("voices"), list) or not data["voices"]:
        return None
    if max_age is not None \
            and time.time() - float(data.get("fetched_at") or 0) > max_age:
        return None
    return data


def _write_catalog_cache(payload: dict) -> None:
    CATALOG_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CATALOG_CACHE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload))
    tmp.rename(CATALOG_CACHE_FILE)


def fetch_piper_catalog(force: bool = False) -> dict:
    """Downloadable Piper voices: live index, disk cache, then bundled list.

    'installed' is stamped per request from the filesystem, never cached.
    """
    payload = None
    if not force:
        payload = _read_catalog_cache(CATALOG_TTL_SECONDS)
    if payload is None:
        try:
            request = urllib.request.Request(
                HF_TREE_API + "?recursive=true",
                headers={"User-Agent": "demo-maker-studio"})
            with urllib.request.urlopen(request, timeout=15) as resp:
                raw = json.loads(resp.read().decode())
            voices = []
            for item in raw:
                if item.get("type") != "file":
                    continue
                entry = _entry_from_tree_path(
                    str(item.get("path") or ""),
                    int(item.get("size") or 0))
                if entry:
                    voices.append(entry)
            if not voices:
                raise TtsError("index contained no voices")
            payload = {"source": "network", "fetched_at": time.time(),
                       "voices": _sort_voices(voices)}
            _write_catalog_cache(payload)
        except Exception:
            stale = _read_catalog_cache(None)
            if stale:
                payload = dict(stale)
                payload["source"] = "cache"
            else:
                payload = _bundled_catalog()
    out = dict(payload)
    out["voices"] = [
        dict(v, installed=(PIPER_MODELS_DIR / Path(v["relpath"]).name)
             .is_file())
        for v in payload["voices"]
    ]
    return out


# ----------------------------------------------------------- download job

_DOWNLOAD_LOCK = threading.Lock()
_download_state: dict = {"running": False, "done": False, "key": "",
                         "error": "", "got": 0, "total": 0}


def _find_voice_entry(key: str) -> Optional[dict]:
    for source in (_read_catalog_cache(None), _bundled_catalog()):
        if not source:
            continue
        for voice in source.get("voices", []):
            if voice["key"] == key:
                return voice
    return None


def start_voice_download(key: str) -> dict:
    """Kick off a background download of one voice (+ .json sidecar)."""
    key = str(key or "").strip()
    entry = _find_voice_entry(key)
    if not entry:
        raise TtsError("unknown voice %r; refresh the list first" % key)
    filename = Path(entry["relpath"]).name
    if ".." in entry["relpath"]:
        raise TtsError("bad voice path")
    model_dest = PIPER_MODELS_DIR / filename
    json_dest = PIPER_MODELS_DIR / (filename + ".json")
    if model_dest.is_file() and json_dest.is_file():
        raise TtsError("%s is already installed" % key)
    with _DOWNLOAD_LOCK:
        if _download_state["running"]:
            raise TtsError("a download is already in progress (%s)"
                           % _download_state["key"])
        _download_state.update(running=True, done=False, key=key,
                               error="", got=0, total=0)
    threading.Thread(target=_run_voice_download,
                     args=(entry, model_dest, json_dest),
                     daemon=True).start()
    return voice_download_status()


def _run_voice_download(entry: dict, model_dest: Path,
                        json_dest: Path) -> None:
    try:
        PIPER_MODELS_DIR.mkdir(parents=True, exist_ok=True)
        for dest in (model_dest, json_dest):
            url = HF_RESOLVE_BASE + entry["relpath"] \
                + (".json" if dest == json_dest else "")
            download_file(url, dest, progress=_download_progress)
        with _DOWNLOAD_LOCK:
            _download_state.update(done=True, total=max(
                _download_state["total"],
                model_dest.stat().st_size + json_dest.stat().st_size))
    except Exception as exc:  # noqa: BLE001: surfaced verbatim in the UI
        for partial in (model_dest, json_dest,
                        model_dest.with_name(model_dest.name + ".part"),
                        json_dest.with_name(json_dest.name + ".part")):
            if partial.exists():
                try:
                    partial.unlink()
                except OSError:
                    pass
        with _DOWNLOAD_LOCK:
            _download_state.update(error=str(exc))
    finally:
        with _DOWNLOAD_LOCK:
            _download_state["running"] = False


def _download_progress(got: int, total: int) -> None:
    with _DOWNLOAD_LOCK:
        _download_state.update(got=got, total=total)


def voice_download_status() -> dict:
    with _DOWNLOAD_LOCK:
        status = dict(_download_state)
    if status["done"] and not status["error"]:
        status["installed"] = True
    return status
