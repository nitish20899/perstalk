"""Text cleanup helpers shared by the web backend and native app smoke tests."""

from __future__ import annotations

import re


def apply_spoken_formatting(text: str) -> str:
    """Convert common dictated formatting words before the rewrite model runs."""
    formatted = f" {text.strip()} "
    open_quote = "__PERSTALK_OPEN_QUOTE__"
    close_quote = "__PERSTALK_CLOSE_QUOTE__"
    replacements = [
        (r"\b(new paragraph|next paragraph)\b", "\n\n"),
        (r"\b(new line|next line|line break)\b", "\n"),
        (r"\b(question mark)\b", "?"),
        (r"\b(exclamation point|exclamation mark)\b", "!"),
        (r"\b(full stop|period)\b", "."),
        (r"\b(comma)\b", ","),
        (r"\b(colon)\b", ":"),
        (r"\b(semicolon)\b", ";"),
        (r"\b(open parenthesis)\b", "("),
        (r"\b(close parenthesis)\b", ")"),
        (r"\b(open quote)\b", open_quote),
        (r"\b(close quote)\b", close_quote),
        (r"\b(dash|hyphen)\b", "-"),
        (r"\b(slash)\b", "/"),
    ]

    for pattern, replacement in replacements:
        formatted = re.sub(pattern, replacement, formatted, flags=re.IGNORECASE)

    formatted = re.sub(rf"{open_quote}[ \t]+", open_quote, formatted)
    formatted = re.sub(rf"[ \t]+{close_quote}", close_quote, formatted)
    formatted = formatted.replace(open_quote, '"').replace(close_quote, '"')
    formatted = re.sub(r"[ \t]+([,.;:?!\)])", r"\1", formatted)
    formatted = re.sub(r"([\(\"])[ \t]+", r"\1", formatted)
    formatted = re.sub(r"[ \t]*\n[ \t]*", "\n", formatted)
    formatted = re.sub(r"\n{3,}", "\n\n", formatted)
    formatted = re.sub(r"([,.;:?!])(?=\S)", r"\1 ", formatted)
    formatted = re.sub(r"[ \t]{2,}", " ", formatted)
    return formatted.strip()
