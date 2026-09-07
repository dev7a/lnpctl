#!/usr/bin/env python3
"""Invariants for real keyed-plist values; synthetic fixtures contain no host data."""
import copy
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HARNESS = os.path.abspath(sys.argv[1])
sys.argv = sys.argv[:1]
UID = plistlib.UID


def fixture():
    objects = ["$null"]

    def add(value):
        objects.append(value)
        return UID(len(objects) - 1)

    config_class = add({"$classname": "NEConfiguration", "$classes": ["NEConfiguration", "NSObject"]})
    controller_class = add({"$classname": "NEPathController", "$classes": ["NEPathController", "NSObject"]})
    array_class = add({"$classname": "NSArray", "$classes": ["NSArray", "NSObject"]})
    rule_class = add({"$classname": "NEPathRule", "$classes": ["NEPathRule", "NSObject"]})
    identity = add("org.example.Test")
    path = add("/Users/example/Build/Test.app/Contents/MacOS/Test")
    rule = add({"$class": rule_class, "SigningIdentifier": identity, "Path": path,
                "MulticastPreferenceSet": True, "DenyMulticast": False,
                "UnrelatedOpaque": b"\x00\xff\x01", "ExtraFlag": True})
    keep = add({"$class": rule_class, "SigningIdentifier": identity, "Path": UID(0),
                "MulticastPreferenceSet": True, "DenyMulticast": True})
    default_id = add("PathRuleDefaultNonSystemIdentifier")
    default_rule = add({"$class": rule_class, "SigningIdentifier": default_id, "Path": UID(0),
                        "MulticastPreferenceSet": False, "DenyMulticast": True})
    arrays = []
    top = {"Version": 1, "Generation": 42}
    for user in ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]:
        array = add({"$class": array_class, "NS.objects": [default_rule, rule, keep]})
        arrays.append(array.data)
        controller = add({"$class": controller_class, "Rules": array, "Enabled": True})
        config = add({"$class": config_class,
                      "Name": add("com.apple.preferences.networkprivacy-" + user),
                      "PathController": controller, "RetainOtherSettings": b"opaque"})
        top[user] = config
    # A completely different configuration must survive the edit without interpretation.
    vpn = add({"$class": config_class, "Name": add("Example VPN"),
               "ConfigurationPayload": {"secret": b"test fixture", "Enabled": True}})
    top["33333333-3333-4333-8333-333333333333"] = vpn
    # An unreachable object that looks like an entry must not become selectable.
    add({"$class": config_class, "Name": add("com.apple.preferences.networkprivacy-44444444-4444-4444-8444-444444444444"),
         "PathController": UID(0)})
    return {"$archiver": "NSKeyedArchiver", "$version": 100000, "$top": top, "$objects": objects}, arrays


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.a, self.arrays = fixture()
        self.source = self.write(self.a)

    def write(self, value, name="input.plist"):
        path = self.root / name
        path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=False))
        return path

    def run_tool(self, *args, ok=True):
        p = subprocess.run([HARNESS, *map(str, args)], capture_output=True, text=True)
        self.assertEqual(p.returncode == 0, ok, p.stderr)
        return p

    def scan(self, path=None):
        return json.loads(self.run_tool("scan", path or self.source).stdout)

    def test_only_reachable_application_rules_are_selectable(self):
        rows = self.scan()
        self.assertEqual(len(rows), 4)
        self.assertEqual(len({r["token"] for r in rows}), 4)
        self.assertFalse(any(r["identifier"].startswith("PathRuleDefault") for r in rows))

    def test_one_user_one_duplicate_removed_every_other_value_preserved(self):
        rows = self.scan()
        result = self.root / "result.plist"
        self.run_tool("edit", self.source, result, rows[0]["token"])
        actual = plistlib.loads(result.read_bytes())
        expected = copy.deepcopy(self.a)
        del expected["$objects"][self.arrays[0]]["NS.objects"][1]
        self.assertEqual(actual, expected)
        self.assertEqual(len(self.scan(result)), 3)

    def test_multi_selection_across_users(self):
        rows = self.scan()
        result = self.root / "result.plist"
        self.run_tool("edit", self.source, result, rows[0]["token"], rows[3]["token"])
        expected = copy.deepcopy(self.a)
        del expected["$objects"][self.arrays[0]]["NS.objects"][1]
        del expected["$objects"][self.arrays[1]]["NS.objects"][2]
        self.assertEqual(plistlib.loads(result.read_bytes()), expected)

    def test_tokens_are_invalid_after_any_snapshot_change(self):
        token = self.scan()[0]["token"]
        self.a["$top"]["Generation"] += 1
        self.write(self.a)
        p = self.run_tool("edit", self.source, self.root / "result", token, ok=False)
        self.assertIn("does not match this snapshot", p.stderr)
        self.assertFalse((self.root / "result").exists())

    def test_duplicate_selection_rejected(self):
        token = self.scan()[0]["token"]
        self.run_tool("edit", self.source, self.root / "result", token, token, ok=False)

    def test_shared_rules_array_rejected(self):
        self.a["$top"]["AnotherReference"] = UID(self.arrays[0])
        self.write(self.a)
        token = self.scan()[0]["token"]
        p = self.run_tool("edit", self.source, self.root / "result", token, ok=False)
        self.assertIn("share an archive array", p.stderr)

    def test_shared_controller_across_users_rejected(self):
        configs = [self.a["$objects"][ref.data] for ref in self.a["$top"].values() if isinstance(ref, UID)]
        configs[1]["PathController"] = configs[0]["PathController"]
        self.write(self.a)
        rows = self.scan()
        self.assertEqual(len(rows), 4)
        for index in (0, 2):
            with self.subTest(index=index):
                p = self.run_tool("edit", self.source, self.root / "result", rows[index]["token"], ok=False)
                self.assertIn("share an archive configuration or path controller", p.stderr)
                self.assertFalse((self.root / "result").exists())

    def test_shared_controller_with_unrelated_configuration_rejected(self):
        configs = [self.a["$objects"][ref.data] for ref in self.a["$top"].values() if isinstance(ref, UID)]
        configs[2]["PathController"] = configs[0]["PathController"]
        self.write(self.a)
        p = self.run_tool("edit", self.source, self.root / "result", self.scan()[0]["token"], ok=False)
        self.assertIn("share an archive configuration or path controller", p.stderr)
        self.assertFalse((self.root / "result").exists())

    def test_nested_configuration_alias_rejected(self):
        refs = [ref for ref in self.a["$top"].values() if isinstance(ref, UID)]
        self.a["$objects"][refs[2].data]["OpaqueReference"] = {"nested": [refs[0]]}
        self.write(self.a)
        p = self.run_tool("edit", self.source, self.root / "result", self.scan()[0]["token"], ok=False)
        self.assertIn("share an archive configuration or path controller", p.stderr)
        self.assertFalse((self.root / "result").exists())

    def test_unselected_shared_controller_preserved_during_safe_edit(self):
        refs = [ref for ref in self.a["$top"].values() if isinstance(ref, UID)]
        self.a["$objects"][refs[2].data]["PathController"] = self.a["$objects"][refs[0].data]["PathController"]
        self.write(self.a)
        result = self.root / "result.plist"
        self.run_tool("edit", self.source, result, self.scan()[2]["token"])
        expected = copy.deepcopy(self.a)
        del expected["$objects"][self.arrays[1]]["NS.objects"][1]
        self.assertEqual(plistlib.loads(result.read_bytes()), expected)

    def test_shared_controller_mixed_with_safe_selection_rejected(self):
        refs = [ref for ref in self.a["$top"].values() if isinstance(ref, UID)]
        self.a["$objects"][refs[2].data]["PathController"] = self.a["$objects"][refs[0].data]["PathController"]
        self.write(self.a)
        rows = self.scan()
        self.run_tool("edit", self.source, self.root / "result", rows[0]["token"], rows[2]["token"], ok=False)
        self.assertFalse((self.root / "result").exists())

    def test_malformed_and_out_of_range_archives_fail(self):
        variants = []
        a = copy.deepcopy(self.a); a["$objects"][self.arrays[0]]["NS.objects"] = "bad"; variants.append(a)
        a = copy.deepcopy(self.a); a["$objects"].append({"bad": UID(99999)}); variants.append(a)
        a = copy.deepcopy(self.a); a["$version"] = 2; variants.append(a)
        a = copy.deepcopy(self.a); a["$objects"][6] = 3; variants.append(a)
        for i, a in enumerate(variants):
            with self.subTest(i=i): self.run_tool("scan", self.write(a, f"bad-{i}.plist"), ok=False)

    def test_permission_fields_must_be_recognized(self):
        self.a["$objects"][7]["DenyMulticast"] = "no"
        self.write(self.a)
        self.run_tool("scan", self.source, ok=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
