#!/usr/bin/env python3
"""Tests de la Puerta C extendida en P0.3.

Se ejecutan sin simulador ni Xcode:

    python3 -m unittest discover -s herramientas/tests -v

Cubren los tests negativos obligatorios de la matriz de P0.3: una traza
sembrada con UUID, con un nombre tecnico de herramienta como etiqueta o dentro
de una burbuja, y con un nombre de elemento desconocido. Tambien comprueban
que `--solo-repo` sigue funcionando exactamente igual que antes.
"""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
RUTA_SCRIPT = RAIZ / "herramientas" / "verificar-cierre.py"

_spec = importlib.util.spec_from_file_location("verificar_cierre", RUTA_SCRIPT)
verificador = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verificador)


def escribir(directorio: Path, nombre: str, lineas: list[str]) -> Path:
    ruta = directorio / nombre
    ruta.write_text("\n".join(lineas) + "\n", encoding="utf-8")
    return ruta


TRAZA_P03_VALIDA = [
    '[t=0.0s] UserBubble("Di solo: ok")',
    '[t=0.0s] AssistantBubble("ok")',
    '  [t=0.0s] TextSegment("ok")',
]

TRAZA_P02_VALIDA = [
    '[t=0.0s] UserBubble("Recuerda la palabra clave.")',
    '[t=0.1s] MemoryLineNotice(text: "Guarde en Memoria: palabra clave", '
    "hasUndo: true)",
    '[t=0.2s] AssistantBubble("Listo.")',
    '  [t=0.2s] TextSegment("Listo.")',
]


