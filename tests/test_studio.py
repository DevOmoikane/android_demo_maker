"""Unit tests for the Demo Maker studio backend (stdlib unittest)."""
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from demo_maker import adb, config, doctor, runner, steps, spec, tts  # noqa: E402

PROJECT = Path(__file__).resolve().parent.parent


class StepsValidationTests(unittest.TestCase):
    def test_example_file_is_valid(self):
        doc = steps.load_steps_file(str(PROJECT / "example-steps.json"))
        self.assertEqual([], steps.validate_steps(doc))

    def test_not_a_list(self):
        errors = steps.validate_steps({"action": "launch"})
        self.assertTrue(any("array" in e["message"] for e in errors))

    def test_unknown_action(self):
        errors = steps.validate_steps([{"action": "teleport"}])
        self.assertEqual("[0]", errors[0]["path"])
        self.assertIn("unknown action", errors[0]["message"])

    def test_required_field_missing(self):
        errors = steps.validate_steps([{"action": "tap_text"}])
        self.assertIn("missing required field 'text'", errors[0]["message"])

    def test_numeric_field_type(self):
        errors = steps.validate_steps(
            [{"action": "tap_xy", "x": "left", "y": 10}])
        self.assertIn("must be a number", errors[0]["message"])

    def test_if_screen_requires_text(self):
        errors = steps.validate_steps(
            [{"action": "if", "source": "screen",
              "then": [{"action": "back"}]}])
        self.assertTrue(any("requires 'text'" in e["message"] for e in errors))

    def test_if_needs_branch(self):
        errors = steps.validate_steps([{"action": "if"}])
        self.assertTrue(any("then' or 'else'" in e["message"] for e in errors))

    def test_nested_branch_paths(self):
        doc = [{"action": "if", "source": "last_command",
                "then": [{"action": "nope"}]}]
        errors = steps.validate_steps(doc)
        self.assertEqual("[0].then[0]", errors[0]["path"])

    def test_save_rejects_invalid(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "x.json"
            errors = steps.save_steps_file(str(target), [{"action": "bogus"}])
            self.assertTrue(errors)
            self.assertFalse(target.exists())

    def test_save_atomic_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "sub" / "x.json"
            doc = [{"action": "pause", "narration": "hi"}]
            errors = steps.save_steps_file(str(target), doc)
            self.assertEqual([], errors)
            self.assertFalse(target.with_name("x.json.tmp").exists())
            self.assertEqual(doc, steps.load_steps_file(str(target)))

    def test_default_step_prefills_defaults(self):
        step = steps.default_step("tap_until_gone")
        self.assertEqual(15, step["max_attempts"])
        self.assertIsNone(steps.default_step("nonexistent"))

    def test_long_press_requires_a_locator(self):
        errors = steps.validate_steps([{"action": "long_press"}])
        self.assertTrue(any("needs 'text'" in e["message"] for e in errors))

    def test_double_tap_half_point_rejected(self):
        errors = steps.validate_steps(
            [{"action": "double_tap", "x": 5}])
        self.assertTrue(any("together" in e["message"] for e in errors))

    def test_long_press_accepts_each_locator(self):
        for step in ({"action": "long_press", "text": "Hi"},
                     {"action": "long_press", "contains": "Hi"},
                     {"action": "long_press", "desc": "icon"},
                     {"action": "long_press", "x": 5, "y": 6}):
            self.assertEqual([], steps.validate_steps([step]))

    def test_swipe_directions(self):
        for direction in ("up", "down", "left", "right"):
            doc = [{"action": "swipe", "direction": direction}]
            self.assertEqual([], steps.validate_steps(doc))
        errors = steps.validate_steps([{"action": "swipe",
                                        "direction": "sideways"}])
        self.assertTrue(any("must be one of" in e["message"]
                            for e in errors))

    def test_swipe_element_requires_anchor_text(self):
        errors = steps.validate_steps([{"action": "swipe_element"}])
        self.assertIn("missing required field 'text'",
                      errors[0]["message"])

    def test_drag_and_drop_needs_exactly_one_target(self):
        base = {"action": "drag_and_drop", "from_text": "card"}
        errors = steps.validate_steps([dict(base)])
        self.assertTrue(any("drop target" in e["message"] for e in errors))
        errors = steps.validate_steps([dict(base, to_text="Trash",
                                            to_desc="trash")])
        self.assertTrue(any("only one" in e["message"] for e in errors))
        for target in ({"to_text": "Trash"}, {"to_desc": "trash"},
                       {"x": 10, "y": 20}):
            self.assertEqual([], steps.validate_steps([dict(base, **target)]))

    def test_gestures_available_for_spec_scenarios(self):
        for action in ("long_press", "double_tap", "swipe_element",
                       "drag_and_drop"):
            self.assertIn(action, spec.SPEC_ACTIONS)


class TtsParsingTests(unittest.TestCase):
    FIXTURE = (
        "Samantha          en_US    # Hello, my name is Samantha.\n"
        "Bad News          en_US    # The light you see\n"
        "Amelie            fr_CA    # Bonjour, je m'appelle Amelie.\n"
        "Thomas            fr_FR\n"                      # no sample phrase
        "Available voices:\n"
        "\n"
    )

    def test_parse_say_output(self):
        voices = tts.parse_say_voices(self.FIXTURE)
        by_name = {v["name"]: v for v in voices}
        self.assertEqual({"Samantha", "Bad News", "Amelie", "Thomas"},
                         set(by_name))
        self.assertEqual("en_US", by_name["Bad News"]["locale"])
        self.assertEqual("The light you see", by_name["Bad News"]["sample"])
        self.assertEqual("", by_name["Thomas"]["sample"])

    def test_piper_voices_scan(self):
        models = tts.piper_voices({})
        names = [m["name"] for m in models]
        self.assertIn("en_US-hfc_female-medium", names)


class AdbParsingTests(unittest.TestCase):
    LIST_OUTPUT = (
        "List of devices attached\r\n"
        "1C021FDEE003CG         device usb:2-2 product:raven "
        "model:Pixel_6_Pro device:raven transport_id:2\r\n"
        "emulator-5554          offline\r\n"
    )

    def test_parse_devices(self):
        devs = adb._parse_devices(self.LIST_OUTPUT)
        self.assertEqual(2, len(devs))
        self.assertEqual("1C021FDEE003CG", devs[0]["serial"])
        self.assertEqual("device", devs[0]["state"])
        self.assertEqual("Pixel 6 Pro", devs[0]["model"])
        self.assertEqual("offline", devs[1]["state"])
        self.assertEqual("", devs[1]["model"])

    def test_resolve_activity_parsing(self):
        brief = ("priority=0 preferredOrder=0\r\n"
                 "  com.android.settings/.Settings\r\n")
        lines = [ln.strip() for ln in brief.replace("\r", "").splitlines()]
        activity = next((ln for ln in lines
                         if ln.startswith("com.android.settings/")), "")
        self.assertEqual("com.android.settings/.Settings", activity)


class DoctorTests(unittest.TestCase):
    def test_distro_families(self):
        cases = [
            ('ID=ubuntu\nID_LIKE=debian\n', "debian"),
            ('ID=fedora\n', "fedora"),
            ('ID=arch\n', "arch"),
            ('NAME="openSUSE Leap"\nID=opensuse-leap\n', "suse"),
            ('ID=nobara\nID_LIKE=fedora\n', "fedora"),
            ('', "generic"),
        ]
        for text, expected in cases:
            self.assertEqual(expected, doctor.linux_distro_family(text),
                             msg=text)

    def test_check_table_complete(self):
        keys = {c.key for c in doctor.CHECKS}
        self.assertLessEqual(
            {"adb", "jq", "ffmpeg", "ffprobe", "say", "piper"}, keys)


class CommandBuilderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.script = Path(self.tmp.name) / "android-demo.sh"
        self.script.write_text("#!/usr/bin/env bash\nexit 0\n")
        self.steps_file = Path(self.tmp.name) / "steps.json"
        self.steps_file.write_text("[]")

    def tearDown(self):
        self.tmp.cleanup()

    def base_settings(self, **over):
        settings = dict(config.DEFAULTS)
        settings.update({
            "script_path": str(self.script),
            "steps_path": str(self.steps_file),
            "serial": "SER1",
            "app_id": "com.example.app",
            "out_dir": self.tmp.name,
        })
        settings.update(over)
        return settings

    def argv_for(self, settings, mode="normal"):
        argv, errors = runner.build_argv(settings, mode)
        return argv, errors

    def test_errors_when_app_missing(self):
        _, errors = runner.build_argv(self.base_settings(app_id=""), "dry")
        self.assertTrue(any("app selected" in e for e in errors))

    def test_errors_when_script_missing(self):
        settings = self.base_settings(script_path="/nope/none.sh")
        _, errors = runner.build_argv(settings, "dry")
        self.assertTrue(any("not found" in e for e in errors))

    def test_minimal_command(self):
        argv, errors = self.argv_for(self.base_settings(), "dry")
        self.assertEqual([], errors)
        joined = " ".join(argv)
        self.assertIn("--dry-run", joined)
        self.assertIn("--app-id com.example.app", joined)
        self.assertIn("--serial SER1", joined)
        # defaults select the piper engine explicitly
        self.assertIn("--tts piper", joined)

    def test_say_flags(self):
        settings = self.base_settings(engine="say", voice="Ava", rate="200")
        joined = " ".join(self.argv_for(settings)[0])
        self.assertIn("--tts say", joined)
        self.assertIn("--voice Ava", joined)
        self.assertIn("--rate 200", joined)

    def test_piper_flags(self):
        settings = self.base_settings(
            engine="piper", piper_model="/m/v.onnx", piper_bin="/b/piper")
        joined = " ".join(self.argv_for(settings)[0])
        self.assertIn("--piper-model /m/v.onnx", joined)
        self.assertIn("--piper-bin /b/piper", joined)

    def test_none_engine_means_no_narration(self):
        settings = self.base_settings(engine="none")
        self.assertIn("--no-narration", " ".join(self.argv_for(settings)[0]))

    def test_out_name_gets_mp4_suffix(self):
        settings = self.base_settings(out_name="my demo")
        joined = " ".join(self.argv_for(settings)[0])
        self.assertIn("--out", joined)
        self.assertIn("my%20demo.mp4", " ".join(
            a.replace(" ", "%20") for a in self.argv_for(settings)[0]))
        self.assertTrue(joined.endswith(".mp4") or ".mp4" in joined)

    def test_empty_out_name_still_yields_file_path(self):
        # regression: a bare directory used to be passed as --out, which
        # ffmpeg only rejects after the whole recording is done
        settings = self.base_settings(out_name="")
        argv, errors = self.argv_for(settings)
        self.assertEqual([], errors)
        out = argv[argv.index("--out") + 1]
        self.assertTrue(out.startswith(self.tmp.name))
        self.assertTrue(out.endswith(".mp4"))
        self.assertIn("android-demo-", Path(out).name)

    def test_missing_out_dir_gets_created(self):
        settings = self.base_settings(
            out_dir=str(Path(self.tmp.name) / "deep" / "nested"),
            out_name="x.mp4")
        argv, errors = self.argv_for(settings)
        self.assertEqual([], errors)
        self.assertTrue(Path(argv[argv.index("--out") + 1]).parent.is_dir())

    def test_keep_workdir_flag(self):
        settings = self.base_settings(keep_workdir=True)
        self.assertIn("--keep-workdir", " ".join(self.argv_for(settings)[0]))


class SpecScenarioTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, doc):
        path = Path(self.tmp.name) / name
        path.write_text(json.dumps(doc, indent=2))
        return str(path)

    def test_registry_shape(self):
        for action in ("assert_text", "assert_contains", "assert_desc",
                       "assert_gone", "assert_checked", "wait_gone",
                       "tap_desc_contains", "seed_requests"):
            self.assertIn(action, spec.SPEC_ACTIONS)
        self.assertNotIn("tap_contains_optional", spec.SPEC_ACTIONS)

    def test_narration_fields(self):
        # every demo action offers narration + settle_ms
        for action in ("launch", "tap_text", "pause"):
            names = [f["name"] for f in steps.ACTIONS[action]["fields"]]
            self.assertIn("narration", names)
            self.assertIn("settle_ms", names)
        # spec actions keep settle_ms but never narration
        for action, meta in spec.SPEC_ACTIONS.items():
            names = [f["name"] for f in meta["fields"]]
            self.assertNotIn("narration", names)
            self.assertIn("settle_ms", names)

    def test_validate_doc_flags_bad_entries_with_index(self):
        good = [{"action": "back"}]
        path = self.write("doc.json", [
            {"name": "ok", "steps": good},
            {"_skipped": "S2"},
            {"name": "broken", "steps": [{"action": "nope"}]},
            {"what": "?"},
        ])
        doc = json.loads(Path(path).read_text())
        problems = spec.validate_doc(doc)
        paths = [p["path"] for p in problems]
        self.assertTrue(all(p.startswith("[") for p in paths), paths)
        self.assertTrue(any(p.startswith("[2]") for p in paths))
        self.assertTrue(any(p.startswith("[3]") for p in paths))
        self.assertTrue(
            all("ok" not in p["message"] or not p["path"].startswith("[0]")
                for p in problems))

    def test_validate_doc_accepts_placeholders(self):
        problems = spec.validate_doc([
            {"name": "s", "steps": []},
            {"_note": "just a note"},
        ])
        self.assertEqual([], problems)

    def test_inspect_kinds(self):
        path = self.write("mix.json", [
            {"name": "S1", "steps": [{"action": "pause"}]},
            {"_skipped": "SPEC-02", "_why": "not built yet"},
            {"_blocked": "SPEC-03", "_why": "backend missing"},
            {"_note": "file caveat"},
        ])
        info = spec.inspect_file(path)
        self.assertEqual("", info["error"])
        kinds = [e["kind"] for e in info["entries"]]
        self.assertEqual(["scenario", "skipped", "skipped", "note"], kinds)
        self.assertEqual("SPEC-03", info["entries"][2]["skipped"])

    def test_inspect_invalid_entry(self):
        path = self.write("bad.json", [{"what": "?"}])
        info = spec.inspect_file(path)
        self.assertEqual("invalid", info["entries"][0]["kind"])
        self.assertTrue(info["entries"][0]["errors"])

    def test_step_errors_use_spec_vocabulary(self):
        path = self.write("x.json", [
            {"name": "ok", "steps": [{"action": "assert_gone",
                                      "text": "Bye"}]},
            {"name": "demo-only action", "steps":
                [{"action": "tap_contains_optional", "text": "x"}]},
            {"name": "missing field", "steps": [{"action": "assert_gone"}]},
        ])
        entries = spec.inspect_file(path)["entries"]
        self.assertEqual([], entries[0]["errors"])
        self.assertTrue(any("unknown action" in e["message"]
                            for e in entries[1]["errors"]))
        self.assertTrue(any("'text'" in e["message"]
                            for e in entries[2]["errors"]))

    def test_scenario_needs_steps_array(self):
        path = self.write("y.json", [{"name": "no steps"}])
        entry = spec.inspect_file(path)["entries"][0]
        self.assertEqual("invalid", entry["kind"])
        self.assertTrue(any("'steps' must be an array" in m
                            for m in entry["errors"]))

    def test_summarize(self):
        files = [
            {"error": "", "entries": [
                {"kind": "scenario"}, {"kind": "skipped"},
                {"kind": "note"}]},
            {"error": "boom", "entries": []},
        ]
        totals = spec.summarize(files)
        self.assertEqual(1, totals["runnable"])
        self.assertEqual(1, totals["skipped"])
        self.assertEqual(1, totals["notes"])
        self.assertEqual(1, totals["error_files"])

    def test_list_files_sorted(self):
        Path(self.tmp.name, "b.json").write_text("[]")
        Path(self.tmp.name, "a.json").write_text("[]")
        Path(self.tmp.name, "skip.txt").write_text("nope")
        names = [p.name for p in
                 spec.list_scenario_files(self.tmp.name)]
        self.assertEqual(["a.json", "b.json"], names)

    def test_list_files_missing_dir(self):
        with self.assertRaises(spec.SpecError):
            spec.list_scenario_files("/nope/nothing")

    def base_settings(self, **over):
        settings = dict(config.DEFAULTS)
        settings.update({
            "spec_script": "./android-spec-test.sh",
            "spec_app_id": "com.example.app",
            "serial": "SER1",
            "spec_scenarios_dir": self.tmp.name,
        })
        settings.update(over)
        return settings

    def test_argv_minimal(self):
        argv, errors = spec.build_spec_argv(self.base_settings())
        self.assertEqual([], errors)
        self.assertIn("--app-id com.example.app", " ".join(argv))
        self.assertIn("--scenarios", " ".join(argv))

    def test_argv_extra_flags(self):
        argv, errors = spec.build_spec_argv(
            self.base_settings(spec_activity="com.example.app/.Main"),
            only="AUTH-01", report_path="/tmp/r.json")
        joined = " ".join(argv)
        self.assertEqual([], errors)
        self.assertIn("--activity com.example.app/.Main", joined)
        self.assertIn("--only AUTH-01", joined)
        self.assertIn("--report /tmp/r.json", joined)

    def test_argv_target_override(self):
        target = self.write("single.json", [])
        argv, errors = spec.build_spec_argv(self.base_settings(),
                                            target=target)
        self.assertEqual([], errors)
        self.assertIn(target, argv)

    def test_argv_errors(self):
        _, errors = spec.build_spec_argv(self.base_settings(
            spec_app_id="", serial="", spec_script="/nope.sh",
            spec_scenarios_dir="/gone"))
        self.assertEqual(4, len(errors))


