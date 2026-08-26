"""Step schema registry, validation, and atomic file IO for steps JSON."""
import json
import re
from pathlib import Path
from typing import Dict, List, Optional


def _f(name, ftype, required=False, default=None, options=None,
       help_text="", when=None):
    spec = {"name": name, "type": ftype, "required": required,
            "default": default, "help": help_text}
    if options is not None:
        spec["options"] = options
    if when is not None:
        spec["when"] = when
    return spec


_LAST_COMMAND = {"field": "source", "value": "last_command"}
_SCREEN = {"field": "source", "value": "screen"}

_NARRATION = [
    _f("narration", "multiline",
       help_text="text spoken over this step; dwell time matches its length"),
    _f("settle_ms", "int",
       help_text="ms to wait after the action before narration starts"),
]

ACTIONS: Dict[str, dict] = {
    "launch": {"label": "Launch app (force-stop then cold start)", "fields": []},
    "reopen": {"label": "Reopen app (foreground existing session)", "fields": []},
    "pm_clear": {"label": "Clear app data (logged-out state)", "fields": []},
    "tap_text": {"label": "Tap exact text", "fields": [
        _f("text", "text", True, help_text="exact uiautomator text to tap"),
        _f("nth", "int", False, 1, help_text="1-based match index"),
        _f("type", "text", False, help_text="text typed after the tap;"
           " supports {{TIMESTAMP}} and {{ENV:NAME}}"),
    ]},
    "tap_contains": {"label": "Tap substring match", "fields": [
        _f("text", "text", True, help_text="substring of the text to tap"),
        _f("nth", "int", False, 1),
        _f("type", "text", False),
    ]},
    "tap_contains_optional": {"label": "Tap substring (never fails)",
                              "fields": [
        _f("text", "text", True, help_text="tapped only when present;"
           " the step always succeeds"),
        _f("nth", "int", False, 1),
    ]},
    "tap_until_gone": {"label": "Tap until a watcher disappears", "fields": [
        _f("watch_for", "text", True,
           help_text="exact text that must disappear to move on"),
        _f("max_attempts", "int", False, 15),
        _f("interval_seconds", "num", False, 3),
    ]},
    "tap_desc": {"label": "Tap content description", "fields": [
        _f("desc", "text", True, help_text="exact content-desc value"),
        _f("nth", "int", False, 1),
    ]},
    "tap_left_of_contains": {"label": "Tap left of a label", "fields": [
        _f("text", "text", True, help_text="label text to anchor on"),
        _f("offset_x", "int", False, 59,
           help_text="pixels left of the label's edge (e.g. its checkbox)"),
        _f("nth", "int", False, 1),
    ]},
    "swipe_up_from_contains": {"label": "Swipe up from a label", "fields": [
        _f("text", "text", True),
        _f("delta_y", "int", False, 500, help_text="swipe distance in px"),
        _f("nth", "int", False, 1),
    ]},
    "swipe_element": {"label": "Swipe from an element", "fields": [
        _f("text", "text", True,
           help_text="substring anchor; the swipe starts at this element's "
                     "center so it lands inside the right container"),
        _f("direction", "select", False, "up",
           ["up", "down", "left", "right"]),
        _f("delta", "int", False, 500, help_text="swipe distance in px"),
        _f("nth", "int", False, 1),
    ]},
    "drag_and_drop": {"label": "Drag element onto a target", "fields": [
        _f("from_text", "text", True,
           help_text="substring locating the dragged element"),
        _f("from_nth", "int", False, 1),
        _f("to_text", "text", False,
           help_text="drop target: substring of its text"),
        _f("to_desc", "text", False,
           help_text="or drop target: exact content-desc"),
        _f("x", "int", False, help_text="or raw drop coordinates; needs y too"),
        _f("y", "int", False),
        _f("to_nth", "int", False, 1),
        _f("duration_ms", "int", False, 800, help_text="drag length in ms"),
    ]},
    "swipe_until_contains": {"label": "Scroll until text visible", "fields": [
        _f("text", "text", True),
        _f("max_swipes", "int", False, 6),
        _f("nth", "int", False, 1),
    ]},
    "tap_xy": {"label": "Tap raw coordinates (last resort)", "fields": [
        _f("x", "int", True), _f("y", "int", True),
        _f("type", "text", False),
    ]},
    "long_press": {"label": "Long press (hold)", "fields": [
        _f("text", "text", False, help_text="exact uiautomator text to press"),
        _f("contains", "text", False,
           help_text="substring of the text to press (used when text is absent)"),
        _f("desc", "text", False, help_text="exact content-desc to press"),
        _f("x", "int", False, help_text="raw coordinate press; needs y too"),
        _f("y", "int", False),
        _f("nth", "int", False, 1),
        _f("duration_ms", "int", False, 1000,
           help_text="hold length; keep >= ~600 so the hold clears the "
                     "~500ms long-click timeout"),
    ]},
    "double_tap": {"label": "Double tap", "fields": [
        _f("text", "text", False, help_text="exact uiautomator text to tap"),
        _f("contains", "text", False,
           help_text="substring of the text to tap (used when text is absent)"),
        _f("desc", "text", False, help_text="exact content-desc to tap"),
        _f("x", "int", False, help_text="raw coordinate tap; needs y too"),
        _f("y", "int", False),
        _f("nth", "int", False, 1),
    ]},
    "back": {"label": "Back button", "fields": []},
    "home_button": {"label": "Home button", "fields": []},
    "dismiss_keyboard": {"label": "Dismiss keyboard", "fields": []},
    "pause": {"label": "Pause (narration provides dwell)", "fields": []},
    "swipe": {"label": "Swipe screen center (any direction)", "fields": [
        _f("direction", "select", True, "up", ["up", "down", "left", "right"]),
        _f("duration_ms", "int", False, 400, help_text="gesture speed in ms"),
    ]},
    "assert_text": {"label": "Assert text appears (guards progress)",
                    "fields": [
        _f("text", "text", True),
        _f("nth", "int", False, 1),
    ]},
    "exec": {"label": "Run host command", "fields": [
        _f("command", "multiline", True,
           help_text="runs locally; {{TIMESTAMP}} and {{ENV:NAME}} supported;"
                     " DEMO_* env vars exported"),
        _f("shell", "select", False, "bash", ["bash", "sh", "lambda"],
           help_text="lambda runs the text as a jq filter with null input"),
        _f("on_fail", "select", False, "stop", ["stop", "continue"]),
    ]},
    "if": {"label": "Conditional sub-context", "fields": [
        _f("source", "select", False, "last_command",
           ["last_command", "screen"]),
        _f("expect", "select", False, "success", ["success", "fail"],
           when=_LAST_COMMAND),
        _f("output_equals", "text", False, when=_LAST_COMMAND),
        _f("output_matches", "text", False, when=_LAST_COMMAND,
           help_text="extended regex against captured stdout"),
        _f("text", "text", False, when=_SCREEN,
           help_text="on-screen text to poll for"),
        _f("text_match", "select", False, "contains", ["contains", "exact"],
           when=_SCREEN),
        _f("equals", "text", False, when=_SCREEN),
        _f("matches", "text", False, when=_SCREEN),
        _f("timeout_seconds", "int", False, 8, when=_SCREEN),
        _f("then", "steps", help_text="run when the condition holds"),
        _f("else", "steps", help_text="run when it fails"),
    ]},
}