class TrazaValidaTest(unittest.TestCase):
    def test_p03_cierra(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_P0.3.txt", TRAZA_P03_VALIDA)
            self.assertEqual(
                verificador.verificar_traza(ruta, "P0.3"), []
            )

    def test_p02_cierra_con_una_linea_de_memoria(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_P0.2.txt", TRAZA_P02_VALIDA)
            self.assertEqual(
                verificador.verificar_traza(ruta, "P0.2"), []
            )

    def test_p03_con_dos_lineas_de_memoria_falla_el_conteo_3(self) -> None:
        lineas = TRAZA_P03_VALIDA + [
            '[t=0.1s] MemoryLineNotice(text: "Guarde en Memoria: x", '
            "hasUndo: true)"
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_P0.3.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "P0.3")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)


class TrazasNegativasTest(unittest.TestCase):
    def _fallos(self, lineas: list[str], partida: str = "P0.3") -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(
                Path(tmp), f"ui_transcript_{partida}.txt", lineas
            )
            return verificador.verificar_traza(ruta, partida)

    def test_uuid_sembrado_falla_el_conteo_2(self) -> None:
        lineas = [
            '[t=0.0s] UserBubble("id 123E4567-E89B-12D3-A456-426614174000")'
        ]
        fallos = self._fallos(lineas)
        self.assertTrue(any("Conteo 2" in f for f in fallos), fallos)

    def test_save_memory_como_etiqueta_visible_falla_el_conteo_4(self) -> None:
        # Etiqueta visible (no dentro de una burbuja): ademas de ser un nombre
        # desconocido, el conteo 4 la caza como ocurrencia literal.
        lineas = ['[t=0.0s] save_memory("x")']
        fallos = self._fallos(lineas)
        self.assertTrue(any("Conteo 4" in f for f in fallos), fallos)

    def test_save_memory_dentro_de_una_burbuja_falla_el_conteo_4(self) -> None:
        lineas = ['[t=0.0s] UserBubble("save_memory")']
        fallos = self._fallos(lineas)
        self.assertTrue(any("Conteo 4" in f for f in fallos), fallos)

    def test_delete_memory_como_etiqueta_visible_falla(self) -> None:
        lineas = ['[t=0.0s] delete_memory("x")']
        fallos = self._fallos(lineas)
        self.assertTrue(any("Conteo 4" in f for f in fallos), fallos)

    def test_delete_memory_dentro_de_un_text_segment_falla(self) -> None:
        lineas = [
            '[t=0.0s] AssistantBubble("Listo.")',
            '  [t=0.0s] TextSegment("delete_memory")',
        ]
        fallos = self._fallos(lineas)
        self.assertTrue(any("Conteo 4" in f for f in fallos), fallos)

    def test_nombre_de_elemento_desconocido_falla_la_lista(self) -> None:
        lineas = ['[t=0.0s] TaskStepRow("paso")']
        fallos = self._fallos(lineas)
        self.assertTrue(
            any("etiqueta desconocida" in f for f in fallos), fallos
        )

    def test_text_segment_fuera_de_burbuja_falla_el_contexto(self) -> None:
        lineas = ['[t=0.0s] TextSegment("suelto")']
        fallos = self._fallos(lineas)
        self.assertTrue(
            any("solo es valida anidada" in f for f in fallos), fallos
        )

    def test_text_segment_anidada_sin_burbuja_falla_el_contexto(self) -> None:
        lineas = [
            '[t=0.0s] UserBubble("Hola")',
            '  [t=0.0s] TextSegment("suelto")',
        ]
        fallos = self._fallos(lineas)
        self.assertTrue(
            any("anidada fuera de una AssistantBubble" in f for f in fallos),
            fallos,
        )

    def test_traza_vacia_falla(self) -> None:
        fallos = self._fallos([])
        self.assertTrue(
            any("no contiene ningun elemento" in f for f in fallos), fallos
        )

    def test_linea_sin_formato_falla(self) -> None:
        fallos = self._fallos(["UserBubble sin tiempo"])
        self.assertTrue(any("no tiene el formato" in f for f in fallos), fallos)

    def test_nombre_de_traza_no_valido_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_bloque1.txt", TRAZA_P03_VALIDA)
            fallos = verificador.verificar_traza(ruta, "P0.3")
            self.assertTrue(any("Nombre de traza no valido" in f for f in fallos))

    def test_traza_ausente_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = Path(tmp) / "ui_transcript_P0.3.txt"
            fallos = verificador.verificar_traza(ruta, "P0.3")
            self.assertEqual(fallos, ["Falta la traza: ui_transcript_P0.3.txt"])

    def test_directorio_rechaza_nombres_invalidos_y_faltantes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            escribir(directorio, "ui_transcript_P0.3.txt", TRAZA_P03_VALIDA)
            escribir(directorio, "ui_transcript_P0_3.txt", TRAZA_P03_VALIDA)
            escribir(directorio, "uitranscript_P0.3.txt", TRAZA_P03_VALIDA)
            fallos = verificador.verificar_trazas(directorio, ["P0.3", "P0.2"])
            self.assertTrue(
                any("Nombre de traza no valido" in f for f in fallos), fallos
            )
            self.assertTrue(
                any("Falta la traza de P0.2" in f for f in fallos), fallos
            )

    def test_b26_archiva_varias_trazas_con_sufijo_de_caso(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            escribir(
                directorio,
                "ui_transcript_B2.6-sensible-salud.txt",
                TRAZA_P03_VALIDA,
            )
            self.assertEqual(
                verificador.verificar_trazas(directorio, ["B2.6"]), []
            )


class ProgresoVivoTest(unittest.TestCase):
    def _fallos(self, lineas: list[str]) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-B.txt", lineas)
            return verificador.verificar_traza(ruta, "B3-B")

    def test_b3_b_sin_declaracion_de_modo_falla(self) -> None:
        lineas = ['[t=0.0s] TaskHeader(estado: "En curso", pasoActual: 1, '
                  "pasosTotales: 2, costoSellado: \"0\")"]
        fallos = self._fallos(lineas)
        self.assertTrue(any("no declara modo" in f for f in fallos), fallos)

    def test_replay_sin_espera_suficiente_falla(self) -> None:
        lineas = [
            "modo: replay-temporizado",
            '[t=0.0s] UserBubble("Hola")',
            '[t=0.5s] AssistantBubble("Listo")',
            '  [t=0.5s] TextSegment("Listo")',
        ]
        fallos = self._fallos(lineas)
        self.assertTrue(any("espera de red comprobada" in f for f in fallos), fallos)

    def test_replay_con_hueco_de_dos_segundos_cierra(self) -> None:
        lineas = [
            "modo: replay-temporizado",
            '[t=0.0s] UserBubble("Hola")',
            '[t=2.4s] AssistantBubble("Listo")',
            '  [t=2.4s] TextSegment("Listo")',
        ]
        self.assertEqual(self._fallos(lineas), [])

    def test_vivo_con_tramo_de_dos_segundos_cierra(self) -> None:
        lineas = [
            "modo: vivo",
            '[t=0.0s] UserBubble("Hola")',
            '[t=2.3s] AssistantBubble("Listo")',
            '  [t=2.3s] TextSegment("Listo")',
        ]
        self.assertEqual(self._fallos(lineas), [])

    def test_vivo_sin_tramo_de_espera_falla(self) -> None:
        lineas = [
            "modo: vivo",
            '[t=0.0s] UserBubble("Hola")',
            '[t=0.4s] AssistantBubble("Listo")',
            '  [t=0.4s] TextSegment("Listo")',
        ]
        fallos = self._fallos(lineas)
        self.assertTrue(any("espera de red comprobada" in f for f in fallos), fallos)

    def test_replay_con_latido_cada_quince_cierra(self) -> None:
        # Sin hueco >= 2,0 s: la espera se prueba por la racha de latidos
        # (huecos <= 1,5 s) que cubre 3,0 s.
        lineas = [
            "modo: replay-temporizado",
            '[t=0.0s] UserBubble("Hola")',
            '[t=1.4s] StreamingBubble("Paso 1/3")',
            '[t=2.8s] StreamingBubble("Paso 2/3")',
            '[t=3.0s] AssistantBubble("Listo")',
            '  [t=3.0s] TextSegment("Listo")',
        ]
        self.assertEqual(self._fallos(lineas), [])

    def test_modo_desconocido_falla(self) -> None:
        lineas = ["modo: casi-vivo", '[t=0.0s] UserBubble("Hola")']
        fallos = self._fallos(lineas)
        self.assertTrue(any("modo desconocido" in f for f in fallos), fallos)


class SoloRepoTest(unittest.TestCase):
    def test_solo_repo_sigue_cerrando_sin_trazas(self) -> None:
        resultado = subprocess.run(
            [sys.executable, str(RUTA_SCRIPT), "--solo-repo"],
            capture_output=True,
            text=True,
            cwd=str(RAIZ),
        )
        self.assertEqual(resultado.returncode, 0, resultado.stdout + resultado.stderr)
        self.assertIn("Cierre verificado", resultado.stdout)

    def test_solo_repo_ignora_humos_y_trazas(self) -> None:
        # Aunque se le pasen rutas inexistentes, --solo-repo no mira log,
        # humos ni trazas: es la parte que corre en CI y no cambia.
        resultado = subprocess.run(
            [
                sys.executable,
                str(RUTA_SCRIPT),
                "--solo-repo",
                "--humos",
                "/ruta/que/no/existe",
                "--partidas",
                "P0.3",
            ],
            capture_output=True,
            text=True,
            cwd=str(RAIZ),
        )
        self.assertEqual(resultado.returncode, 0, resultado.stdout + resultado.stderr)


if __name__ == "__main__":
    unittest.main()
