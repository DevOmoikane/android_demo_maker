#!/usr/bin/env python3
"""Environment doctor for the Demo Maker Web Studio.

Checks every external tool the pipeline needs, explains what each one is
for, and offers to install what is missing (asking first). Can also
download a Piper voice model when requested.

Standalone usage:
    .venv/bin/python -m demo_maker.doctor [--check] [--yes]

  --check  report only: no prompts, no installs, exit code reflects result
  --yes    assume yes for every prompt (scripted setups)
"""
import argparse
import os
import platform
import shlex
import shutil
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional

if sys.version_info < (3, 8):
    print("error: Python 3.8 or newer is required", file=sys.stderr)
    sys.exit(1)

PROJECT_DIR = Path(__file__).resolve().parent.parent
PIPER_MODELS_DIR = PROJECT_DIR / "piper-voices"
PIPER_DEFAULT_VOICE = "en_US-hfc_female-medium"
HF_BASE = (
    "https://huggingface.co/rhasspy/piper-voices/resolve/main"
    "/en/en_US/hfc_female/medium"
)

SYSTEM = platform.system().lower()  # 'darwin' | 'linux' | ...


def linux_distro_family(os_release_text: Optional[str] = None) -> str:
    """Best-effort distro family from /etc/os-release content."""
    if os_release_text is None:
        try:
            os_release_text = Path("/etc/os-release").read_text()
        except OSError:
            return "generic"
    fields = {}
    for line in os_release_text.splitlines():
        if "=" in line:
            key, _, val = line.partition("=")
            fields[key.strip()] = val.strip().strip('"')
    blob = (fields.get("ID", "") + " " + fields.get("ID_LIKE", "")).lower()
    for needle, family in [
        ("debian", "debian"), ("ubuntu", "debian"), ("mint", "debian"),
        ("pop", "debian"), ("fedora", "fedora"), ("rhel", "fedora"),
        ("centos", "fedora"), ("rocky", "fedora"), ("alma", "fedora"),
        ("arch", "arch"), ("manjaro", "arch"), ("suse", "suse"),
    ]:
        if needle in blob:
            return family
    return "generic"


