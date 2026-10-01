"""Spec-test scenarios: file inspection, validation, and argv building.

A scenario file is a JSON array whose entries are either runnable scenarios
{"name": str, "steps": [...]} or coverage placeholders with no "name":
{"_skipped": "...", "_why": "..."} or {"_note": "..."}. The runnable ones are
executed by android-spec-test.sh; placeholders only feed its coverage report.
"""
import json
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import steps as steps_mod


def _f(name, ftype, required=False, default=None, help_text=""):
    return {"name": name, "type": ftype, "required": required,
            "default": default, "help": help_text}


def _demo_action(action_spec: dict) -> dict:
    """Copy a demo action for scenario use; narration is never spoken here."""
    fields = [f for f in action_spec["fields"] if f["name"] != "narration"]
    return dict(action_spec, fields=fields)


# The spec script's own action vocabulary: everything android-demo.sh drives
# except narration-only conveniences it does not implement, plus its assertion
# set. Keep field names in sync with android-spec-test.sh's perform_action().
SPEC_ACTIONS: Dict[str, dict] = {
    key: _demo_action(value) for key, value in steps_mod.ACTIONS.items()
    if key != "tap_contains_optional"
}

SPEC_ACTIONS.update({
    "tap_desc_contains": {"label": "Tap content-desc substring", "fields": [
        _f("text", "text", True,
           help_text="substring of the content-desc to tap"),
        _f("nth", "int", False, 1),
    ]},
    "assert_signed_in": {"label": "Assert signed-in nav destinations",
                         "fields": []},
    "assert_text_eventually": {
        "label": "Assert exact text appears (polling)", "fields": [
            _f("text", "text", True),
            _f("nth", "int", False, 1),
            _f("max_attempts", "int", False, 25,
               help_text="poll attempts before failing"),
            _f("interval_seconds", "num", False, 0.8),
        ]},
    "assert_contains": {"label": "Assert substring visible now", "fields": [
        _f("text", "text", True),
        _f("nth", "int", False, 1),
    ]},
    "assert_desc": {"label": "Assert exact content-desc visible",
                    "fields": [
        _f("desc", "text", True),
        _f("nth", "int", False, 1),
    ]},
    "seed_requests": {"label": "Seed website-access requests "
                                "(app-specific)", "fields": [
        _f("child_id", "text", True,
           help_text="child to seed requests for; needs SEED_REQUESTS_SCRIPT"),
        _f("domains", "strings", False,
           help_text="domains to request approval for"),
    ]},
    "assert_desc_contains": {
        "label": "Assert content-desc contains (polling)", "fields": [
            _f("text", "text", True,
               help_text="substring of a content-desc that must appear"),
            _f("nth", "int", False, 1),
            _f("max_attempts", "int", False, 25),
            _f("interval_seconds", "num", False, 0.8),
        ]},
    "assert_gone": {"label": "Assert exact text absent", "fields": [
        _f("text", "text", True),
    ]},
    "assert_contains_gone": {"label": "Assert substring absent", "fields": [
        _f("text", "text", True),
        _f("nth", "int", False, 1),
    ]},
    "assert_checked": {"label": "Assert toggle checked", "fields": [
        _f("text", "text", False, help_text="locate by exact text"),
        _f("desc", "text", False, help_text="or locate by content-desc"),
        _f("nth", "int", False, 1),
    ]},
    "assert_unchecked": {"label": "Assert toggle unchecked", "fields": [
        _f("text", "text", False),
        _f("desc", "text", False),
        _f("nth", "int", False, 1),
    ]},
    "wait_gone": {"label": "Wait until text disappears", "fields": [
        _f("text", "text", True,
           help_text="e.g. a progress indicator that must clear"),
        _f("max_attempts", "int", False, 20),
        _f("interval_seconds", "num", False, 3),
    ]},
})

# The runner honors settle_ms on every step; make it editable everywhere.
# Device needs the same treatment. SPEC_ACTIONS is built in two parts: copied
# from steps.ACTIONS, which already picked up the shared device field, then
# extended by the block above, whose actions never passed through that loop.
# Attach it here too or those actions accept any value silently and the editor
# draws no field to fix it with. Reuse the spec object from steps rather than
# rebuilding it: this file's own _f takes no options, so a local copy would
# lose the ["1", "2"] that validation checks against.
for _spec_action in SPEC_ACTIONS.values():
    if all(f["name"] != "settle_ms" for f in _spec_action["fields"]):
        _spec_action["fields"].append(
            _f("settle_ms", "int",
               help_text="ms to wait after this step before the next one"))
    if all(f["name"] != "device" for f in _spec_action["fields"]):
        _spec_action["fields"].append(steps_mod._DEVICE_FIELD)


class SpecError(Exception):
    pass


def list_scenario_files(dir_path: str) -> List[Path]:
    root = Path(dir_path).expanduser()
    if not root.is_dir():
        raise SpecError("scenarios directory not found: %s" % root)
    return sorted(root.glob("*.json"), key=lambda p: p.name.lower())


def inspect_file(path) -> dict:
    """One scenario file summarized for the UI, with per-entry errors."""
    info: dict = {"file": Path(path).name, "path": str(path),
                  "entries": [], "error": ""}
    try:
        raw = Path(path).read_text()
    except OSError as exc:
        info["error"] = "cannot read: %s" % exc
        return info
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        info["error"] = "not valid JSON: %s" % exc
        return info
    if not isinstance(doc, list):
        info["error"] = "top level must be a JSON array of scenarios"
        return info
    for index, entry in enumerate(doc):
        info["entries"].append(_inspect_entry(entry, index))
    return info