class PiperCatalogTests(unittest.TestCase):
    def setUp(self):
        self.orig_cache = tts.CATALOG_CACHE_FILE
        self.tmp = tempfile.TemporaryDirectory()
        tts.CATALOG_CACHE_FILE = Path(self.tmp.name) / "piper-catalog.json"

    def tearDown(self):
        tts.CATALOG_CACHE_FILE = self.orig_cache
        self.tmp.cleanup()

    def test_entry_from_repo_dir(self):
        entry = tts._entry_from_repo_dir("en/en_US/amy/medium", 123)
        self.assertEqual("en_US-amy-medium", entry["key"])
        self.assertEqual("en_US", entry["locale"])
        self.assertEqual("medium", entry["quality"])
        self.assertEqual(123, entry["size_bytes"])
        self.assertEqual("en/en_US/amy/medium/en_US-amy-medium.onnx",
                         entry["relpath"])

    def test_entry_underscore_name(self):
        # en_US-hfc_female-medium: the voice name itself contains an _
        entry = tts._entry_from_tree_path(
            "en/en_US/hfc_female/medium/en_US-hfc_female-medium.onnx", 0)
        self.assertEqual("en_US-hfc_female-medium", entry["key"])

    def test_entry_rejects_junk(self):
        self.assertIsNone(tts._entry_from_repo_dir("en/en_US/amy"))
        self.assertIsNone(tts._entry_from_repo_dir("../etc/passwd/x"))
        self.assertIsNone(tts._entry_from_tree_path(
            "en/en_US/amy/medium/en_US-amy-medium.onnx.json", 0))
        self.assertIsNone(tts._entry_from_tree_path(
            "en/en_US/other/medium/en_US-amy-medium.onnx", 0))

    def test_catalog_cache_roundtrip_and_staleness(self):
        payload = {"source": "network", "fetched_at": time.time(),
                   "voices": [{"key": "k"}]}
        tts._write_catalog_cache(payload)
        fresh = tts._read_catalog_cache(max_age=3600)
        self.assertIsNotNone(fresh)
        old = dict(payload, fetched_at=time.time() - 100000)
        tts._write_catalog_cache(old)
        self.assertIsNone(tts._read_catalog_cache(max_age=3600))
        self.assertIsNotNone(tts._read_catalog_cache(max_age=None))

    def test_bundled_catalog_is_wellformed(self):
        data = tts._bundled_catalog()
        self.assertGreaterEqual(len(data["voices"]), 5)
        for voice in data["voices"]:
            self.assertNotIn("..", voice["relpath"])
            self.assertTrue(voice["relpath"].endswith(voice["key"] + ".onnx"))

    def test_unknown_key_rejected(self):
        with self.assertRaises(tts.TtsError):
            tts.start_voice_download("../../evil")

    def test_fetch_falls_back_when_offline(self):
        def boom(*a, **k):
            raise OSError("no network")
        orig_urlopen = tts.urllib.request.urlopen
        tts._write_catalog_cache({
            "source": "network",
            "fetched_at": time.time() - 200000,
            "voices": [{"key": "en_US-old-medium",
                        "locale": "en_US",
                        "name": "old",
                        "quality": "medium",
                        "size_bytes": 1,
                        "relpath":
                        "en/en_US/old/medium/en_US-old-medium.onnx"}]})
        try:
            tts.urllib.request.urlopen = boom
            data = tts.fetch_piper_catalog(force=True)
            self.assertEqual("cache", data["source"])
            self.assertEqual("en_US-old-medium", data["voices"][0]["key"])
            self.assertFalse(data["voices"][0]["installed"])
        finally:
            tts.urllib.request.urlopen = orig_urlopen


