"""The web UI's markdown renderer must never let corpus or model text become markup.

The renderer (`esc`, `inline`, `md` in teach/web/index.html) is extracted and run
under node. Without node the behavioural test is skipped; the static test still runs.
"""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

INDEX = Path(__file__).resolve().parent.parent / "teach" / "web" / "index.html"
START = "// ------------------------------------------------------- mini render de MD"
END = "// ------------------------------------------------------------------ vistas"


def _renderer_source() -> str:
    text = INDEX.read_text(encoding="utf-8")
    return text[text.index(START):text.index(END)]


def test_renderer_block_is_found():
    src = _renderer_source()
    assert "const esc" in src and "function md" in src


def test_esc_covers_quotes_and_summary_is_not_passed_raw():
    src = _renderer_source()
    assert "&quot;" in src and "&#39;" in src
    # a whole <summary> line must not be appended to the output unescaped
    assert not re.search(r"<summary>\.\*<\\/summary>\$/\.test", src)


NODE = shutil.which("node")

PAYLOADS = [
    "<summary><img src=x onerror=alert(1)></summary>",
    '"><img src=x onerror=alert(1)>',
    "<details>\n<summary>a<script>alert(1)</script></summary>\n</details>",
    "[x](https://e.com/\"onmouseover=alert(1))",
    "- <img src=x onerror=alert(1)>",
    "| <svg onload=alert(1)> | b |\n|---|---|\n| c | d |",
]


def _run(expr_json: str) -> str:
    script = _renderer_source() + f"\nconsole.log(JSON.stringify({expr_json}));"
    out = subprocess.run([NODE, "-"], input=script, capture_output=True, text=True, check=True, timeout=30)
    return json.loads(out.stdout)


@pytest.mark.skipif(NODE is None, reason="node not installed")
@pytest.mark.parametrize("payload", PAYLOADS)
def test_payloads_never_produce_active_markup(payload):
    html = _run(f"md({json.dumps(payload)})")
    # no tag other than the structural ones the renderer itself emits
    tags = set(re.findall(r"<\s*([a-zA-Z0-9]+)", html))
    assert tags <= {"p", "ul", "ol", "li", "table", "tr", "td", "th", "div", "details",
                    "summary", "code", "pre", "strong", "a", "h2", "h3", "hr"}, html
    assert "<img" not in html and "<script" not in html and "<svg" not in html
    assert not re.search(r'<a [^>]*"\s*on\w+=', html)


@pytest.mark.skipif(NODE is None, reason="node not installed")
def test_esc_escapes_all_five():
    assert _run("esc(`&<>\"'`)") == "&amp;&lt;&gt;&quot;&#39;"


@pytest.mark.skipif(NODE is None, reason="node not installed")
def test_legit_details_and_summary_still_render():
    html = _run("md('<details>\\n<summary>Solution `ls`</summary>\\n\\nbody\\n</details>')")
    assert "<details>" in html and "<summary>Solution <code>ls</code></summary>" in html
