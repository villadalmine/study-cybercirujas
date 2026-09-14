"""The four functions a study agent gets — and the boundary around them.

Phase 2 of the study bot hands these to a model the student steers; phase 3
hands the same four to agents nobody here controls, over MCP. So two things
matter and are tested here: the search ranks the way it claims to, and the
contract stays a read of the published corpus and nothing else.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import inspect
import unittest

from teach.core import corpus


class ContractTests(unittest.TestCase):
    def test_it_is_the_four_functions_the_design_names(self):
        # "The bot's tools and the MCP tools are the same four functions —
        # design once, ship twice." A fifth appearing here means two callers
        # are about to disagree about what the contract is.
        public = {name for name, value in vars(corpus).items()
                  if inspect.isfunction(value) and not name.startswith("_")}
        self.assertEqual(public, {"list_certs", "get_syllabus", "get_topic",
                                  "search_topics"})

    def test_nothing_in_the_contract_can_write(self):
        # Handed to an agent nobody here controls. Every one of these must be a
        # read of material the site already serves without a login.
        source = inspect.getsource(corpus)
        for forbidden in ("save(", "write_text", "mkdir", "unlink", "subprocess",
                          "complete(", "make_completer"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)


class ListAndSyllabusTests(unittest.TestCase):
    def test_every_listed_certification_can_be_opened(self):
        # A list that names something `get_syllabus` cannot open would send an
        # agent into a 404 it did nothing to deserve.
        for entry in corpus.list_certs():
            with self.subTest(cert=entry["id"]):
                corpus.get_syllabus(entry["id"])

    def test_the_count_matches_what_the_syllabus_holds(self):
        # An empty certification is allowed — `cba` is catalogued with its
        # objectives still locked in a PDF — but it has to say so in the list,
        # or an agent spends a round trip to find out.
        for entry in corpus.list_certs():
            with self.subTest(cert=entry["id"]):
                topics = corpus.get_syllabus(entry["id"])["topics"]
                self.assertEqual(entry["topics"], len(topics))
                self.assertEqual(entry["available"],
                                 sum(1 for t in topics if t["available"]))

    def test_the_syllabus_is_small_enough_to_hand_a_model_whole(self):
        # This is the phase-2 index. The design says "a few hundred tokens";
        # if one certification ever stopped fitting, the design would need to
        # change rather than the page silently truncating.
        syllabus = corpus.get_syllabus("lpi-010-160")
        rendered = sum(len(t["title"] or "") + len(t["id"]) for t in syllabus["topics"])
        self.assertLess(rendered // 4, 1000)

    def test_availability_is_reported_not_assumed(self):
        topics = corpus.get_syllabus("lpi-010-160")["topics"]
        self.assertTrue(any(t["available"] for t in topics))
        for topic in topics:
            self.assertIsInstance(topic["available"], bool)
            self.assertIsInstance(topic["langs"], list)


class SearchTests(unittest.TestCase):
    def test_a_title_hit_outranks_a_domain_hit(self):
        hits = corpus.search_topics("users groups", cert="lpi-010-160")
        self.assertEqual(hits[0]["id"], "5.2")
        self.assertIn("title", hits[0]["why"])

    def test_an_exact_topic_id_wins(self):
        # Someone typing "5.2" means the objective, not a title containing it.
        hits = corpus.search_topics("5.2", cert="cka")
        self.assertEqual(hits[0]["id"], "5.2")
        self.assertIn("id 5.2", hits[0]["why"])

    def test_filler_words_are_dropped_by_measurement_not_by_a_list(self):
        # "and" opens half the objectives ever written, in every language. A
        # term that matches that much of the corpus cannot rank it.
        hits = corpus.search_topics("users and groups", cert="lpi-010-160")
        self.assertNotIn("and", hits[0]["why"])

    def test_a_query_of_nothing_but_filler_still_answers(self):
        # Badly, but it answers: dropping every term would turn a vague
        # question into a silent empty result, which reads as "no such topic".
        self.assertTrue(corpus.search_topics("and", cert="lpi-010-160"))

    def test_accents_and_case_do_not_matter(self):
        # The corpus is seven languages; a Spanish student types "autenticación".
        plain = corpus.search_topics("autenticacion")
        accented = corpus.search_topics("Autenticación")
        self.assertEqual([h["id"] for h in plain], [h["id"] for h in accented])

    def test_the_cert_filter_is_honoured(self):
        hits = corpus.search_topics("network", cert="cka")
        self.assertTrue(hits)
        self.assertEqual({h["cert"] for h in hits}, {"cka"})

    def test_every_hit_explains_itself(self):
        for hit in corpus.search_topics("kubernetes security"):
            with self.subTest(hit=hit["id"]):
                self.assertTrue(hit["why"])

    def test_material_breaks_a_tie(self):
        # A topic nobody can read is a worse answer than one that exists.
        hits = corpus.search_topics("kubernetes", limit=corpus.MAX_LIMIT)
        scores = [(h["score"], h["available"]) for h in hits]
        for (s1, a1), (s2, a2) in zip(scores, scores[1:]):
            if s1 == s2:
                self.assertFalse(a2 and not a1, "unavailable ranked above available")

    def test_a_query_that_matches_nothing_returns_nothing(self):
        self.assertEqual(corpus.search_topics("zzzzzzzzzz"), [])

    def test_the_limit_is_bounded_however_it_is_asked_for(self):
        # It is reachable over HTTP and MCP by callers we do not control.
        self.assertLessEqual(len(corpus.search_topics("a", limit=10_000)),
                             corpus.MAX_LIMIT)
        self.assertTrue(corpus.search_topics("kubernetes", limit=0))


class TopicTests(unittest.TestCase):
    def test_the_material_travels_with_its_sources(self):
        # An agent that can cite the official page can be checked; one that
        # cannot is asking to be believed.
        topic = corpus.get_topic("lpi-010-160", "5.2", "en")
        self.assertIn("/etc/passwd", topic["content"])
        self.assertTrue(topic["sources"])
        self.assertTrue(topic["generated_by"]["model"])

    def test_a_missing_language_says_so_rather_than_pretending(self):
        topic = corpus.get_topic("lpi-010-160", "5.2", "en")
        self.assertIn("lang_fallback", topic)


if __name__ == "__main__":
    unittest.main()
