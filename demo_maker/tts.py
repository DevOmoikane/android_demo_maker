"""Voice listing and preview synthesis for the say and Piper engines."""
import hashlib
import re
import shutil
import subprocess
from pathlib import Path
from typing import List, Optional

from . import config
from .doctor import find_piper_binary

PROJECT_DIR = config.PROJECT_DIR
_SAY_LINE = re.compile(r"^(.*\S)\s+([A-Za-z]{2}[-_][A-Za-z]{2,4})$")
PIPER_MODELS_DIR = PROJECT_DIR / "piper-voices"


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
