"""A snapshot must be refused when the source document does not support it.

Seven certifications were frozen from their *overview* page, which lists chapter
titles and no objectives. The extraction returned the chapter titles, the weights
came back as 100 divided by their count, and every downstream check passed —
because every file it produced was genuinely good. The defect was the list of
topics, and nothing looked at that.

Both checks derive from the fetched document itself, so neither is specific to a
vendor, an exam or a page layout.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from teach.core import tracker  # noqa: E402

class SyllabusCoverageTests(unittest.TestCase):
    """A snapshot must be refused when the document does not support it.

    Seven certifications were frozen from their overview page, which lists
    chapter titles and no objectives. The extraction returned the chapter
    titles, the weights were 100 divided by their count, and every downstream
    check passed because every file it produced was genuinely good.
    """

    PAGE = ("351.1 Virtualization Concepts 351.2 Xen 351.3 QEMU 351.4 Libvirt "
            "351.5 Disk Images 352.1 Container Concepts 352.2 LXC 352.3 Docker "
            "352.4 Orchestration 353.1 Cloud Tools 353.2 Packer 353.3 cloud-init "
            "353.4 Vagrant")

    def test_counts_objectives_and_ignores_page_furniture(self):
        # "160.5" is a price and "100.00" a percentage; both match the shape.
        ids = tracker.objective_ids(self.PAGE + " 160.5 100.00")
        self.assertEqual(len(ids), 13)

    def test_does_not_count_an_objective_the_exam_withdrew(self):
        # LPIC-1 prints "104.4 Removed" so the surviving ids keep their numbers.
        # Counting it demanded a topic for something the exam no longer asks,
        # and rejected a correct 42-topic extraction for missing a phantom.
        page = "104.1 Partitions 104.2 Integrity 104.3 Mounting 104.4 Removed 104.5 Permissions"
        self.assertEqual(tracker.objective_ids(page), {"104.1", "104.2", "104.3", "104.5"})

    def test_unnumbered_document_yields_nothing_rather_than_a_pass(self):
        self.assertEqual(tracker.objective_ids("Domain 1: Full Virtualization"), set())

    def test_rejects_chapter_headings_extracted_from_a_numbered_document(self):
        topics = [{"id": "1.1", "weight": 33.33}, {"id": "1.2", "weight": 33.33},
                  {"id": "1.3", "weight": 33.34}]
        with self.assertRaises(tracker.TrackerError) as caught:
            tracker._reject_unreadable_syllabus(topics, self.PAGE, "u")
        self.assertIn("13 objectives", str(caught.exception))

    def test_rejects_weights_computed_from_the_topic_count(self):
        # Sum is exactly 100, which was the only rule the snapshot ever had.
        topics = [{"id": f"1.{i}", "weight": 25} for i in range(1, 5)]
        with self.assertRaises(tracker.TrackerError) as caught:
            tracker._reject_unreadable_syllabus(topics, "no numbering here", "u")
        self.assertIn("divided", str(caught.exception))

    def test_normalises_a_published_scale_to_exactly_one_hundred(self):
        # LPIC-3 305 prints weights totalling 57. The first real extraction was
        # correct and was thrown away because the model rescaled them to 105.26.
        topics = [{"id": f"351.{i}", "weight": w} for i, w in
                  enumerate([6, 3, 4, 9, 3, 7, 6, 9, 3, 2, 2, 3, 3], 1)]
        tracker.normalise_weights(topics)
        self.assertEqual(round(sum(t["weight"] for t in topics), 2), 100.0)
        # Proportions survive: Libvirt (9) stays three times Xen (3).
        self.assertAlmostEqual(topics[3]["weight"] / topics[1]["weight"], 3.0, places=1)

    def test_normalising_does_not_disguise_weights_taken_from_the_count(self):
        topics = [{"id": f"1.{i}", "weight": 5} for i in range(1, 5)]
        tracker.normalise_weights(topics)
        with self.assertRaises(tracker.TrackerError):
            tracker._reject_unreadable_syllabus(topics, "no numbering", "u")

    def test_accepts_equal_weights_the_document_actually_publishes(self):
        # CNCF publishes CAPA as five domains at 20% each. Rejecting that would
        # block a correct syllabus for having the shape of a wrong one, so the
        # distinction is whether the DOCUMENT prints a weight per topic.
        page = ("| Argo Project Fundamentals | 20% | | Argo Workflows | 20% | "
                "| Argo CD | 20% | | Argo Rollouts | 20% | | Argo Events | 20% |")
        topics = [{"id": f"{i}.1", "weight": 20} for i in range(1, 6)]
        tracker._reject_unreadable_syllabus(topics, page, "u")

    def test_accepts_an_even_split_when_the_vendor_publishes_no_weights(self):
        # HashiCorp lists Terraform objectives with no weighting at all. Declared
        # by a person in catalog.yaml, the even split is the honest answer.
        topics = [{"id": f"1.{i}", "weight": 25} for i in range(1, 5)]
        tracker._reject_unreadable_syllabus(topics, "no numbering", "u",
                                            weights_unpublished=True)

    def test_declaring_no_weights_does_not_excuse_missing_objectives(self):
        topics = [{"id": "1.1", "weight": 50}, {"id": "1.2", "weight": 50}]
        with self.assertRaises(tracker.TrackerError):
            tracker._reject_unreadable_syllabus(topics, self.PAGE, "u",
                                                weights_unpublished=True)

    def test_strips_backend_diagnostics_that_are_not_the_answer(self):
        # A CAPA snapshot died at line 2 on "Client.listTools() called but
        # server has no tools" — a model call thrown away for a diagnostic that
        # has nothing to do with the content.
        noisy = "version: '1.0'\nClient.listTools() called but server has no tools\ntopics: []"
        cleaned = "\n".join(l for l in noisy.splitlines()
                            if not tracker.CLI_NOISE.match(l))
        self.assertNotIn("listTools", cleaned)
        self.assertIn("version", cleaned)

    def test_accepts_a_full_extraction(self):
        topics = [{"id": f"351.{i}", "weight": w} for i, w in
                  enumerate([10, 5, 7, 15, 5, 12, 10, 15, 5, 4, 4, 4, 4], 1)]
        tracker._reject_unreadable_syllabus(topics, self.PAGE, "u")


class SnapshotDocumentTests(unittest.TestCase):
    """The snapshot reads the whole objectives document and records its hash (#63; audit 2026-10-20, item 5)."""

    def fetch(self, body: bytes, limit: int = 20000):
        with mock.patch.object(tracker, "_get_bytes", return_value=(body, "text/html")):
            return tracker.fetch_document("https://example.org/objectives", limit=limit)

    def test_returns_the_full_text_and_the_sha256_of_the_bytes(self):
        body = b"<html><body><h1>Objectives</h1><p>1.1 Install</p></body></html>"
        text, digest = self.fetch(body)
        self.assertEqual(text, "Objectives 1.1 Install")
        self.assertEqual(digest, hashlib.sha256(body).hexdigest())

    def test_refuses_a_document_longer_than_the_limit_instead_of_truncating(self):
        with self.assertRaises(tracker.TrackerError) as raised:
            self.fetch(b"<p>" + b"objective " * 50 + b"</p>", limit=100)
        self.assertIn("refused rather than truncated", str(raised.exception).lower())

    def test_fetch_text_still_cuts_for_its_other_callers(self):
        with mock.patch.object(tracker, "_get_bytes", return_value=(b"<p>abcdef</p>", "text/html")):
            self.assertEqual(tracker.fetch_text("https://example.org/x", limit=3), "abc")


class SyncCncfTests(unittest.TestCase):
    """`teach tracker sync` fills `upstream:` and never moves `tracked_version` (#63)."""

    def run_sync(self, cert: dict):
        data = {"certs": {"cka": cert}}
        responses = {
            "contents": [{"name": "CKA_Curriculum_v1.37.pdf"}],
            "commits": [{"sha": "b3c8508", "commit": {"committer": {"date": "2026-10-15T15:49:08Z"}}}],
        }

        class Response:
            def __init__(self, payload):
                self.payload = payload

            def json(self):
                return self.payload

        def fake_get(url):
            return Response(responses["contents" if url.endswith("/contents/") else "commits"])

        with mock.patch.object(tracker, "_get", side_effect=fake_get), \
                mock.patch.object(tracker, "_get_bytes", return_value=(b"%PDF", "application/pdf")), \
                mock.patch.object(tracker.catalog, "load", return_value=data), \
                mock.patch.object(tracker.catalog, "save"):
            changes = tracker.sync_cncf()
        return data["certs"]["cka"], changes

    def test_a_new_upstream_version_goes_to_upstream_not_tracked_version(self):
        cert, changes = self.run_sync({"tracked_version": "1.35", "sources": {}})
        self.assertEqual(cert["tracked_version"], "1.35")
        self.assertEqual(cert["upstream_status"], "outdated")
        self.assertEqual(cert["upstream"]["version"], "1.37")
        self.assertEqual(cert["upstream"]["objectives"],
                         "https://github.com/cncf/curriculum/raw/b3c8508/CKA_Curriculum_v1.37.pdf")
        self.assertEqual(cert["upstream"]["sha256"], hashlib.sha256(b"%PDF").hexdigest())
        self.assertIn("tracked_version stays 1.35", " ".join(changes))

    def test_after_the_switch_the_status_is_current(self):
        cert, _ = self.run_sync({"tracked_version": "1.37", "sources": {},
                                 "upstream": {"version": "1.37", "milestone": "CKA & CKAD v1.37 upgrade"}})
        self.assertEqual((cert["tracked_version"], cert["upstream_status"]), ("1.37", "current"))
        self.assertEqual(cert["upstream"]["milestone"], "CKA & CKAD v1.37 upgrade")

    def test_sync_is_idempotent_once_the_tracked_version_is_the_published_one(self):
        cert, changes = self.run_sync({"tracked_version": "1.37", "sources": {}})
        self.assertNotIn("upstream", cert)                      # nothing ahead: no block, no clock date
        self.assertEqual(cert["upstream_status"], "current")
        self.assertNotIn("upstream publishes", " ".join(changes))



def make_pdf(pages: list[list[tuple[float, str, str | None]]]) -> bytes:
    """A minimal PDF: per page, lines of (y, text, link uri or None).

    Written by hand so the test needs no PDF library beyond the reader under test,
    and no network: the real NVIDIA guides are what this was tuned on, the shape is
    what is pinned here."""
    objects: list[bytes] = []

    def add(body: str) -> int:
        objects.append(body.encode("latin-1"))
        return len(objects)

    font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids = []
    pages_id = len(objects) + 1 + 2 * len(pages) + sum(sum(1 for l in p if l[2]) for p in pages)
    for lines in pages:
        stream = "".join(
            f"BT /F1 10 Tf 1 0 0 1 40 {y} Tm ({text.replace('(', '[').replace(')', ']')}) Tj ET\n"
            for y, text, _ in lines)
        content = add(f"<< /Length {len(stream)} >>\nstream\n{stream}endstream")
        annots = [add(f"<< /Type /Annot /Subtype /Link /Rect [40 {y - 2} 400 {y + 9}] "
                      f"/A << /S /URI /URI ({uri}) >> >>")
                  for y, _, uri in lines if uri]
        refs = " ".join(f"{a} 0 R" for a in annots)
        page_ids.append(add(f"<< /Type /Page /Parent {pages_id} 0 R /MediaBox [0 0 612 792] "
                            f"/Resources << /Font << /F1 {font} 0 R >> >> /Contents {content} 0 R "
                            f"/Annots [{refs}] >>"))
    assert add(f"<< /Type /Pages /Kids [{' '.join(f'{p} 0 R' for p in page_ids)}] "
               f"/Count {len(page_ids)} >>") == pages_id
    catalog_id = add(f"<< /Type /Catalog /Pages {pages_id} 0 R >>")
    out, offsets = b"%PDF-1.4\n", []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += b"".join(f"{o:010d} 00000 n \n".encode() for o in offsets)
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root {catalog_id} 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode()
    return out


TOPICS = [{"id": "1.1", "topic": "1 - Essential AI Knowledge"},
          {"id": "1.2", "topic": "1 - Essential AI Knowledge"},
          {"id": "2.1", "topic": "2 - AI Infrastructure"}]


class ReadingsTests(unittest.TestCase):
    """The vendor's per-domain readings reach the syllabus with their links (#271)."""

    def test_html_links_are_kept_and_filed_under_their_domain(self):
        page = (b"<nav><a href='https://x.example/home'>Home</a></nav>"
                b"<h2>Essential AI Knowledge</h2><p>Potential exam topics.</p>"
                b"<h3>Suggested Reading</h3><ul>"
                b"<li><a href='https://developer.nvidia.com/tensorrt'>NVIDIA TensorRT</a></li>"
                b"<li><a href='https://medium.com/post'>A blog</a></li></ul>"
                b"<h2>AI Infrastructure</h2><h3>Recommended Training</h3>"
                b"<a href='https://academy.nvidia.com/course'>Course</a>"
                b"<a href='#ai-operations'>AI Operations</a>"
                b"<footer><a href='https://x.example/privacy'>Privacy</a></footer>")
        stream = tracker.document_stream("https://v.example/overview", page, "text/html")
        found = tracker.readings_by_domain(stream, TOPICS)
        self.assertEqual(found, {
            "1 - Essential AI Knowledge": [
                {"title": "NVIDIA TensorRT", "url": "https://developer.nvidia.com/tensorrt"},
                {"title": "A blog", "url": "https://medium.com/post"}],
            "2 - AI Infrastructure": [{"title": "Course", "url": "https://academy.nvidia.com/course"}]})

    def test_the_heading_words_in_running_prose_open_nothing(self):
        # The NCA-AIIO cover: "...exam, recommended training, and suggested reading
        # to prepare for the exam." followed by a link to the certification portal.
        page = (b"<p>Essential AI Knowledge guide.</p><p>recommended training and suggested reading "
                b"to help prepare for the exam.</p><a href='https://v.example/certs'>found here</a>")
        stream = tracker.document_stream("https://v.example/o", page, "text/html")
        self.assertEqual(tracker.readings_by_domain(stream, TOPICS), {})

    def test_prose_after_a_list_closes_it(self):
        page = (b"<h2>AI Infrastructure</h2><h3>Suggested Readings</h3>"
                b"<a href='https://docs.nvidia.com/a'>A</a><p>" + b"Copyright notice. " * 30 +
                b"</p><a href='https://www.nvidia.com/contact'>Questions</a>")
        stream = tracker.document_stream("https://v.example/o", page, "text/html")
        self.assertEqual([r["url"] for r in tracker.readings_by_domain(stream, TOPICS)["2 - AI Infrastructure"]],
                         ["https://docs.nvidia.com/a"])

    def test_pdf_link_annotations_are_read_with_the_line_they_cover(self):
        # pypdf's extract_text never includes /URI annotations: this is the part
        # of the study guide document_text threw away.
        body = make_pdf([
            [(760, "NVIDIA AI Infrastructure Associate | Study Guide | 1", None),
             (700, "Essential AI knowledge: Exam Weight 38%", None),
             (680, "1.1 Describe the NVIDIA software stack.", None),
             (660, "Suggested Readings", None),
             (640, "> NVIDIA TensorRT, NVIDIA Developer", "https://developer.nvidia.com/tensorrt")],
            [(760, "NVIDIA AI Infrastructure Associate | Study Guide | 2", None),
             (700, "2.1 Identify hardware requirements.", None),
             (680, "Suggested Reading List", None),
             (660, "> DGX SuperPOD Reference Architecture", "https://docs.nvidia.com/superpod"),
             (520, "Questions?", None),
             (500, "Contact us here.", "https://www.nvidia.com/contact")]])
        stream = tracker.document_stream("https://v.example/guide.pdf", body, "application/pdf")
        self.assertNotIn("Study Guide", " ".join(v for _, v, _ in stream))   # running head dropped
        found = tracker.readings_by_domain(stream, TOPICS)
        self.assertEqual(found["1 - Essential AI Knowledge"],
                         [{"title": "NVIDIA TensorRT, NVIDIA Developer",
                           "url": "https://developer.nvidia.com/tensorrt"}])
        self.assertEqual([r["url"] for r in found["2 - AI Infrastructure"]],
                         ["https://docs.nvidia.com/superpod"])

    def test_two_columns_each_link_gets_its_own_column(self):
        # NCA-GENL: the bullet sits 9 points left of its box, and the right
        # column's baseline differs from the left one by a few points.
        items = tracker._pdf_page_items(
            [(36, 140, "> Attention Is All You Need"), (294, 141, "> Autoregressive Model")],
            [(45, 152, 138, 149, "https://a.example/1"), (303, 396, 138, 149, "https://a.example/2")])
        self.assertEqual(items, [("link", "https://a.example/1", "Attention Is All You Need"),
                                 ("link", "https://a.example/2", "Autoregressive Model")])

    def test_a_title_wrapped_onto_two_boxes_is_one_reading(self):
        # The other column's row sits between the two boxes of the left link.
        items = tracker._pdf_page_items(
            [(36, 126, "> End-to-End AI for PCs: Transitioning "), (45, 116, "AI Models With ONNX"),
             (294, 126, "> What Are Foundation Models?"), (303, 126, ", NVIDIA Blog")],
            [(45, 267, 124, 135, "https://a.example/e2e"), (45, 140, 113, 124, "https://a.example/e2e"),
             (303, 432, 124, 135, "https://a.example/fm")])
        self.assertEqual(items, [("link", "https://a.example/e2e", "End-to-End AI for PCs: Transitioning AI Models With ONNX"),
                                 ("link", "https://a.example/fm", "What Are Foundation Models?, NVIDIA Blog")])

    def test_a_box_over_the_publisher_only_still_gets_the_title(self):
        items = tracker._pdf_page_items([(36, 500, "> What Is Trustworthy AI?"), (160, 500, ", NVIDIA Blog")],
                                        [(160, 220, 498, 509, "https://blogs.nvidia.com/x")])
        self.assertEqual(items, [("link", "https://blogs.nvidia.com/x", "What Is Trustworthy AI?, NVIDIA Blog")])

    def test_a_domain_named_with_another_plural_is_still_that_domain(self):
        # NCP-AII's page: "System and Server Bring-Up"; the syllabus: "Systems…".
        topics = [{"id": "1.1", "topic": "1 - Systems and Server Bring-Up"},
                  {"id": "5.1", "topic": "5 - Troubleshooting and Optimization"}]
        page = (b"<ul><li>System and Server Bring-Up</li><li>Troubleshooting and Optimization</li></ul>"
                b"<h2>System and Server Bring-Up</h2><h3>Suggested Reading</h3>"
                b"<a href='https://docs.nvidia.com/smi'>nvidia-smi</a>")
        found = tracker.readings_by_domain(tracker.document_stream("https://v.example/p", page, "text/html"), topics)
        self.assertEqual(list(found), ["1 - Systems and Server Bring-Up"])

    def test_an_unrecognised_section_is_dropped_not_filed_under_the_last_domain(self):
        page = (b"<h2>AI Infrastructure</h2><h3>Suggested Readings</h3><a href='https://docs.nvidia.com/a'>A</a>"
                b"<p>" + b"A long paragraph about something else entirely. " * 10 + b"</p>"
                b"<h2>Some Domain We Do Not Know</h2><h3>Suggested Readings</h3><a href='https://docs.nvidia.com/b'>B</a>")
        found = tracker.readings_by_domain(tracker.document_stream("https://v.example/p", page, "text/html"), TOPICS)
        self.assertEqual([r["url"] for r in found["2 - AI Infrastructure"]], ["https://docs.nvidia.com/a"])

    def test_relative_links_are_resolved_against_the_page(self):
        # Microsoft Learn's resources are all relative: dropping them dropped the list.
        page = (b"<h2>AI Infrastructure</h2><h3>Additional resources</h3>"
                b"<a href='/en-us/azure/ai/x'>X</a><a href='#top'>Back to top</a><a href='mailto:a@b.c'>Mail</a>")
        found = tracker.readings_by_domain(
            tracker.document_stream("https://learn.microsoft.com/en-us/guide", page, "text/html"), TOPICS)
        self.assertEqual(found, {"2 - AI Infrastructure": [{"title": "X", "url": "https://learn.microsoft.com/en-us/azure/ai/x"}]})

    def test_a_running_footer_is_dropped_wherever_it_sits(self):
        pages = [[("text", "Guide | 1", ""), ("text", "a", "")],
                 [("text", "Guide | 2", ""), ("text", "b", "")],
                 [("text", "x", ""), ("text", "Guide | 3", ""), ("text", "(c) notice", "")]]
        self.assertEqual([v for _, v, _ in tracker._drop_running_heads(pages)], ["a", "b", "x", "(c) notice"])

    def test_a_possessive_domain_name_still_matches_itself(self):
        topics = [{"id": "3.1", "topic": "3 - Google Cloud's gen AI offerings"}]
        self.assertEqual(tracker._domain_of("Google Cloud's gen AI offerings", tracker._domain_markers(topics)),
                         "3 - Google Cloud's gen AI offerings")

    def test_a_reading_heading_heading_two_pages_is_not_a_running_head(self):
        pages = [[("text", "Suggested Readings", ""), ("text", "a", "")],
                 [("text", "Suggested Readings", ""), ("text", "b", "")]]
        self.assertEqual([v for _, v, _ in tracker._drop_running_heads(pages)],
                         ["Suggested Readings", "a", "Suggested Readings", "b"])

    def test_a_bare_domain_number_is_not_a_marker(self):
        # LFCS numbers its domains 1 to 5; a lone digit is every page number.
        topics = [{"id": "1", "topic": "1 - Operations"}, {"id": "2", "topic": "2 - Networking"}]
        self.assertIsNone(tracker._domain_of("2", tracker._domain_markers(topics)))

    def test_registering_for_the_exam_is_not_a_reading(self):
        self.assertTrue(tracker.CALL_TO_ACTION.search("Register for NCA-GENL Exam"))
        self.assertTrue(tracker.CALL_TO_ACTION.search("Contact us here."))
        self.assertTrue(tracker.CALL_TO_ACTION.search("Questions? Contact us here."))
        self.assertFalse(tracker.CALL_TO_ACTION.search("NVIDIA DCGM, NVIDIA Developer"))

    def test_same_reading_needs_a_long_shared_prefix(self):
        a = {"title": "Power Constraints and AI Workloads: The Hidden", "url": "u1"}
        b = {"title": "Power Constraints and AI Workloads: The Hidden Challenges, LinkedIn", "url": "u2"}
        self.assertTrue(tracker._same_reading(a, b))
        self.assertFalse(tracker._same_reading({"title": "RAPIDS", "url": "u3"}, {"title": "RAPIDS cuDF", "url": "u4"}))

    def test_the_page_wins_over_the_pdf_on_the_same_title(self):
        # NVIDIA moved three NCA-AIIO links on the page the January PDF still prints.
        page = {"d": [{"title": "Understanding Machine Learning Inference, Run:ai",
                       "url": "https://developer.nvidia.com/topics/ai/ai-inference"}]}
        pdf = {"d": [{"title": "Understanding Machine Learning Inference, Run:ai",
                      "url": "https://www.run.ai/guides/inference"},
                     {"title": "Only in the PDF", "url": "https://docs.nvidia.com/x"}]}
        merged = tracker.merge_readings(page, pdf)
        self.assertEqual([r["url"] for r in merged["d"]],
                         ["https://developer.nvidia.com/topics/ai/ai-inference", "https://docs.nvidia.com/x"])


class AttachReadingsTests(unittest.TestCase):
    """Catalogued hosts reach the generator's sources; nothing else does, and nothing goes stale."""

    def run_attach(self, metadata: dict, page: bytes):
        import frontmatter
        post = frontmatter.Post("", **metadata)
        data = {"certs": {"c": {"sources": {"objectives": "https://v.example/o.html"}}}}
        saved = []
        with mock.patch.object(tracker.catalog, "load", return_value=data), \
                mock.patch.object(tracker.certs, "load", return_value=post), \
                mock.patch.object(tracker.certs, "save", side_effect=lambda c, p: saved.append(p)), \
                mock.patch.object(tracker, "official_domains", return_value={"docs.nvidia.com"}), \
                mock.patch.object(tracker, "_get_bytes", return_value=(page, "text/html")):
            result = tracker.attach_readings("c")
        return post, result, saved

    PAGE = (b"<h2>AI Infrastructure</h2><h3>Suggested Readings</h3>"
            b"<a href='https://docs.nvidia.com/dgx'>DGX</a><a href='https://medium.com/p'>Blog</a>")

    def test_only_catalogued_hosts_join_the_topic_sources(self):
        topic = {"id": "2.1", "topic": "2 - AI Infrastructure", "title": "t", "weight": 10,
                 "status": "generated", "sources": ["https://v.example/o.html", "https://hand.example/x"]}
        post, result, _ = self.run_attach({"topics": [topic]}, self.PAGE)
        self.assertEqual(topic["sources"], ["https://v.example/o.html", "https://hand.example/x",
                                            "https://docs.nvidia.com/dgx"])
        self.assertEqual(topic["status"], "generated")                 # sources are not identity
        self.assertEqual(len(post.metadata["readings"]["2 - AI Infrastructure"]), 2)
        self.assertEqual(result["uncatalogued"], ["medium.com"])

    def test_running_it_again_replaces_its_own_additions(self):
        topic = {"id": "2.1", "topic": "2 - AI Infrastructure", "sources": [
            "https://v.example/o.html", "https://docs.nvidia.com/moved-away"]}
        readings = {"2 - AI Infrastructure": [{"title": "Old", "url": "https://docs.nvidia.com/moved-away"}]}
        self.run_attach({"topics": [topic], "readings": readings}, self.PAGE)
        self.assertEqual(topic["sources"], ["https://v.example/o.html", "https://docs.nvidia.com/dgx"])

    def test_a_hand_added_source_the_vendor_also_lists_is_kept(self):
        # Uncatalogued, so attach never added it: it can only be a person's.
        topic = {"id": "2.1", "topic": "2 - AI Infrastructure",
                 "sources": ["https://v.example/o.html", "https://medium.com/p"]}
        self.run_attach({"topics": [topic]}, self.PAGE)
        self.assertIn("https://medium.com/p", topic["sources"])

    def test_a_document_that_cannot_be_read_writes_nothing(self):
        import frontmatter
        readings = {"2 - AI Infrastructure": [{"title": "DGX", "url": "https://docs.nvidia.com/dgx"}]}
        topic = {"id": "2.1", "topic": "2 - AI Infrastructure",
                 "sources": ["https://v.example/o.html", "https://docs.nvidia.com/dgx"]}
        post = frontmatter.Post("", topics=[topic], readings=readings)
        data = {"certs": {"c": {"sources": {"objectives": "https://v.example/o.pdf"}}}}
        with mock.patch.object(tracker.catalog, "load", return_value=data), \
                mock.patch.object(tracker.certs, "load", return_value=post), \
                mock.patch.object(tracker.certs, "save") as save, \
                mock.patch.object(tracker, "_get_bytes", return_value=(b"<html>404</html>", "text/html; but .pdf")), \
                self.assertRaises(tracker.TrackerError):
            tracker.attach_readings("c")
        save.assert_not_called()
        self.assertEqual(post.metadata["readings"], readings)

    def test_nothing_to_change_writes_nothing(self):
        topic = {"id": "2.1", "topic": "2 - AI Infrastructure", "sources": ["https://v.example/o.html"]}
        _, result, saved = self.run_attach({"topics": [topic]}, b"<p>No reading lists here.</p>")
        self.assertEqual((result["domains"], saved), ({}, []))


class SyncAiTests(unittest.TestCase):
    """`teach tracker sync --provider ai` (#271): drift by hash, level and validity by the page."""

    GUIDE = make_pdf([[(700, "1.1 Describe the NVIDIA software stack.", None)]])
    GUIDE_V2 = make_pdf([[(700, "1.1 Describe the NVIDIA software stack and more.", None)]])

    def run_sync(self, cert: dict, answer: dict | None = None, frozen: str | None = None,
                 body: bytes | None = None, url: str = "https://v.example/g.pdf", kind: str = "application/pdf"):
        """One sync over a catalog holding `cert`; the same dict is updated, so calls chain like runs."""
        import frontmatter
        cert.setdefault("category", "ai")
        cert.setdefault("sources", {"objectives": url, "overview": "https://v.example/page"})
        data = {"certs": {"nca-aiio": cert, "cka": {"category": "cloud-native"}}}
        post = frontmatter.Post("", **({"source_sha256": frozen} if frozen else {}))
        with mock.patch.object(tracker.catalog, "load", return_value=data), \
                mock.patch.object(tracker.catalog, "save"), \
                mock.patch.object(tracker.certs, "load", return_value=post), \
                mock.patch.object(tracker.certs, "md_path", return_value=Path(__file__)), \
                mock.patch.object(tracker, "_get_bytes", return_value=(body or self.GUIDE, kind)), \
                mock.patch.object(tracker, "fetch_text", return_value="Certification level: Associate"), \
                mock.patch.object(tracker, "_ai_yaml", return_value=answer or {}) as ai:
            changes = tracker.sync_ai()
        self.assertEqual(ai.call_count, 1)                              # the cka entry is not read
        return cert, changes

    def test_reads_level_and_validity_without_rewording_an_agreeing_validity(self):
        cert, changes = self.run_sync({"level": "essentials", "validity": "2 años"},
                                      {"level": "Associate", "validity_years": 2})
        self.assertEqual((cert["level"], cert["validity"]), ("associate", "2 años"))
        self.assertIn("nca-aiio: level essentials -> associate", changes)

    def test_an_experience_level_is_not_a_tier(self):
        # MCPA prints "Experience Level: Beginner"; the certification is an Associate.
        cert, _ = self.run_sync({"level": "associate"}, {"level": "beginner"})
        self.assertEqual(cert["level"], "associate")

    def test_unknown_changes_nothing(self):
        cert, _ = self.run_sync({"level": "essentials", "validity": "2 años"},
                                {"level": "unknown", "validity_years": "unknown"})
        self.assertEqual((cert["level"], cert["validity"]), ("essentials", "2 años"))

    def test_baseline_then_same_then_changed_then_back(self):
        # All seven AI syllabi predate source_sha256, so this is the path they take.
        cert = {"tracked_version": "unknown", "upstream_status": "current"}
        _, changes = self.run_sync(cert)
        self.assertIn("baseline recorded", " ".join(changes))
        self.assertEqual(cert["upstream_status"], "current")             # a baseline is not a verdict
        _, changes = self.run_sync(cert)
        self.assertEqual((cert["upstream_status"], changes), ("current", ["ai: no upstream changes"]))
        _, changes = self.run_sync(cert, body=self.GUIDE_V2)
        self.assertEqual(cert["upstream_status"], "outdated")
        self.assertIn("changed upstream", " ".join(changes))
        self.assertEqual(cert["tracked_version"], "unknown")             # #63
        _, changes = self.run_sync(cert, body=self.GUIDE_V2)
        self.assertEqual(changes, ["ai: no upstream changes"])          # reported once, not every run
        _, changes = self.run_sync(cert)
        self.assertEqual(cert["upstream_status"], "current")
        self.assertNotIn("objectives_drift", cert)
        self.assertIn("matches again", " ".join(changes))

    def test_drift_never_opens_an_upgrade_window_the_consistency_check_rejects(self):
        # An `upstream:` block is an upgrade window (version, snapshot, milestone);
        # check_curriculum_consistency failed on a hash-only one.
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
        import curriculum_citations
        cert = {"tracked_version": "unknown", "objectives_sha256": "0" * 64}
        self.run_sync(cert)
        self.assertEqual(cert["upstream_status"], "outdated")
        self.assertNotIn("upstream", cert)
        self.assertEqual(curriculum_citations.window(cert), (None, []))

    def test_a_page_is_compared_by_its_text_not_its_bytes(self):
        # MCPA's WordPress page changes a nonce on every fetch.
        page = b"<html><input name='_wpnonce' value='%s'><p>Exam objectives: MCP</p></html>"
        cert = {}
        self.run_sync(cert, body=page % b"a1", url="https://v.example/mcpa/", kind="text/html")
        _, changes = self.run_sync(cert, body=page % b"b2", url="https://v.example/mcpa/", kind="text/html")
        self.assertEqual((cert.get("upstream_status"), changes), ("current", ["ai: no upstream changes"]))

    def test_the_frozen_pdf_hash_supersedes_a_baseline(self):
        digest = hashlib.sha256(self.GUIDE).hexdigest()
        cert = {"upstream_status": "outdated", "objectives_sha256": "x" * 64,
                "objectives_drift": {"sha256": "y"}}
        self.run_sync(cert, frozen=digest)
        self.assertEqual(cert["upstream_status"], "current")
        self.assertNotIn("objectives_sha256", cert)
        self.assertNotIn("objectives_drift", cert)

if __name__ == "__main__":
    unittest.main()
