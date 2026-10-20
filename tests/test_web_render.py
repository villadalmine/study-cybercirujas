"""The web UI's markdown renderer must never let corpus or model text become markup.

The renderer (`esc`, `inline`, `md` in teach/web/index.html) is extracted and run
under node. Without node the behavioural tests are skipped; the static ones still run.
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

INDEX = Path(__file__).resolve().parent.parent / "teach" / "web" / "index.html"
START = "// ------------------------------------------------------- mini render de MD"
END = "// ------------------------------------------------------------------ vistas"
NODE = shutil.which("node")

PAYLOADS = [
    "<summary><img src=x onerror=alert(1)></summary>",
    '"><img src=x onerror=alert(1)>',
    "<details>\n<summary>a<script>alert(1)</script></summary>\n</details>",
    "[x](https://e.com/\"onmouseover=alert(1))",
    "- <img src=x onerror=alert(1)>",
    "| <svg onload=alert(1)> | b |\n|---|---|\n| c | d |",
]
STRUCTURAL = {"p", "ul", "ol", "li", "table", "tr", "td", "th", "div", "details",
              "summary", "code", "pre", "strong", "a", "h2", "h3", "hr"}


def renderer_source() -> str:
    text = INDEX.read_text(encoding="utf-8")
    return text[text.index(START):text.index(END)]


def run_js(expr: str) -> str:
    script = renderer_source() + f"\nconsole.log(JSON.stringify({expr}));"
    out = subprocess.run([NODE, "-"], input=script, capture_output=True, text=True, check=True, timeout=30)
    return json.loads(out.stdout)


class StaticTests(unittest.TestCase):
    def test_renderer_block_is_found(self):
        src = renderer_source()
        self.assertIn("const esc", src)
        self.assertIn("function md", src)

    def test_esc_covers_quotes_and_summary_is_not_passed_raw(self):
        src = renderer_source()
        self.assertIn("&quot;", src)
        self.assertIn("&#39;", src)
        self.assertIsNone(re.search(r"<summary>\.\*<\\/summary>\$/\.test", src))


@unittest.skipIf(NODE is None, "node not installed")
class RendererTests(unittest.TestCase):
    def test_payloads_never_produce_active_markup(self):
        for payload in PAYLOADS:
            with self.subTest(payload=payload):
                html = run_js(f"md({json.dumps(payload)})")
                tags = set(re.findall(r"<\s*([a-zA-Z0-9]+)", html))
                self.assertLessEqual(tags, STRUCTURAL, html)
                for bad in ("<img", "<script", "<svg"):
                    self.assertNotIn(bad, html)
                self.assertIsNone(re.search(r'<a [^>]*"\s*on\w+=', html))

    def test_esc_escapes_all_five(self):
        self.assertEqual(run_js("esc(`&<>\"'`)"), "&amp;&lt;&gt;&quot;&#39;")

    def test_legit_details_and_summary_still_render(self):
        html = run_js("md('<details>\\n<summary>Solution `ls`</summary>\\n\\nbody\\n</details>')")
        self.assertIn("<details>", html)
        self.assertIn("<summary>Solution <code>ls</code></summary>", html)


if __name__ == "__main__":
    unittest.main()
