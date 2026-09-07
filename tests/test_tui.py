#!/usr/bin/env python3
"""Exercise the real ncurses picker in a PTY; uses only Python's standard library.

Pass the path to a compiled tests/tui_harness executable as the sole argument.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import unittest


HARNESS = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else None
sys.argv = sys.argv[:1]


class Picker:
    def __init__(self, size=(24, 100), extra_env=None):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.resize(*size, signal_child=False)
        env = dict(os.environ, TERM="xterm-256color", LC_ALL="en_US.UTF-8")
        env.update(extra_env or {})
        self.child = subprocess.Popen([HARNESS], stdin=self.slave, stdout=self.slave,
                                      stderr=self.slave, env=env, start_new_session=True)
        self.output = bytearray()
        # Wait for an actual screen (or initialization error), not process startup.
        deadline = time.monotonic() + 5
        while not any(marker in self.output for marker in
                      (b"Local Network cleanup", b"Enlarge terminal", b"ERROR:")):
            if self.child.poll() is not None or time.monotonic() >= deadline:
                self.close()
                raise AssertionError("picker did not become ready: " + repr(bytes(self.output)))
            self.pump(0.05)

    def pump(self, duration=0.15):
        until = time.monotonic() + duration
        while time.monotonic() < until:
            if select.select([self.master], [], [], max(0, until - time.monotonic()))[0]:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.output.extend(chunk)
        return bytes(self.output)

    def send(self, keys):
        os.write(self.master, keys)
        self.pump()

    def resize(self, rows, columns, signal_child=True):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        if signal_child:
            self.child.send_signal(signal.SIGWINCH)
            self.pump()

    def finish(self):
        until = time.monotonic() + 3
        while self.child.poll() is None and time.monotonic() < until:
            self.pump(0.1)
        self.child.wait(timeout=0.1)
        self.pump(0.05)
        restored = termios.tcgetattr(self.slave)
        # macOS sets PENDIN itself when restoring canonical input; it is not a
        # user-controlled terminal mode and clears when pending input is read.
        restored[3] &= ~getattr(termios, "PENDIN", 0)
        original = self.original.copy()
        original[3] &= ~getattr(termios, "PENDIN", 0)
        if restored != original:
            raise AssertionError("picker did not restore terminal attributes")
        return bytes(self.output)

    def close(self):
        if self.child.poll() is None:
            self.child.kill()
            self.child.wait()
        os.close(self.master)
        os.close(self.slave)


class TUITests(unittest.TestCase):
    def picker(self, *args, **kwargs):
        picker = Picker(*args, **kwargs)
        self.addCleanup(picker.close)
        return picker

    def test_selection_filter_and_explicit_review_confirmation(self):
        p = self.picker()
        p.send(b" ")                  # token 00
        p.send(b"/application.79\n") # filter across identifier
        p.send(b" ")                  # token 79; token 00 remains selected
        self.assertIn(b"hidden", p.output)
        p.send(b"\n")                # review
        self.assertIn(b"selected;", p.output)
        p.send(b"\n")                # Enter must not prepare
        self.assertIsNone(p.child.poll())
        p.send(b"p")
        self.assertIn(b"RESULT:token-00,token-79", p.finish())

    def test_long_list_navigation_and_toggle(self):
        p = self.picker()
        p.send(b"\x1bOF ")            # End -> token 79
        p.send(b"\x1bOH \x1bOB ")   # Home -> 00; Down -> 01
        p.send(b" ")                  # deselect 01
        p.send(b"\n\x1bOFp")         # review End then prepare
        self.assertIn(b"RESULT:token-00,token-79", p.finish())

    def test_unicode_filter_cancel_and_controls_are_visible(self):
        p = self.picker()
        self.assertNotIn(b"\x1b]52;c;INJECT", p.output)
        self.assertIn(b"\\u001B", p.output)
        p.send("/网络\n ".encode())
        p.send(b"/nomatch\x1b")
        p.pump(1.2)  # ncurses distinguishes a standalone Escape from a key prefix
        p.send(b"\np")
        self.assertIn(b"RESULT:token-00", p.finish())

    def test_page_navigation_and_back_from_review(self):
        p = self.picker()
        p.send(b"\x1b[6~ \x1b[5~ ")  # PageDown selects 10; PageUp selects 00
        p.send(b"\n\x1b")             # return from review without preparation
        p.pump(1.2)
        self.assertIsNone(p.child.poll())
        p.send(b"\np")
        self.assertIn(b"RESULT:token-00,token-10", p.finish())

    def test_minimum_size_uses_compact_table(self):
        p = self.picker(size=(16, 40))
        p.send(b" \t\x1bOF")
        self.assertIn(b"Configuration", p.output)
        p.send(b"\np")
        self.assertIn(b"RESULT:token-00", p.finish())

    def test_resize_details_and_cancel_restores_terminal(self):
        p = self.picker(size=(18, 64), extra_env={"NO_COLOR": "1"})
        p.send(b" \t\x1bOF")         # select, focus details, end of long path
        self.assertIn(b"Configuration", p.output)
        p.resize(12, 30)
        self.assertIn(b"Enlarge terminal", p.output)
        p.resize(24, 100)
        p.send(b"q")
        self.assertIn(b"RESULT:cancel", p.finish())
        self.assertNotIn(b"\x1b[36m", p.output)

    def test_ctrl_c_restores_terminal(self):
        p = self.picker()
        p.child.send_signal(signal.SIGINT)
        self.assertIn(b"RESULT:cancel", p.finish())

    def test_empty_selection_does_not_prepare(self):
        p = self.picker()
        p.send(b"\np")
        self.assertIsNone(p.child.poll())
        # ncurses can retain the leading S from the previous hint.
        self.assertIn(b"entry with Space first.", p.output)
        p.send(b"q")
        self.assertIn(b"RESULT:cancel", p.finish())

    def test_initial_details_show_user_and_executable(self):
        p = self.picker()
        self.assertIn(b"User: example (501)", p.output)
        self.assertIn(b"Executable:", p.output)
        self.assertIn(b"/Users/example/Builds/", p.output)
        p.send(b"q")
        self.assertIn(b"RESULT:cancel", p.finish())

    def test_filter_controls_match_text_entry(self):
        p = self.picker()
        p.send(b" /q ")
        self.assertIn(b"Enter Keep  Esc Undo  Ctrl-U Clear", p.output)
        self.assertIn(b"Backspace Delete  Ctrl-C Cancel", p.output)
        self.assertIsNone(p.child.poll())  # q typed into a filter must not cancel.
        p.send(b"\x15application.79\n ")
        p.send(b"\np")
        self.assertIn(b"RESULT:token-00,token-79", p.finish())

    def test_narrow_review_explains_prepare_and_recovery(self):
        p = self.picker(size=(16, 40))
        p.send(b" \n")
        self.assertIn(b"p saves backup; permissions unchanged.", p.output)
        self.assertIn(b"Apply later from macOS Recovery.", p.output)
        p.send(b"q")
        self.assertIn(b"RESULT:cancel", p.finish())

    def test_narrow_hidden_selection_count_is_visible(self):
        p = self.picker(size=(16, 40))
        p.send(b" /application.79\n")
        self.assertIn(b"Selected 1 (1 hidden)", p.output)
        p.send(b"\np")
        self.assertIn(b"RESULT:token-00", p.finish())

    def test_unsupported_terminal_fails_cleanly(self):
        p = self.picker(extra_env={"TERM": "dumb"})
        self.assertIn(b"ERROR:The picker needs an interactive terminal", p.finish())
        self.assertEqual(p.child.returncode, 2)


if __name__ == "__main__":
    if not HARNESS:
        raise SystemExit("usage: test_tui.py /absolute/path/to/tui_harness")
    unittest.main()