class RunnerReportTests(unittest.TestCase):
    def test_kind_defaults_to_demo(self):
        r = runner.Runner()
        status = r.status()
        self.assertEqual("demo", status["kind"])
        self.assertNotIn("spec_report", status)

    def test_report_parsed_once_done(self):
        r = runner.Runner()
        r.kind = "spec"
        r.exit_code = 0
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "r.json"
            good.write_text('{"summary": {"passed": 1}}')
            r.report_path = str(good)
            self.assertEqual({"summary": {"passed": 1}}, r.status()["spec_report"])
            good.write_text("{}")  # cached: not re-read on later polls
            self.assertEqual({"summary": {"passed": 1}},
                             r.status()["spec_report"])
            r._report_cache = None
            bad = Path(tmp) / "gone.json"
            r.report_path = str(bad)
            self.assertIn("error", r.status()["spec_report"])


class ConfigTests(unittest.TestCase):
    def test_defaults_present_and_typed(self):
        settings = config.load_settings()
        for key, value in config.DEFAULTS.items():
            self.assertIn(key, settings)
            if isinstance(value, bool):
                self.assertIsInstance(settings[key], bool)

    def test_update_scope_whitelist(self):
        updated = config.update_settings(
            {"scope": "all", "engine": "piper", "hacker_key": "x"})
        self.assertEqual("all", updated["scope"])
        self.assertNotIn("hacker_key", updated)
        config.update_settings({"scope": "user", "engine": "say"})


if __name__ == "__main__":
    unittest.main()
