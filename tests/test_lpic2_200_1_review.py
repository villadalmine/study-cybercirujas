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


class WireRateTest(unittest.TestCase):
    def test_rows_are_frames_and_the_rates_follow(self):
        # One semantics per row: an L2 frame (header + FCS included); on the
        # wire it costs 20 B more (preamble/SFD 8 + inter-frame gap 12).
        for lang in LANGS:
            rows = re.findall(r"^\| (\d+) B \((\d+) B[^|]*\| (\d+) \| ([\d.]+) (k|M)pps",
                              read(lang, "content.md"), re.M)
            self.assertEqual(len(rows), 5, lang)
            for frame, payload, wire, gbe, unit in rows:
                frame, payload, wire = int(frame), int(payload), int(wire)
                self.assertEqual(frame - payload, 18, (lang, frame))
                self.assertEqual(wire - frame, 20, (lang, frame))
                pps = 1e9 / (wire * 8) / (1e3 if unit == "k" else 1e6)
                self.assertAlmostEqual(float(gbe), pps, delta=0.06 * pps, msg=(lang, frame))


# Checked on 2026-10-15 with redirects followed. Not all are dead: LPI's 201
# page redirects to the combined 201-202 page (cite the final page), its 202
# page lands on the LPI home page, and the rest answer 404, or 403 to every
# client. None of them is cited here, including meta.yaml's `sources`.
DEAD_CITATIONS = (
    "https://www.lpi.org/our-certifications/exam-202-objectives/",
    "https://www.lpi.org/our-certifications/exam-201-objectives/",
    "https://wiki.linuxfoundation.org/networking/iproute2",
    "https://docs.kernel.org/block/queue-sysfs.html",
    "https://sysstat.github.io/sysstat-docs/",
)


class CitationsTest(unittest.TestCase):
    def test_no_citation_known_not_to_reach_its_page(self):
        for lang in LANGS:
            for name in ("content.md", "exercises.md", "meta.yaml"):
                text = read(lang, name)
                for url in DEAD_CITATIONS:
                    self.assertNotIn(url, text, f"{lang}/{name}")


class ConntrackLabTest(unittest.TestCase):
    def test_lab_5c_can_fill_the_table(self):
        # nf_conntrack_max is read-only outside the initial namespace
        # (nf_conntrack_standalone.c: "Don't allow non-init_net ns to alter
        # global sysctls"; reproduced on 6.18: Invalid argument), and the
        # limit must be below the number of streams or nothing fills.
        for lang in LANGS:
            text = read(lang, "exercises.md")
            self.assertNotRegex(text, r"netns exec \w+ sysctl -w net\.netfilter\.nf_conntrack_max", lang)
            limit = int(re.search(r"^sudo sysctl -w net\.netfilter\.nf_conntrack_max=(\d+)$", text, re.M).group(1))
            streams = int(re.search(r"iperf3 -c \S+ -P (\d+)", text).group(1))
            self.assertLess(limit, streams, lang)


class LabContractTest(unittest.TestCase):
    def test_lab_follows_the_study_lab_contract(self):
        import yaml
        lab = TOPIC / "lab"
        spec = yaml.safe_load((lab / "lab.yaml").read_text(encoding="utf-8"))
        self.assertEqual(spec["requires"], "linux")      # systemd as PID 1
        self.assertEqual(spec["run_as"], "root")
        self.assertEqual({k: v["args"] for k, v in spec["modes"].items()},
                         {"break": ["break"], "verify": ["verify"], "cleanup": ["cleanup"]})
        script = (lab / "break_fix.sh").read_text(encoding="utf-8")
        self.assertIn('case "${1:-break}" in', script)   # no argument = break
        self.assertNotIn(chr(13), script)                # LF only: bash rejects CRLF
        # Only tools the study-lab:linux image ships (procps, psmisc, lsof):
        # no sysstat or iotop in the part that runs.
        code = script.split("# --- SOLUTION")[0]
        self.assertNotRegex(code, r"\b(iostat|sar|mpstat|pidstat|iotop)\b")


class ProvenanceTest(unittest.TestCase):
    def test_hand_edits_are_recorded(self):
        # CONTRIBUTING, "Provenance is mandatory": a hand edit appends a record.
        import yaml
        for lang in LANGS:
            meta = yaml.safe_load((TOPIC / lang / "meta.yaml").read_text(encoding="utf-8"))
            edits = meta.get("human_edits") or []
            self.assertGreaterEqual(len(edits), 7, lang)
            for edit in edits:
                self.assertEqual(set(edit), {"date", "author", "summary", "source"}, lang)


class MemAvailableTest(unittest.TestCase):
    def test_q16_matches_si_mem_available(self):
        # mm/show_mem.c si_mem_available() counts the file LRU and never reads
        # Dirty/Writeback: more dirty pages do not lower MemAvailable.
        for lang in LANGS:
            answer = next(l for l in read(lang, "exercises.md").splitlines()
                          if l.startswith("**Q16.**"))
            self.assertIn("si_mem_available()", answer, lang)
            self.assertNotRegex(answer, r"`MemAvailable` (drops|baja)", lang)


