#!/usr/bin/env python3
"""Production CLI display and prompt behavior using only synthetic inputs."""
import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HARNESS = os.path.abspath(sys.argv[1])
sys.argv = sys.argv[:1]


class CLITests(unittest.TestCase):
    def fixture_command(self, command, fixture):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            path.write_text(json.dumps(fixture))
            return subprocess.check_output([HARNESS, command, str(path)], text=True)

    def prompt(self, command, answer):
        master, slave = pty.openpty()
        child = subprocess.Popen([HARNESS, command], stdin=slave, stdout=slave, stderr=slave)
        output = bytearray()
        try:
            deadline = time.monotonic() + 5
            marker = b"[y/N] " if command == "confirm" else b"Choice: "
            while marker not in output:
                if time.monotonic() >= deadline or child.poll() is not None:
                    self.fail("prompt did not become ready: " + repr(output))
                if select.select([master], [], [], 0.05)[0]:
                    output.extend(os.read(master, 65536))
            os.write(master, answer)
            child.wait(timeout=3)
            while select.select([master], [], [], 0.05)[0]:
                output.extend(os.read(master, 65536))
            self.assertEqual(child.returncode, 0, output)
            return bytes(output)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            os.close(master)
            os.close(slave)

    def test_plan_distinguishes_users_and_duplicate_applications(self):
        rows = [dict(label="Test App", user=user, identifier="org.example.Test",
                     path=f"/Users/{user}/Test.app/Contents/MacOS/Test", path_status="Missing",
                     permission="Allowed", configuration=f"configuration-{user}")
                for user in ("alice", "bob")]
        plan = dict(volume_name="Test", volume_uuid="00000000-0000-0000-0000-000000000001",
                    created="2026-09-06T00:00:00Z", kind="cleanup", removed=rows)
        output = self.fixture_command("plan", plan)
        self.assertIn("1. Test App", output)
        self.assertIn("2. Test App", output)
        for row in rows:
            self.assertIn("User: " + row["user"], output)
            self.assertIn("Executable: " + row["path"], output)
            self.assertIn("Configuration: " + row["configuration"], output)
        self.assertEqual(output.count("Identifier: org.example.Test"), 2)
        self.assertIn("Path status at preparation: Missing", output)

    def test_human_output_escapes_invisible_text_and_preserves_unicode(self):
        values = ["网络 café", "\x1b]52;c;INJECT\x07", "x\u200ey\u202ez\u2060w\u061cq"]
        self.assertEqual(json.loads(self.fixture_command("sanitize", values)),
                         ["网络 café", r"\u001B]52;c;INJECT\u0007", r"x\u200Ey\u202Ez\u2060w\u061Cq"])

    def test_confirmation_accepts_explicit_yes_case_insensitively(self):
        for answer in (b"y\n", b"Y\n", b"YES\n", b" yes \n"):
            with self.subTest(answer=answer):
                self.assertIn(b"RESULT:yes", self.prompt("confirm", answer))

    def test_confirmation_defaults_to_no(self):
        for answer in (b"\n", b"n\n", b"yes please\n"):
            with self.subTest(answer=answer):
                self.assertIn(b"RESULT:no", self.prompt("confirm", answer))

    def test_menu_normalizes_case_and_whitespace(self):
        self.assertIn(b"RESULT:a", self.prompt("menu", b" A \n"))
        self.assertIn(b"RESULT:q", self.prompt("menu", b"Q\n"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
