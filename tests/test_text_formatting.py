from __future__ import annotations

import unittest

from text_formatting import apply_spoken_formatting


class SpokenFormattingTests(unittest.TestCase):
    def test_punctuation_commands(self) -> None:
        self.assertEqual(
            apply_spoken_formatting(
                "hello comma how are you question mark I am fine exclamation point"
            ),
            "hello, how are you? I am fine!",
        )

    def test_line_break_commands(self) -> None:
        self.assertEqual(
            apply_spoken_formatting("first line new line second line"),
            "first line\nsecond line",
        )
        self.assertEqual(
            apply_spoken_formatting("intro next paragraph body"),
            "intro\n\nbody",
        )

    def test_wrapping_commands(self) -> None:
        self.assertEqual(
            apply_spoken_formatting(
                "open parenthesis private beta close parenthesis open quote ship it close quote"
            ),
            '(private beta) "ship it"',
        )

    def test_spacing_cleanup(self) -> None:
        self.assertEqual(
            apply_spoken_formatting("hello comma world period next"),
            "hello, world. next",
        )


if __name__ == "__main__":
    unittest.main()