class ListenQueueTest(unittest.TestCase):
    def test_listen_recv_q_never_exceeds_backlog_plus_one(self):
        # On LISTEN, ss shows Recv-Q = sk_ack_backlog and Send-Q =
        # sk_max_ack_backlog (net/ipv4/tcp_diag.c); the queue is full when the
        # first exceeds the second (sk_acceptq_is_full), so Recv-Q <= Send-Q + 1.
        for lang in LANGS:
            for name in ("content.md", "exercises.md"):
                for recv, send in re.findall(r"^LISTEN +(\d+) +(\d+) ", read(lang, name), re.M):
                    self.assertLessEqual(int(recv), int(send) + 1, f"{lang}/{name}")


class ConntrackSizeTest(unittest.TestCase):
    def test_one_per_entry_size_and_a_consistent_slabtop_row(self):
        # Measured 2026-10-15: /sys/kernel/slab/nf_conntrack/slab_size = 256 on
        # kernel 6.18 (object_size 248). The size depends on the build, so
        # the material points at slab_size instead of quoting a constant.
        for lang in LANGS:
            text = read(lang, "content.md") + read(lang, "exercises.md")
            self.assertNotRegex(text, r"~3[02]0 (B|bytes)", lang)
            objs, size, slabs, per_slab, cache = re.search(
                r"^ *(\d+) +\d+ +\d+% +([\d.]+)K +(\d+) +(\d+) +(\d+)K nf_conntrack$",
                read(lang, "content.md"), re.M).groups()
            self.assertGreaterEqual(int(slabs) * int(per_slab), int(objs), lang)
            self.assertEqual(int(slabs) * 4, int(cache), lang)   # 4 KiB slabs
            self.assertAlmostEqual(float(size) * 1024 * int(per_slab), 4096, delta=64)


class PacketRateTest(unittest.TestCase):
    def test_no_per_core_packet_rate_is_quoted(self):
        # No source gives one; it depends on CPU, NIC, driver and ruleset.
        for lang in LANGS:
            text = read(lang, "content.md") + read(lang, "exercises.md")
            self.assertNotRegex(text, r"Mpps (per|por) core", lang)


class MathisTest(unittest.TestCase):
    def test_one_form_of_the_bound_with_its_constant_and_source(self):
        # Mathis et al. 1997 (doi 10.1145/263932.264023): (MSS/RTT) * C/sqrt(p),
        # C = 1.22; exercises.md already used it, content.md dropped C.
        for lang in LANGS:
            content = read(lang, "content.md")
            self.assertNotIn("BW ≈ MSS / (RTT × √p)", content, lang)
            self.assertIn("(MSS / RTT) × (1.22 / √p)", content, lang)
            self.assertIn("10.1145/263932.264023", content, lang)
            self.assertAlmostEqual(1.22 * 1448 / (0.080 * 0.001 ** 0.5) / 1e3, 698, delta=1)


class CpuPressureTest(unittest.TestCase):
    def test_cpu_full_exists_and_is_zero_system_wide(self):
        # psi.rst: "CPU full is undefined at the system level, but has been
        # reported since 5.13, so it is set to zero for backward compatibility".
        for lang in LANGS:
            text = read(lang, "content.md") + read(lang, "exercises.md")
            self.assertNotRegex(text, r"non-existent\) `cpu full`|inexistente\) `cpu full`|does not publish `cpu full`|no publica `cpu full`", lang)
            somes = re.findall(r"^(?:/proc/pressure/cpu:)?some avg10=", text, re.M)
            fulls = re.findall(r"^(?:/proc/pressure/cpu:)?full avg10=0\.00 avg60=0\.00 avg300=0\.00 total=0$", text, re.M)
            self.assertGreaterEqual(len(fulls), 4, lang)


class NapiBudgetTest(unittest.TestCase):
    def test_budget_usecs_default_follows_hz(self):
        # net/core/hotdata.c: .netdev_budget_usecs = 2 * USEC_PER_SEC / HZ;
        # Debian bookworm builds with CONFIG_HZ_250=y, so the lab VM prints 8000.
        for lang in LANGS:
            text = read(lang, "content.md") + read(lang, "exercises.md")
            for value in re.findall(r"netdev_budget_usecs = (\d+)", text):
                self.assertEqual(int(value), 2 * 1_000_000 // 250, lang)
            self.assertNotRegex(text, r"`netdev_budget_usecs`, 2000 µs\)", lang)


class MemoryEventsTest(unittest.TestCase):
    def test_q25_uses_cgroup_v2_definitions(self):
        # cgroup-v2.rst, memory.events: max = "about to go over the max
        # boundary" (direct reclaim runs); oom = "allocation was about to fail".
        for lang in LANGS:
            answer = next(l for l in read(lang, "exercises.md").splitlines()
                          if l.startswith("**Q25.**"))
            self.assertNotRegex(answer, r"refused and reclaim|rechazada y se forzó", lang)
            self.assertIn("cgroup-v2.rst", answer, lang)
            self.assertIn("`oom`", answer, lang)


class OverheadTest(unittest.TestCase):
    def test_tool_cost_column_quotes_no_unsourced_percentage(self):
        # Sampling overhead depends on -F and the event; no source gives a
        # range, so the column stays qualitative like its other rows.
        for lang in LANGS:
            row = next(l for l in read(lang, "content.md").splitlines()
                       if l.startswith("| `perf top` / `perf record` |"))
            self.assertNotRegex(row, r"\d+\s*[–-]\s*\d+\s*%", lang)
            self.assertIn("`-F`", row, lang)


if __name__ == "__main__":
    unittest.main()
