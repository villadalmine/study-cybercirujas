"""Ciclo de invalidación por cambio de temario.

Se testea porque la parte delicada no es detectar el cambio sino no darlo por
resuelto antes de tiempo: el status vive a nivel de topic pero el contenido
existe una vez por idioma, así que limpiar el flag al regenerar el español
dejaría las traducciones describiendo el temario viejo, en silencio y para
siempre. Ese es el caso que cubre `test_regenerar_default_no_libera_el_resto`.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

CERT_MD = """\
---
cert: testcert
exam: "TEST"
version: '1'
snapshot_date: '2026-07-30'
sources: []
topics:
- id: '1.1'
  title: Changed topic
  topic: 1 - D
  weight: 100
  status: stale
  stale_since: '2026-07-30T03:00:00'
  sources: []
---
# Test
"""

BEFORE_CHANGE = "2026-07-28T10:00:00"
AFTER_CHANGE = "2026-07-30T04:00:00"


class StaleCycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "catalog.yaml").write_text("certs: {}\npaths: {}\n")
        (root / "certs").mkdir()
        (root / "certs" / "testcert.md").write_text(CERT_MD)
        for lang in ("es", "en"):
            d = root / "certs" / "testcert" / "1.1" / lang
            d.mkdir(parents=True)
            (d / "content.md").write_text("# content\n")
            (d / "meta.yaml").write_text(f"generated_at: '{BEFORE_CHANGE}'\nlang: {lang}\n")
        self._prev_root = os.environ.get("TEACH_ROOT")
        os.environ["TEACH_ROOT"] = str(root)

    def tearDown(self) -> None:
        if self._prev_root is None:
            os.environ.pop("TEACH_ROOT", None)
        else:
            os.environ["TEACH_ROOT"] = self._prev_root
        self.tmp.cleanup()

    def _outdated(self) -> list[str]:
        from teach.core import certs

        return certs.topic_outdated_langs("testcert", "1.1")

    def _regenerate(self, lang: str, when: str = AFTER_CHANGE) -> None:
        from teach.core import certs

        meta = certs.content_dir("testcert", "1.1") / lang / "meta.yaml"
        meta.write_text(f"generated_at: '{when}'\nlang: {lang}\n")

    def test_contenido_anterior_al_cambio_queda_marcado(self) -> None:
        self.assertEqual(self._outdated(), ["es", "en"])

    def test_regenerar_default_no_libera_el_resto(self) -> None:
        """El caso que motivó el diseño: rehacer el español no puede dar el
        topic por actualizado mientras haya traducciones sin rehacer."""
        from teach.core import certs

        self._regenerate("es")
        self.assertEqual(self._outdated(), ["en"])
        self.assertEqual(certs.get_topic("testcert", "1.1")["status"], "stale")

    def test_ciclo_se_cierra_cuando_no_queda_ninguno(self) -> None:
        from teach.core import certs

        self._regenerate("es")
        self._regenerate("en")
        self.assertEqual(self._outdated(), [])

        certs.clear_topic_stale("testcert", "1.1")
        topic = certs.get_topic("testcert", "1.1")
        self.assertEqual(topic["status"], "generated")
        self.assertNotIn("stale_since", topic)

    def test_sin_marca_temporal_no_hay_nada_viejo(self) -> None:
        """Un topic que nunca cambió no reporta idiomas desactualizados, por
        más que su contenido sea anterior a cualquier fecha."""
        from teach.core import certs

        certs.clear_topic_stale("testcert", "1.1")
        self.assertEqual(self._outdated(), [])

    def test_meta_ilegible_se_considera_viejo(self) -> None:
        """Ante la duda, regenerar: si no se puede probar que el contenido es
        posterior al cambio, se asume que no lo es."""
        from teach.core import certs

        (certs.content_dir("testcert", "1.1") / "es" / "meta.yaml").unlink()
        self._regenerate("en")
        self.assertEqual(self._outdated(), ["es"])


class SnapshotStatusTest(unittest.TestCase):
    """Detección del cambio en el snapshot, sin tocar disco ni gastar cuota."""

    def _apply(self, incoming, existing):
        from teach.core import tracker

        return tracker._apply_snapshot_status(
            incoming, existing, "http://source", "2026-07-30T03:00:00"
        )

    def test_clasifica_nuevo_cambiado_e_igual(self) -> None:
        existing = {
            "1.1": {"id": "1.1", "title": "Old", "topic": "1 - D", "weight": 10,
                    "status": "generated"},
            "1.2": {"id": "1.2", "title": "Same", "topic": "1 - D", "weight": 10,
                    "status": "generated"},
        }
        incoming = [
            {"id": "1.1", "title": "New", "topic": "1 - D", "weight": 10},
            {"id": "1.2", "title": "Same", "topic": "1 - D", "weight": 10},
            {"id": "1.3", "title": "Fresh", "topic": "1 - D", "weight": 10},
        ]
        added, stale, edited = self._apply(incoming, existing)

        self.assertEqual((added, stale, edited), (["1.3"], ["1.1"], []))
        by_id = {t["id"]: t for t in incoming}
        self.assertEqual(by_id["1.1"]["stale_since"], "2026-07-30T03:00:00")
        self.assertNotIn("stale_since", by_id["1.2"])
        self.assertEqual(by_id["1.2"]["status"], "generated")
        self.assertEqual(by_id["1.3"]["status"], "pending")

    def test_el_peso_tambien_invalida(self) -> None:
        """El peso fija la profundidad que se le pide al modelo, así que un
        cambio de peso cambia el material esperado."""
        existing = {"1.1": {"id": "1.1", "title": "T", "topic": "1 - D", "weight": 10,
                            "status": "generated"}}
        incoming = [{"id": "1.1", "title": "T", "topic": "1 - D", "weight": 25}]
        _, stale, _ = self._apply(incoming, existing)
        self.assertEqual(stale, ["1.1"])

    def test_edited_nunca_se_pisa(self) -> None:
        """Contenido enriquecido a mano se conserva y se reporta aparte para
        que una persona decida, en vez de descartarlo automáticamente."""
        existing = {"1.1": {"id": "1.1", "title": "Old", "topic": "1 - D", "weight": 10,
                            "status": "edited"}}
        incoming = [{"id": "1.1", "title": "New", "topic": "1 - D", "weight": 10}]
        _, stale, edited = self._apply(incoming, existing)

        self.assertEqual(stale, [])
        self.assertEqual(edited, ["1.1"])
        self.assertEqual(incoming[0]["status"], "edited")


if __name__ == "__main__":
    unittest.main()
