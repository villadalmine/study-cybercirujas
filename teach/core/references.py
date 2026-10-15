"""Where a topic's References section starts — one definition for every check.

check_citations (do the URLs exist), check_sources (whose domains), check_claims
and check_source_chain (does the content declare its sources) all read the same
section. Four slightly different regexes used to disagree: numbered headings
("## 14. References") were skipped by one, a CJK prefix ("## 参考例：…", a
"reference example") was taken for References by another.

A heading is References when, after optional '#'s and an optional number
("14." / "10)"), its first word is one of NAMES and the next character ends
that word: end of line, a space, '(' / '（', '/', or ':' / '：'. So
"## 10. References (official sources)" and "## 参考資料 / References" are
References; "## Referenceshelf" and "## 参考例：確認コマンドまとめ" are not.
"""
from __future__ import annotations

import re

NAMES = ("References", "Referencias", "Références", "Referenzen", "Referências",
         "参考文献", "参考文档", "参考資料", "参考资料", "参考")

HEADING = re.compile(
    r"^#+[ \t]*(?:[0-9]+[.)]?[ \t]*)?(?:" + "|".join(re.escape(n) for n in NAMES) + r")"
    r"(?=[ \t]|$|[(（/:：])[^\n]*$",
    re.I | re.M,
)


def section(text: str) -> str | None:
    """The text after the first References heading, or None when there is none."""
    match = HEADING.search(text)
    return text[match.end():] if match else None