def _inspect_entry(entry, index: int) -> dict:
    item = {"index": index, "kind": "scenario", "name": "",
            "skipped": "", "why": "", "step_count": 0, "errors": []}
    if not isinstance(entry, dict):
        item["kind"] = "invalid"
        item["errors"].append("entry must be an object")
        return item
    if "name" in entry:
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            item["kind"] = "invalid"
            item["errors"].append("'name' must be a non-empty string")
            name = ""
        item["name"] = name
        step_list = entry.get("steps")
        if not isinstance(step_list, list):
            item["kind"] = "invalid"
            item["errors"].append("'steps' must be an array")
            return item
        item["step_count"] = len(step_list)
        item["errors"] += steps_mod.validate_steps(step_list, SPEC_ACTIONS)
        return item
    # Coverage placeholder, matching android-spec-test.sh: any entry without
    # a "name" is never executed. Recognized spellings: _skipped (also
    # _blocked) with an optional _why reason, or a file-level _note.
    label = entry.get("_skipped", entry.get("_blocked"))
    note = entry.get("_note")
    if label is None and note is None:
        item["kind"] = "invalid"
        item["errors"].append(
            "entry needs 'name' (runnable) or '_skipped'/'_note' "
            "(placeholder)")
        return item
    item["kind"] = "note" if label is None else "skipped"
    item["skipped"] = "" if label is None else str(label)
    item["why"] = str(entry.get("_why") or note or "")
    return item


def validate_doc(doc) -> List[dict]:
    """Validate a whole scenario file; returns [{path, message}] issues.

    Paths are entry-indexed ("[2] name: ...") so a 422 banner can point at
    the offending scenario even though the editor shows one entry at a time.
    """
    if not isinstance(doc, list):
        return [{"path": "", "message": "scenario file must be a JSON array"}]
    problems: List[dict] = []
    for index, entry in enumerate(doc):
        info = _inspect_entry(entry, index)
        tag = "[%d]" % index
        label = info.get("name") or info.get("skipped") or info["kind"]
        for issue in info["errors"]:
            if isinstance(issue, dict):
                problems.append({
                    "path": "%s%s" % (tag, issue.get("path", "")),
                    "message": "%s: %s" % (label, issue["message"]),
                })
            else:
                problems.append(
                    {"path": tag, "message": "%s: %s" % (label, issue)})
    return problems


def summarize(files_info: List[dict]) -> dict:
    totals = {"files": len(files_info), "scenarios": 0, "runnable": 0,
              "skipped": 0, "notes": 0, "invalid": 0, "error_files": 0}
    for info in files_info:
        if info["error"]:
            totals["error_files"] += 1
        for entry in info["entries"]:
            if entry["kind"] == "scenario":
                totals["scenarios"] += 1
                totals["runnable"] += 1
            elif entry["kind"] == "skipped":
                totals["skipped"] += 1
            elif entry["kind"] == "note":
                totals["notes"] += 1
            else:
                totals["invalid"] += 1
    return totals


def build_spec_argv(settings: dict, target: Optional[str] = None,
                    only: Optional[str] = None,
                    report_path: Optional[str] = None) -> Tuple[list, list]:
    """Translate settings into an android-spec-test.sh invocation.

    Returns (argv, errors); errors is non-empty when required pieces are
    missing or paths do not exist.
    """
    errors = []
    script = str(settings.get("spec_script") or "").strip()
    if not script or not Path(script).is_file():
        errors.append("android-spec-test.sh not found: %s"
                      % (script or "<unset>"))

    app_id = str(settings.get("spec_app_id") or "").strip()
    if not app_id:
        errors.append("no app id set for spec tests")

    serial = str(settings.get("serial") or "").strip()
    if not serial:
        errors.append("no device selected")

    if settings.get("second_device"):
        serial_2 = str(settings.get("serial_2") or "").strip()
        if not serial_2:
            errors.append("second device enabled but no second serial selected")
        elif serial_2 == serial:
            errors.append("second device is the same device as the main one")

    where = str(target if target is not None
                else settings.get("spec_scenarios_dir") or "").strip()
    if not where or not Path(where).expanduser().exists():
        errors.append("scenarios location not found: %s" % (where or "<unset>"))
    else:
        where = str(Path(where).expanduser())

    if errors:
        return [], errors

    argv = [script, "--app-id", app_id, "--serial", serial,
            "--scenarios", where]
    activity = str(settings.get("spec_activity") or "").strip()
    if activity:
        argv += ["--activity", activity]
    if settings.get("second_device"):
        # --app-id-2 and --activity-2 fall back to the primary, as in
        # runner.build_argv. No --compose-height here: spec runs record
        # nothing, so there is no composite to size.
        argv += ["--serial-2", str(settings.get("serial_2") or "").strip(),
                 "--app-id-2",
                 str(settings.get("app_id_2") or "").strip() or app_id]
        activity_2 = str(settings.get("activity_2") or "").strip() or activity
        if activity_2:
            argv += ["--activity-2", activity_2]
    if only:
        argv += ["--only", only]
    if report_path:
        argv += ["--report", report_path]
    return argv, []