_NUM_RE = re.compile(r"^-?\d+(\.\d+)?$")
_INT_RE = re.compile(r"^-?\d+$")

# Narration applies to every action; attach it once here so the editor forms
# always offer it (the spec registry strips the narration field, since spec
# runs never speak).
for _action in ACTIONS.values():
    _action["fields"].extend(_NARRATION)


def _given(value) -> bool:
    """A field the user actually filled in (None and blank both mean no)."""
    return value is not None and str(value).strip() != ""


def _xy_state(step) -> str:
    """"both", "half", or "none": how completely x/y are filled in."""
    has_x, has_y = _given(step.get("x")), _given(step.get("y"))
    if has_x and has_y:
        return "both"
    if has_x or has_y:
        return "half"
    return "none"


def _require_xy_pair(step, path, errors) -> bool:
    if _xy_state(step) == "half":
        errors.append({"path": path,
                       "message": "'x' and 'y' must be given together"})
        return False
    return True


def _validate_gesture_locator(step, action, path, errors):
    anchors = [f for f in ("text", "contains", "desc")
               if _given(step.get(f))]
    has_point = _require_xy_pair(step, path, errors) \
        and _xy_state(step) == "both"
    if not anchors and not has_point:
        errors.append({"path": path,
                       "message": "%s needs 'text', 'contains', 'desc', "
                                  "or 'x'+'y'" % action})


