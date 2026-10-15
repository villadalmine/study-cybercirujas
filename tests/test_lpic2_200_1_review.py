"""lpic-2/200.1: what the review of PR #6 found, kept from coming back.

The topic was authored by a model; an independent review (fable, revisor-pr)
found claims that no source backed. Each test pins one fix against the
official source it was checked with, in both languages.
"""
import re
import unittest
from pathlib import Path

TOPIC = Path(__file__).resolve().parent.parent / "certs" / "lpic-2" / "200.1"
LANGS = ("en", "es")

# LPI, Exam Objectives version 4.5.0, 200.1 (weight: 6), "partial list of the
# used files, terms and utilities", verbatim:
# https://www.lpi.org/our-certifications/exam-201-202-objectives/
LPI_LIST = ("`iostat`, `iotop`, `vmstat`, `netstat`, `ss`, `iptraf`, `pstree`, "
            "`ps`, `w`, `lsof`, `top`, `htop`, `uptime`, `sar`, swap, "
            "processes blocked on I/O, blocks in, blocks out")


def read(lang: str, name: str) -> str:
    return (TOPIC / lang / name).read_text(encoding="utf-8")


class ObjectiveTest(unittest.TestCase):
    def test_weight_is_lpis(self):
        for lang in LANGS:
            for name in ("content.md", "exercises.md"):
                head = "\n".join(read(lang, name).splitlines()[:8])
                self.assertRegex(head, r"(LPI weight|[Pp]eso LPI):?\*?\*? 6", f"{lang}/{name}")
                self.assertNotRegex(head, r"[Ww]eight:?\*?\*? 5|[Pp]eso:?\*?\*? 5", f"{lang}/{name}")

    def test_utility_list_is_lpis_verbatim(self):
        for lang in LANGS:
            for name in ("content.md", "exercises.md"):
                self.assertIn(LPI_LIST, read(lang, name), f"{lang}/{name}")


class SampleOutputTest(unittest.TestCase):
    def test_no_claim_of_a_capture_that_never_happened(self):
        # The material is model-written; nothing was run on a host. Saying
        # otherwise is the kind of invented provenance the review caught.
        for lang in LANGS:
            text = read(lang, "content.md")
            self.assertNotRegex(text, r"captured on a reference|se captur[óo] en un host")
            self.assertRegex(text, r"\*\*(illustrative|ilustrativa)\*\*")


def yaml_blocks(text: str) -> list:
    import yaml
    out = []
    for block in re.findall(r"^```yaml\n(.*?)^```", text, re.M | re.S):
        try:
            out.extend(d for d in yaml.safe_load_all(block) if d is not None)
        except yaml.YAMLError:
            pass
    return out


def sysstat_play_tasks(lang: str) -> list[str]:
    for doc in yaml_blocks(read(lang, "content.md")):
        for play in doc if isinstance(doc, list) else []:
            tasks = (play or {}).get("tasks") or [] if isinstance(play, dict) else []
            names = [t.get("name", "") for t in tasks if isinstance(t, dict)]
            if any("Override the collection interval" in n for n in names):
                return names
    raise AssertionError(f"{lang}: sysstat playbook not found")


class PlaybookTest(unittest.TestCase):
    def test_override_directory_exists_before_the_copy_into_it(self):
        # ansible.builtin.copy does not create parent directories.
        for lang in LANGS:
            names = sysstat_play_tasks(lang)
            mkdir = names.index("Ensure the timer override directory exists")
            copy = next(i for i, n in enumerate(names) if "Override the collection interval" in n)
            self.assertLess(mkdir, copy, lang)

    def test_debian_cron_helper_is_enabled(self):
        # /usr/lib/sysstat/debian-sa1 (Debian 12, sysstat 12.6.1) exits unless
        # ENABLED="true" in /etc/default/sysstat; the cron fallback runs it.
        for lang in LANGS:
            self.assertTrue(any("ENABLED" in n for n in sysstat_play_tasks(lang)), lang)


class AlertsTest(unittest.TestCase):
    def test_vmstat_metrics_used_by_alerts_are_exported(self):
        # node_exporter's vmstat collector exports only --collector.vmstat.fields,
        # default ^(oom_kill|pgpg|pswp|pg.*fault).* (collector/vmstat_linux.go).
        default = r"^(oom_kill|pgpg|pswp|pg.*fault).*"
        for lang in LANGS:
            text = read(lang, "content.md")
            used = set(re.findall(r"node_vmstat_(\w+)", text))
            flag = re.search(r"--collector\.vmstat\.fields=(\S+)", text)
            pattern = flag.group(1) if flag else default
            missing = sorted(f for f in used if not re.match(pattern, f))
            self.assertEqual(missing, [], lang)


if __name__ == "__main__":
    unittest.main()
