"""Piso de calidad: mismo estándar para todos los backends.

Se testea porque el piso solo sirve si es estable. Si los umbrales se mueven
sin querer, el material que hoy pasa deja de pasar (o al revés) y la matriz de
STATUS empieza a mentir en la dirección opuesta.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import unittest

from teach.core import pipeline, quality

CONTENT_OK = "# 1.1 Tema\n\n" + ("Explicación con ejemplos concretos. " * 200) + (
    "\n\n## Referencias\n\n- Kubernetes — https://kubernetes.io/docs/\n"
)
EXERCISES_OK = "# 1.1 Ejercicios\n\n" + ("Paso numerado con su verificación. " * 80) + (
    "\n\n<details><summary>Respuestas</summary>\n\nR1.\n\n</details>\n"
)


class QualityFloorTest(unittest.TestCase):
    def test_material_completo_pasa(self) -> None:
        self.assertEqual(quality.check("content", CONTENT_OK), [])
        self.assertEqual(quality.check("exercises", EXERCISES_OK), [])

    def test_material_corto_se_rechaza(self) -> None:
        problems = quality.check("content", "# Tema\n\nDos frases y nada más.\n")
        self.assertTrue(any("por debajo del mínimo" in p for p in problems))

    def test_content_sin_referencias_se_rechaza(self) -> None:
        """La sección de referencias la pide el prompt explícitamente, y es lo
        que sostiene la política de contenido original con atribución."""
        sin_refs = CONTENT_OK.replace("## Referencias", "## Otra cosa")
        problems = quality.check("content", sin_refs)
        self.assertTrue(any("referencias" in p.lower() for p in problems))

    def test_exercises_sin_details_se_rechaza(self) -> None:
        """El caso real: CNPE generó 18 de 18 ejercicios sin la sección de
        respuestas colapsable, con archivos que por tamaño podían pasar."""
        sin_details = EXERCISES_OK.replace("<details>", "<div>").replace(
            "</details>", "</div>"
        )
        problems = quality.check("exercises", sin_details)
        self.assertTrue(any("details" in p for p in problems))

    def test_referencias_en_otros_idiomas(self) -> None:
        """El material se genera en siete idiomas; el encabezado cambia y el
        piso no puede depender del español."""
        for heading in ("References", "Références", "Referenzen", "Referências",
                        "参考文献"):
            with self.subTest(heading=heading):
                text = CONTENT_OK.replace("## Referencias", f"## {heading}")
                self.assertEqual(quality.check("content", text), [])

    def test_no_empieza_con_titulo(self) -> None:
        problems = quality.check("content", CONTENT_OK.replace("# 1.1 Tema", "1.1 Tema"))
        self.assertTrue(any("no empieza" in p for p in problems))

    def test_tipo_desconocido_no_inventa_reglas(self) -> None:
        self.assertEqual(quality.check("no-existe", "x"), [])


class QualityThresholdsTest(unittest.TestCase):
    """Los umbrales viven en pipeline.yaml y están calibrados contra material
    ya verificado; que sigan por debajo del mínimo observado es lo que evita
    rechazar contenido bueno."""

    def test_umbrales_declarados(self) -> None:
        self.assertEqual(quality.rules("content").get("min_bytes"), 4000)
        self.assertEqual(quality.rules("exercises").get("min_bytes"), 1700)

    def test_piso_por_debajo_del_minimo_observado(self) -> None:
        # cks/cka/ckad/lpi: content.md mínimo observado 4577, exercises 1778.
        self.assertLess(quality.rules("content")["min_bytes"], 4577)
        self.assertLess(quality.rules("exercises")["min_bytes"], 1778)

    def test_sin_bloque_quality_todo_pasa(self) -> None:
        """El piso es opcional: un repo sin `quality` en el YAML no debe romper.
        `pipeline.load` está cacheado, así que se muta el dict devuelto y se
        restaura al salir."""
        config = pipeline.load()
        original = config.pop("quality", None)
        try:
            self.assertEqual(quality.check("content", "corto"), [])
        finally:
            if original is not None:
                config["quality"] = original
        self.assertNotEqual(quality.check("content", "corto"), [])


if __name__ == "__main__":
    unittest.main()