def _validate_drop_target(step, path, errors):
    if not _require_xy_pair(step, path, errors):
        return
    targets = [f for f in ("to_text", "to_desc") if _given(step.get(f))]
    if _xy_state(step) == "both":
        targets.append("x+y")
    if len(targets) > 1:
        errors.append({"path": path,
                       "message": "give only one of 'to_text', 'to_desc', "
                                  "or 'x'+'y'"})
    elif not targets:
        errors.append({"path": path,
                       "message": "drag_and_drop needs a drop target: "
                                  "'to_text', 'to_desc', or 'x'+'y'"})


class StepError(Exception):
    pass


def validate_steps(steps, registry=None) -> List[dict]:
    """Return a list of {path, message} issues; empty means valid.

    registry defaults to ACTIONS; spec.py passes its own registry for
    scenario files (a different action vocabulary).
    """
    errors: List[dict] = []
    if not isinstance(steps, list):
        return [{"path": "", "message": "steps document must be a JSON array"}]
    _validate_array(steps, "", errors, registry or ACTIONS)
    return errors


def _validate_array(arr, prefix, errors, registry):
    for idx, step in enumerate(arr):
        path = "%s[%d]" % (prefix, idx)
        _validate_step(step, path, errors, registry)


def _validate_step(step, path, errors, registry):
    def fail(message):
        errors.append({"path": path, "message": message})

    if not isinstance(step, dict):
        fail("step must be an object")
        return
    action = step.get("action")
    if action not in registry:
        fail("unknown action %r" % (action,))
        return

    spec = registry[action]["fields"]
    for field_spec in spec:
        name = field_spec["name"]
        ftype = field_spec["type"]
        if ftype == "steps":
            continue
        value = step.get(name)
        missing = value is None or (isinstance(value, str) and not value.strip())
        if field_spec.get("required") and missing:
            fail("missing required field '%s'" % name)
            continue
        if missing:
            continue
        if ftype in ("int", "num"):
            ok = _INT_RE.match(str(value).strip()) if ftype == "int" \
                else _NUM_RE.match(str(value).strip())
            if not ok:
                fail("field '%s' must be a number (got %r)" % (name, value))
        elif ftype == "select":
            opts = field_spec.get("options") or []
            if str(value) not in opts:
                fail("field '%s' must be one of %s (got %r)"
                     % (name, "|".join(opts), value))

    if action == "exec" and isinstance(step.get("command"), str) \
            and step.get("shell") == "sh":
        pass  # sh accepts anything bash does for our purposes

    if action in ("long_press", "double_tap"):
        _validate_gesture_locator(step, action, path, errors)

    if action == "drag_and_drop":
        # from_text is a required field; the generic loop above already
        # reports it missing. This check covers the drop-target half.
        _validate_drop_target(step, path, errors)

    if action == "if":
        source = str(step.get("source") or "last_command")
        if source == "screen" and not str(step.get("text") or "").strip():
            fail("source=screen requires 'text'")
        branches_ok = False
        for branch in ("then", "else"):
            subtree = step.get(branch)
            if isinstance(subtree, list) and subtree:
                branches_ok = True
                _validate_array(subtree, path + "." + branch, errors, registry)
            elif subtree not in (None, []) and not isinstance(subtree, list):
                fail("'%s' must be an array of steps" % branch)
        if not branches_ok:
            fail("an if step needs a non-empty 'then' or 'else'")


def load_steps_file(path: str):
    try:
        raw = Path(path).read_text()
    except OSError as exc:
        raise StepError("cannot read %s: %s" % (path, exc))
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise StepError("%s is not valid JSON: %s" % (path, exc))
    if not isinstance(doc, list):
        raise StepError("%s must contain a JSON array of steps" % path)
    return doc


def save_steps_file(path: str, steps) -> List[dict]:
    """Validate, then write atomically (tmp file + rename). Returns errors."""
    errors = validate_steps(steps)
    if errors:
        return errors
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(steps, indent=2) + "\n")
    tmp.rename(target)
    return []


def default_step(action: str) -> Optional[dict]:
    """A fresh step skeleton pre-filled with schema defaults."""
    if action not in ACTIONS:
        return None
    step = {"action": action}
    for field_spec in ACTIONS[action]["fields"]:
        if field_spec["type"] == "steps":
            continue
        if field_spec["default"] is not None:
            step[field_spec["name"]] = field_spec["default"]
    if action == "launch":
        step.setdefault("narration", "Opening the app")
    return step


def schema() -> dict:
    """The registry itself, JSON-ready for the editor UI."""
    return ACTIONS
