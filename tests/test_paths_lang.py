"""Career paths are served in the language that was asked for.

A path's base fields are whatever language it was WRITTEN in — Spanish, here —
and the translations sit under `i18n`. "The language it was written in" and
"the platform's default language" are not the same thing, and treating them as
one was a live bug: `/api/paths` returned the base fields untouched whenever the
requested language equalled `certs.DEFAULT_LANG`. That was correct while the
default was `es`, and wrong from the moment English became the authoring
language on 2026-08-04 — so every English visitor read "Ingeniero Kubernetes"
while `i18n.en` held "Kubernetes Engineer".

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import unittest

from fastapi.testclient import TestClient

from teach.api import app
from teach.core import catalog, certs


class PathLanguageTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        self.raw = catalog.load().get("paths", {})

    def _translated(self, lang):
        """Paths that actually carry a translation for this language."""
        return {slug: (p.get("i18n") or {})[lang]
                for slug, p in self.raw.items()
                if (p.get("i18n") or {}).get(lang, {}).get("name")}

    def test_the_default_language_is_translated_like_any_other(self):
        # The bug in one line: `en` is the default, so it used to skip the merge.
        served = self.client.get(f"/api/paths?lang={certs.DEFAULT_LANG}").json()
        wanted = self._translated(certs.DEFAULT_LANG)
        self.assertTrue(wanted, "no path carries a default-language translation")
        for slug, translation in wanted.items():
            with self.subTest(slug=slug):
                self.assertEqual(served[slug]["name"], translation["name"])

    def test_every_language_gets_its_own_names(self):
        for lang in certs.LANGS:
            served = self.client.get(f"/api/paths?lang={lang}").json()
            for slug, translation in self._translated(lang).items():
                with self.subTest(lang=lang, slug=slug):
                    self.assertEqual(served[slug]["name"], translation["name"])

    def test_an_untranslated_path_keeps_what_it_has(self):
        # Falling through to the base fields is right; returning nothing is not.
        for lang in certs.LANGS:
            served = self.client.get(f"/api/paths?lang={lang}").json()
            for slug, path in self.raw.items():
                with self.subTest(lang=lang, slug=slug):
                    self.assertTrue(served[slug].get("name"))
                    # steps/requires_all are structure, never translated
                    if "steps" in path:
                        self.assertEqual(served[slug]["steps"], path["steps"])

    def test_the_i18n_block_itself_is_not_served(self):
        # Shipping every translation to every visitor would send seven copies
        # of the same page to read one.
        served = self.client.get("/api/paths?lang=en").json()
        for slug in served:
            with self.subTest(slug=slug):
                self.assertNotIn("i18n", served[slug])


if __name__ == "__main__":
    unittest.main()