def _piper_works(path: str) -> bool:
    """A stale pyenv shim can exist without a real install behind it."""
    try:
        probe = subprocess.run([path, "--help"], capture_output=True,
                               timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return probe.returncode == 0


def find_piper_binary() -> Optional[str]:
    """PATH first (probed), then common locations, then newest pyenv install.

    Mirrors android-demo.sh's resolution so the studio agrees with the
    script about which binary will be used.
    """
    found = shutil.which("piper")
    if found and _piper_works(found):
        return found
    home = Path.home()
    candidates = [
        home / ".local" / "bin" / "piper",
        Path("/opt/homebrew/bin/piper"),
        Path("/usr/local/bin/piper"),
    ]
    for cand in candidates:
        if cand.is_file() and _piper_works(str(cand)):
            return str(cand)
    pyenv_versions = Path(os.environ.get("PYENV_ROOT",
                                         str(home / ".pyenv"))) / "versions"
    if pyenv_versions.is_dir():
        for version_dir in sorted(pyenv_versions.iterdir(), reverse=True):
            cand = version_dir / "bin" / "piper"
            if cand.is_file() and _piper_works(str(cand)):
                return str(cand)
    return None


@dataclass
class Check:
    key: str
    title: str
    why: str
    required: bool
    platforms: tuple = ("darwin", "linux")
    hints: Dict[str, List[str]] = field(default_factory=dict)
    finder: Optional[Callable[[], Optional[str]]] = None

    def applies(self) -> bool:
        return SYSTEM in self.platforms

    def find(self) -> Optional[str]:
        if self.finder is not None:
            return self.finder()
        return shutil.which(self.key)

    def hint_lines(self) -> List[str]:
        keys = [linux_distro_family()] if SYSTEM == "linux" else ["darwin"]
        lines: List[str] = []
        seen = set()
        for k in keys + ["generic"]:
            for cmd in self.hints.get(k, []):
                if cmd not in seen:
                    seen.add(cmd)
                    lines.append(cmd)
        return lines


CHECKS: List[Check] = [
    Check(
        key="adb",
        title="adb",
        why="drives the device: taps, swipes, screenrecord",
        required=True,
        hints={
            "darwin": ["brew install --cask android-platform-tools"],
            "debian": ["sudo apt install adb"],
            "fedora": ["sudo dnf install android-tools"],
            "arch": ["sudo pacman -S android-tools"],
            "suse": ["sudo zypper install android-tools"],
            "generic": [
                "install Android platform-tools from developer.android.com"
                " and put adb on your PATH"
            ],
        },
    ),
    Check(
        key="jq",
        title="jq",
        why="parses uiautomator XML and step-file data inside android-demo.sh",
        required=True,
        hints={
            "darwin": ["brew install jq"],
            "debian": ["sudo apt install jq"],
            "fedora": ["sudo dnf install jq"],
            "arch": ["sudo pacman -S jq"],
            "suse": ["sudo zypper install jq"],
        },
    ),
    Check(
        key="ffmpeg",
        title="ffmpeg",
        why="concatenates segments and muxes narration into the final MP4",
        required=True,
        hints={
            "darwin": ["brew install ffmpeg"],
            "debian": ["sudo apt install ffmpeg"],
            "fedora": ["sudo dnf install ffmpeg"],
            "arch": ["sudo pacman -S ffmpeg"],
            "suse": ["sudo zypper install ffmpeg"],
        },
    ),
    Check(
        key="ffprobe",
        title="ffprobe",
        why="verifies the produced video file",
        required=True,
        hints={
            "darwin": ["brew install ffmpeg"],
            "debian": ["sudo apt install ffmpeg"],
            "fedora": ["sudo dnf install ffmpeg"],
            "arch": ["sudo pacman -S ffmpeg"],
            "suse": ["sudo zypper install ffmpeg"],
        },
    ),
    Check(
        key="say",
        title="say",
        why="default TTS engine for narration (macOS built-in)",
        required=False,
        platforms=("darwin",),
        hints={"darwin": ["provided by macOS; reinstall via System Settings > Software Update"]},
    ),
    Check(
        key="piper",
        title="piper",
        why="optional neural TTS engine; the natural choice on Linux",
        required=False,
        finder=find_piper_binary,
        hints={
            "darwin": ["pip install piper-tts"],
            "debian": ["pip install piper-tts"],
            "generic": [
                "pip install piper-tts",
                "or grab a release binary: https://github.com/rhasspy/piper/releases",
            ],
        },
    ),
]


def run_install_command(cmd: str) -> bool:
    """Run one install command interactively so sudo can ask for a password."""
    print(f"    running: {cmd}")
    try:
        proc = subprocess.run(shlex.split(cmd))
    except FileNotFoundError:
        print(f"    command not found: {cmd.split()[0]}")
        return False
    return proc.returncode == 0


def offer_installs(missing_required: List[Check], check_only: bool,
                   assume_yes: bool) -> List[Check]:
    """Print hints for everything missing; try to install required tools."""
    still_missing: List[Check] = []
    for check in missing_required:
        hints = check.hint_lines()
        label = "required" if check.required else "optional"
        print(f"  to install ({label}):")
        for h in hints:
            print(f"      {h}")
        if check_only or not check.required:
            still_missing.append(check)
            continue
        if len(hints) == 1:
            question = f"Install {check.title} now with: {hints[0]}?"
        else:
            question = f"Try installing {check.title} now?"
        if assume_yes is False:
            try:
                answer = input(question + " [y/N] ")
            except EOFError:
                answer = ""
            if answer.strip().lower() not in ("y", "yes"):
                still_missing.append(check)
                continue
        ok = all(run_install_command(h) for h in hints)
        if ok and check.find():
            print(f"  [ok]      {check.title} installed")
        else:
            print(f"  [failed]  could not install {check.title} automatically")
            still_missing.append(check)
    return still_missing


def piper_model_urls(voice: str) -> List[str]:
    return [f"{HF_BASE}/{voice}.onnx", f"{HF_BASE}/{voice}.onnx.json"]


def download_file(url: str, dest: Path, chunk_size: int = 1 << 20) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "demo-maker-doctor"})
    with urllib.request.urlopen(request) as resp, open(part, "wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        got = 0
        while True:
            block = resp.read(chunk_size)
            if not block:
                break
            out.write(block)
            got += len(block)
            if total:
                pct = min(got * 100 // total, 100)
                sys.stdout.write(f"\r      {pct:3d}%  ({got >> 20} MB)")
                sys.stdout.flush()
    sys.stdout.write("\n")
    part.rename(dest)


def check_piper_models(check_only: bool, assume_yes: bool) -> bool:
    models = sorted(PIPER_MODELS_DIR.glob("*.onnx")) \
        if PIPER_MODELS_DIR.is_dir() else []
    if models:
        names = ", ".join(m.name for m in models)
        print(f"  [ok]      Piper voice models: {names}")
        return True
    print(f"  [missing] no Piper voice models in {PIPER_MODELS_DIR}")
    if check_only:
        return False
    question = (f"Download the default Piper voice '{PIPER_DEFAULT_VOICE}'"
                f" (~63 MB) into {PIPER_MODELS_DIR}?")
    try:
        answer = input(question + " [y/N] ")
    except EOFError:
        answer = ""
    if not assume_yes and answer.strip().lower() not in ("y", "yes"):
        return False
    for url in piper_model_urls(PIPER_DEFAULT_VOICE):
        dest = PIPER_MODELS_DIR / url.rsplit("/", 1)[-1]
        print(f"      downloading {url}")
        try:
            download_file(url, dest)
        except Exception as exc:  # noqa: BLE001: report any network failure
            print(f"      download failed: {exc}")
            if dest.exists():
                dest.unlink()
            return False
    print("  [ok]      Piper voice model downloaded")
    return True


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Demo Maker environment doctor")
    parser.add_argument("--check", action="store_true",
                        help="report only, no prompts or installs")
    parser.add_argument("--yes", action="store_true",
                        help="assume yes for every prompt")
    args = parser.parse_args(argv)

    print(f"Demo Maker doctor  (python {platform.python_version()},"
          f" {platform.system()} {platform.release()})")

    applicable = [c for c in CHECKS if c.applies()]
    missing: List[Check] = []
    for check in applicable:
        path = check.find()
        if path:
            print(f"  [ok]      {check.title}: {path}")
        elif check.required:
            print(f"  [MISSING] {check.title}  (required: {check.why})")
            missing.append(check)
        else:
            print(f"  [missing] {check.title}  (optional: {check.why})")
            missing.append(check)

    still_missing = offer_installs(missing, args.check, args.yes)

    models_ok = check_piper_models(args.check, args.yes)
    if args.check and not models_ok:
        # informational only; a model is needed just for the Piper engine
        pass

    if still_missing:
        req_names = ", ".join(c.title for c in still_missing if c.required)
        opt_names = ", ".join(c.title for c in still_missing if not c.required)
        if req_names:
            print(f"\nResult: REQUIRED tools still missing: {req_names}")
            print("Install them, then re-run: ./setup.sh --check")
        else:
            print(f"\nResult: ready (optional extras not installed: {opt_names})")
            if not models_ok:
                print("Note: without a Piper voice model only the 'say'"
                      " engine can narrate.")
        return 1 if req_names else 0
    print("\nResult: all required tools present. Launch with: ./run.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
