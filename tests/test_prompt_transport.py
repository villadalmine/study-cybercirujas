"""A prompt that does not fit on the command line travels on stdin.

The limits differ by platform and are counted differently: Linux caps one argv
element at 128 KiB in bytes, Windows caps the whole command line at 32,767
UTF-16 code units. With the Linux number on Windows, a translation prompt
(the whole source file) fails before the CLI starts, with WinError 206.
"""
import unittest

from teach.core.generator import _prompt_on_stdin


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
        # 16k astral characters are 32k UTF-16 units, over the Windows limit,
        # although they are only 16k Python characters.
        self.assertTrue(_prompt_on_stdin("\U0001F600" * 16_000, platform="nt"))
        self.assertFalse(_prompt_on_stdin("ñ" * 16_000, platform="nt"))


if __name__ == "__main__":
    unittest.main()
