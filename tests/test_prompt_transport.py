"""A prompt that does not fit on the command line travels on stdin.

The limits differ by platform and are counted differently: Linux caps one argv
element at 128 KiB in bytes, Windows caps the whole command line at 32,767
UTF-16 code units. With the Linux number on Windows, a translation prompt
(the whole source file) fails before the CLI starts, with WinError 206.
"""
import os
import subprocess
import sys
import unittest

from teach.core.generator import AGENT_COMMANDS, _prompt_on_stdin


class PromptTransportTest(unittest.TestCase):
    def test_small_prompt_stays_on_argv_everywhere(self):
        self.assertFalse(_prompt_on_stdin("x" * 1000, platform="posix"))
        self.assertFalse(_prompt_on_stdin("x" * 1000, platform="nt"))

    def test_windows_limit_is_far_below_the_linux_one(self):
        prompt = "x" * 40_000
        self.assertFalse(_prompt_on_stdin(prompt, platform="posix"))
        self.assertTrue(_prompt_on_stdin(prompt, platform="nt"))

    def test_linux_counts_bytes(self):
        # 60k two-byte characters: 120 KB, over the Linux limit.
        self.assertTrue(_prompt_on_stdin("ñ" * 60_000, platform="posix"))

    def test_windows_counts_utf16_units(self):
        # 16,100 astral characters are 32,200 UTF-16 units, over the Windows limit,
        # although they are only 16,100 Python characters.
        self.assertTrue(_prompt_on_stdin("\U0001F600" * 16_100, platform="nt"))
        self.assertFalse(_prompt_on_stdin("ñ" * 16_100, platform="nt"))

    def test_windows_counts_the_escaped_command_line(self):
        # list2cmdline quotes the argument and turns each " into \": 20,000
        # characters with 13,000 quotes become over 33,000 units on the line.
        prompt = '"' * 13_000 + "x" * 7_000
        self.assertTrue(_prompt_on_stdin(prompt, platform="nt"))
        self.assertFalse(_prompt_on_stdin("x" * 20_000, platform="nt"))

    def test_the_command_counts_too(self):
        # The flags share the same 32,767 units with the prompt. Sized from the
        # command itself, so it does not depend on how long the flags are
        # (the denial list shrank to '*' and broke a fixed 31,900).
        import subprocess
        flags = len(subprocess.list2cmdline(AGENT_COMMANDS["claude"]))
        prompt = "x" * (32_000 - flags // 2)
        self.assertFalse(_prompt_on_stdin(prompt, platform="nt"))
        self.assertTrue(_prompt_on_stdin(prompt, AGENT_COMMANDS["claude"], platform="nt"))

    @unittest.skipUnless(os.name == "nt", "CreateProcess limit: Windows only")
    def test_the_decision_matches_what_windows_accepts(self):
        command = [sys.executable, "-c", "pass"]
        fits = '"' * 10_000 + "x" * 1_000      # escaped: ~21,000 units
        too_long = '"' * 16_000 + "x" * 1_000  # escaped: ~33,000 units
        self.assertFalse(_prompt_on_stdin(fits, command))
        subprocess.run([*command, fits], check=True)
        self.assertTrue(_prompt_on_stdin(too_long, command))
        with self.assertRaises(OSError):
            subprocess.run([*command, too_long], check=True)


if __name__ == "__main__":
    unittest.main()
