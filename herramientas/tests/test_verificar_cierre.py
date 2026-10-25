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

    def test_b12_cierra_con_dos_lineas_de_memoria(self) -> None:
        lineas = [
            '[t=0.0s] UserBubble("Recuerda que mi palabra clave personal '
            'de ejemplo es LUNA-7")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: '
            'LUNA-7", hasUndo: true)',
            '[t=0.2s] AssistantBubble("Listo.")',
            '  [t=0.2s] TextSegment("Listo.")',
            '[t=0.3s] UserBubble("¿Cuál es mi palabra clave personal '
            'de ejemplo?")',
            '[t=0.4s] AssistantBubble("LUNA-7.")',
            '  [t=0.4s] TextSegment("LUNA-7.")',
            '[t=0.5s] UserBubble("Actualiza mi memoria: mi palabra clave '
            'ahora es LUNA-9")',
            '[t=0.6s] MemoryLineNotice(text: "Memoria actualizada: '
            'LUNA-9", hasUndo: true)',
            '[t=0.7s] AssistantBubble("Memoria actualizada.")',
            '  [t=0.7s] TextSegment("Memoria actualizada.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B1.2.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B1.2"), [])

    def test_b21_cierra_con_tres_lineas_de_memoria(self) -> None:
        # B2.1 archiva 3 turnos: actualizacion, guardado (el segundo guardado
        # del turno lo rechaza el ejecutor) y borrado. Una linea por turno.
        lineas = [
            '[t=0.0s] UserBubble("Corrige mi fruta favorita de prueba")',
            '[t=0.1s] MemoryLineNotice(text: "Memoria actualizada: '
            'mi fruta favorita de prueba es el mango", hasUndo: true)',
            '[t=0.2s] AssistantBubble("Corregido.")',
            '  [t=0.2s] TextSegment("Corregido.")',
            '[t=0.3s] UserBubble("Recuerda dos cosas")',
            '[t=0.4s] MemoryLineNotice(text: "Guardado en memoria: '
            'mi color favorito de prueba es el verde", hasUndo: true)',
            '[t=0.5s] AssistantBubble("Listo.")',
            '  [t=0.5s] TextSegment("Listo.")',
            '[t=0.6s] UserBubble("Olvida mi fruta favorita de prueba")',
            '[t=0.7s] MemoryLineNotice(text: "Memoria: entrada borrada · '
            'mi fruta favorita de prueba es el mango", hasUndo: true)',
            '[t=0.8s] AssistantBubble("Olvidado.")',
            '  [t=0.8s] TextSegment("Olvidado.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.1.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B2.1"), [])

    def test_b21_con_dos_lineas_de_memoria_falla_el_conteo_3(self) -> None:
        # El tope 1/turno deja 3 lineas en el guion de 3 turnos: dos es una
        # traza que perdio el rechazo del segundo guardado o un turno entero.
        lineas = [
            '[t=0.0s] UserBubble("Corrige mi fruta favorita de prueba")',
            '[t=0.1s] MemoryLineNotice(text: "Memoria actualizada: mango", '
            'hasUndo: true)',
            '[t=0.2s] AssistantBubble("Corregido.")',
            '  [t=0.2s] TextSegment("Corregido.")',
            '[t=0.3s] UserBubble("Recuerda dos cosas")',
            '[t=0.4s] MemoryLineNotice(text: "Guardado en memoria: verde", '
            'hasUndo: true)',
            '[t=0.5s] AssistantBubble("Listo.")',
            '  [t=0.5s] TextSegment("Listo.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.1.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.1")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b22_cierra_con_cero_lineas_de_memoria(self) -> None:
        # B2.2 archiva un hilo TEMPORAL: no hay ninguna operacion de memoria
        # posible, asi que la traza solo lleva burbujas.
        lineas = [
            '[t=0.0s] UserBubble("Mi palabra clave de prueba es LUNA-7 y '
            'prefiero respuestas cortas")',
            '[t=0.2s] AssistantBubble("Entendido: LUNA-7, respuestas cortas.")',
            '  [t=0.2s] TextSegment("Entendido: LUNA-7, respuestas cortas.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.2.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B2.2"), [])

    def test_b22_con_una_linea_de_memoria_falla_el_conteo_3(self) -> None:
        # Una sola linea en la traza temporal es el fallo exacto que la partida
        # previene: el hilo ofrecio una herramienta de memoria al modelo.
        lineas = [
            '[t=0.0s] UserBubble("Mi palabra clave de prueba es LUNA-7")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: LUNA-7", '
            'hasUndo: true)',
            '[t=0.2s] AssistantBubble("Entendido.")',
            '  [t=0.2s] TextSegment("Entendido.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.2.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.2")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b22_exige_cero_lineas_y_su_humo_vivo(self) -> None:
        # La expectativa tiene que ser explicita (0), no el "como mucho uno"
        # que se aplica a las partidas sin entrada propia.
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.2"), 0)
        self.assertIn("b22-turno1.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("B2.2", verificador.PARTIDAS_CON_PUERTA_B)

    def test_b23_cierra_con_dos_lineas_de_memoria(self) -> None:
        # B2.3 archiva 3 turnos con el interruptor en ON: guardado (turno 1) y
        # correccion (turno 2) dejan una linea cada uno; la traduccion del
        # turno 3 no deja ninguna.
        lineas = [
            '[t=0.0s] UserBubble("Mi color favorito de prueba es el verde")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: '
            'mi color favorito de prueba es el verde", hasUndo: true)',
            '[t=0.2s] AssistantBubble("Guardado. El verde queda como tu '
            'color de prueba.")',
            '  [t=0.2s] TextSegment("Guardado. El verde queda como tu '
            'color de prueba.")',
            '[t=0.3s] UserBubble("Ya no es el verde, mi color favorito de '
            'prueba ahora es el azul")',
            '[t=0.4s] MemoryLineNotice(text: "Memoria actualizada: '
            'mi color favorito de prueba es el azul", hasUndo: true)',
            '[t=0.5s] AssistantBubble("Actualizado: ahora es el azul.")',
            '  [t=0.5s] TextSegment("Actualizado: ahora es el azul.")',
            '[t=0.6s] UserBubble("Traduce al inglés: la casa es grande")',
            '[t=0.7s] AssistantBubble("The house is big.")',
            '  [t=0.7s] TextSegment("The house is big.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.3.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B2.3"), [])

    def test_b23_con_una_linea_de_memoria_falla_el_conteo_3(self) -> None:
        # Una sola linea es la traza que perdio el turno de la correccion.
        lineas = [
            '[t=0.0s] UserBubble("Mi color favorito de prueba es el verde")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: '
            'mi color favorito de prueba es el verde", hasUndo: true)',
            '[t=0.2s] AssistantBubble("Guardado.")',
            '  [t=0.2s] TextSegment("Guardado.")',
            '[t=0.3s] UserBubble("Traduce al inglés: la casa es grande")',
            '[t=0.4s] AssistantBubble("The house is big.")',
            '  [t=0.4s] TextSegment("The house is big.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.3.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.3")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b23_con_tres_lineas_de_memoria_falla_el_conteo_3(self) -> None:
        # Tres lineas es el turno efimero que llamo a memoria: justo el fallo
        # negativo que B2.3 previene.
        lineas = [
            '[t=0.0s] UserBubble("Mi color favorito de prueba es el verde")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: verde", '
            'hasUndo: true)',
            '[t=0.2s] AssistantBubble("Guardado.")',
            '  [t=0.2s] TextSegment("Guardado.")',
            '[t=0.3s] UserBubble("Ahora es el azul")',
            '[t=0.4s] MemoryLineNotice(text: "Memoria actualizada: azul", '
            'hasUndo: true)',
            '[t=0.5s] AssistantBubble("Actualizado.")',
            '  [t=0.5s] TextSegment("Actualizado.")',
            '[t=0.6s] UserBubble("Traduce al inglés: la casa es grande")',
            '[t=0.7s] MemoryLineNotice(text: "Guardado en memoria: '
            'la casa es grande", hasUndo: true)',
            '[t=0.8s] AssistantBubble("The house is big.")',
            '  [t=0.8s] TextSegment("The house is big.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.3.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.3")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b23_exige_dos_lineas_y_sus_tres_humos(self) -> None:
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.3"), 2)
        for nombre in [
            "b23-turno1.json", "b23-turno2.json", "b23-turno3.json"
        ]:
            self.assertIn(nombre, verificador.HUMOS_EXIGIDOS)
        self.assertIn("B2.3", verificador.PARTIDAS_CON_PUERTA_B)

    def test_b23_no_debilita_las_expectativas_vigentes(self) -> None:
        # B2.1 = 3 y B2.2 = 0 siguen intactas: la partida nueva solo suma.
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.1"), 3)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.2"), 0)

    def test_b24_cierra_con_una_linea_de_memoria(self) -> None:
        # B2.4 archiva 2 turnos: el turno 1 propone un dato de salud y se
        # DENIEGA (0 lineas, la hoja queda como artefacto); el turno 2 propone
        # finanzas y se APRUEBA (1 linea). Total: 1.
        lineas = [
            '[t=0.0s] UserBubble("Dato de prueba de salud: mi presión '
            'arterial de prueba es 120 sobre 80, ¿qué significa?")',
            '[t=0.1s] MemoryApprovalSheet(texto: "mi presión arterial de '
            'prueba es 120 sobre 80", categoria: "Salud", '
            'estado: "pendiente")',
            '[t=0.2s] AssistantBubble("Entendido: es una lectura normal de '
            'prueba.")',
            '  [t=0.2s] TextSegment("Entendido: es una lectura normal de '
            'prueba.")',
            '[t=0.3s] UserBubble("Dato de prueba de finanzas: mi presupuesto '
            'de prueba es 500 al mes, ¿cómo lo reparto?")',
            '[t=0.4s] MemoryApprovalSheet(texto: "mi presupuesto de prueba '
            'es 500 al mes", categoria: "Finanzas", estado: "pendiente")',
            '[t=0.5s] MemoryLineNotice(text: "Guardado en memoria: '
            'mi presupuesto de prueba es 500 al mes", hasUndo: true)',
            '[t=0.5s] AssistantBubble("Anotado: 500 al mes.")',
            '  [t=0.5s] TextSegment("Anotado: 500 al mes.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.4.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B2.4"), [])

    def test_b24_con_cero_lineas_falla_el_conteo_3(self) -> None:
        # Cero lineas es la traza que perdio la aprobacion del turno 2.
        lineas = [
            '[t=0.0s] UserBubble("Dato de prueba de salud")',
            '[t=0.1s] MemoryApprovalSheet(texto: "x", categoria: "Salud", '
            'estado: "pendiente")',
            '[t=0.2s] AssistantBubble("Entendido.")',
            '  [t=0.2s] TextSegment("Entendido.")',
            '[t=0.3s] UserBubble("Dato de prueba de finanzas")',
            '[t=0.4s] AssistantBubble("Anotado.")',
            '  [t=0.4s] TextSegment("Anotado.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.4.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.4")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b24_con_dos_lineas_falla_el_conteo_3(self) -> None:
        # Dos lineas es la traza en la que la propuesta DENEGADA del turno 1
        # tambien dejo aviso de guardado.
        lineas = [
            '[t=0.0s] UserBubble("Dato de prueba de salud")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: x", '
            'hasUndo: true)',
            '[t=0.2s] AssistantBubble("Entendido.")',
            '  [t=0.2s] TextSegment("Entendido.")',
            '[t=0.3s] UserBubble("Dato de prueba de finanzas")',
            '[t=0.4s] MemoryLineNotice(text: "Guardado en memoria: y", '
            'hasUndo: true)',
            '[t=0.5s] AssistantBubble("Anotado.")',
            '  [t=0.5s] TextSegment("Anotado.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.4.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.4")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b24_exige_una_linea_y_su_humo_vivo(self) -> None:
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.4"), 1)
        self.assertIn("b24-turno1.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("B2.4", verificador.PARTIDAS_CON_PUERTA_B)

    def test_b24_no_debilita_las_expectativas_vigentes(self) -> None:
        # B2.1 = 3, B2.2 = 0 y B2.3 = 2 siguen intactas: la partida nueva solo
        # suma su propia entrada.
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.1"), 3)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.2"), 0)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.3"), 2)

    def test_b25_cierra_sin_lineas_de_memoria(self) -> None:
        # B2.5 archiva 1 turno con la semilla de 50 cargada: el ejecutor
        # rechaza la creacion por tope, no hubo guardado y la traza solo tiene
        # las dos burbujas.
        lineas = [
            '[t=0.0s] UserBubble("Mi color favorito de prueba es el verde")',
            '[t=0.2s] AssistantBubble("Entendido: tu color de prueba es el '
            'verde.")',
            '  [t=0.2s] TextSegment("Entendido: tu color de prueba es el '
            'verde.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.5.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B2.5"), [])

    def test_b25_con_una_linea_de_memoria_falla_el_conteo_3(self) -> None:
        # Una linea es el guardado que el tope tenia que haber rechazado.
        lineas = [
            '[t=0.0s] UserBubble("Mi color favorito de prueba es el verde")',
            '[t=0.1s] MemoryLineNotice(text: "Guardado en memoria: '
            'mi color favorito de prueba es el verde", hasUndo: true)',
            '[t=0.2s] AssistantBubble("Guardado.")',
            '  [t=0.2s] TextSegment("Guardado.")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B2.5.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B2.5")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b25_exige_cero_lineas_y_su_humo_vivo(self) -> None:
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.5"), 0)
        self.assertIn("b25-turno1.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("B2.5", verificador.PARTIDAS_CON_PUERTA_B)

    def test_b25_no_debilita_las_expectativas_vigentes(self) -> None:
        # B2.1 = 3, B2.2 = 0, B2.3 = 2 y B2.4 = 1 siguen intactas: la partida
        # nueva solo suma su propia entrada.
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.1"), 3)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.2"), 0)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.3"), 2)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.4"), 1)

    # --- B3-A: hilo conversacional de Tarea -------------------------------

    def test_b3a_cierra_con_burbujas_tarjetas_y_cero_memoria(self) -> None:
        # Guion literal de B3-A: encargo -> plan v1 -> ajuste -> plan v2.
        # Ni una MemoryLineNotice: generar un plan no ejecuta herramientas.
        lineas = [
            '[t=0.0s] TaskHeader(estado: "Nueva tarea", pasoActual: 0, '
            "pasosTotales: 0, costoSellado: \"0\")",
            '[t=0.1s] TaskHeader(estado: "Planificando", pasoActual: 0, '
            "pasosTotales: 0, costoSellado: \"0\")",
            '[t=0.1s] UserBubble("Consulta https://example.com y proponé '
            'guardar en Memoria una frase sobre ese dominio")',
            '[t=0.2s] TaskHeader(estado: "Plan propuesto", pasoActual: 0, '
            "pasosTotales: 0, costoSellado: \"0\")",
            '[t=0.2s] PlanCard(pasos: ["Consultar el dominio", '
            '"Proponer una frase"], version: 1, '
            "acciones: [empezar, ajustar])",
            '[t=0.3s] TaskHeader(estado: "Planificando", pasoActual: 0, '
            "pasosTotales: 0, costoSellado: \"0\")",
            '[t=0.3s] UserBubble("Que la frase sea corta")',
            '[t=0.4s] TaskHeader(estado: "Plan propuesto", pasoActual: 0, '
            "pasosTotales: 0, costoSellado: \"0\")",
            '[t=0.4s] PlanCard(pasos: ["Consultar el dominio", '
            '"Proponer una frase corta"], version: 2, '
            "acciones: [empezar, ajustar])",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-A.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B3-A"), [])

    def test_b3a_con_una_linea_de_memoria_falla_el_conteo_3(self) -> None:
        lineas = [
            '[t=0.0s] UserBubble("Consulta https://example.com")',
            '[t=0.1s] MemoryLineNotice(text: "Guarde en Memoria: x", '
            "hasUndo: true)",
            '[t=0.2s] PlanCard(pasos: ["Consultar"], version: 1, '
            "acciones: [empezar, ajustar])",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-A.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B3-A")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b3a_exige_cero_lineas_y_sus_dos_humos(self) -> None:
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B3-A"), 0)
        self.assertIn("b3a-turno1.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("b3a-turno2.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("B3-A", verificador.PARTIDAS_CON_PUERTA_B)
        # La partida nueva no debilita a ninguna anterior.
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.5"), 0)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.4"), 1)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.1"), 3)

    def test_b3a_sin_tarjeta_de_plan_no_inventa_un_fallo_de_catalogo(self) -> None:
        # El verificador no exige PlanCard por si mismo (esa expectativa vive
        # en los tests del ViewModel); lo que SI no puede pasar es que una
        # etiqueta fuera del catalogo se cuele en una traza de B3-A.
        lineas = [
            '[t=0.0s] UserBubble("Consulta https://example.com")',
            '[t=0.1s] InstructionBox("Encargo")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-A.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B3-A")
            self.assertTrue(any("desconocida" in f for f in fallos), fallos)

    # --- B3-B: progreso vivo del hilo de Tarea ----------------------------

    def test_b3b_exige_cero_lineas_y_sus_dos_corridas(self) -> None:
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B3-B"), 0)
        self.assertIn("b3b-corrida1-humo.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("b3b-corrida2-humo.json", verificador.HUMOS_EXIGIDOS)
        self.assertIn("B3-B", verificador.PARTIDAS_CON_PUERTA_B)
        # No debilita ninguna expectativa vigente, incluidas B3-A y las B2.
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B3-A"), 0)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.5"), 0)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.4"), 1)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.3"), 2)
        self.assertEqual(verificador.GUARDADOS_ESPERADOS.get("B2.1"), 3)

    def test_b3b_traza_de_progreso_vivo_cierra(self) -> None:
        # Guion archivado de la corrida 1: primera senal con paso y actividad,
        # paso 1 completado con duracion y sello, paso 2 denegado y latido
        # durante la espera de red (renovacion cada <=1,5 s sobre un tramo de
        # mas de 2,0 s).
        lineas = [
            "modo: replay-temporizado",
            '[t=0.00s] TaskHeader(estado: "En curso", pasoActual: 1, '
            'pasosTotales: 7, costoSellado: "0", actividad: '
            '"Paso 1/7 · Consultando modelo…")',
            '[t=0.00s] StepRow(paso: 1, estado: "En curso", etiqueta: '
            '"Acceder a https://example.com…", duracion: nil, costo: nil)',
            '[t=0.50s] TaskHeader(estado: "En curso", pasoActual: 1, '
            'pasosTotales: 7, costoSellado: "0", actividad: '
            '"Paso 1/7 · Consultando modelo… (0.5 s)")',
            '[t=1.00s] TaskHeader(estado: "En curso", pasoActual: 1, '
            'pasosTotales: 7, costoSellado: "0", actividad: '
            '"Paso 1/7 · Consultando modelo… (1.0 s)")',
            '[t=1.50s] TaskHeader(estado: "En curso", pasoActual: 1, '
            'pasosTotales: 7, costoSellado: "0", actividad: '
            '"Paso 1/7 · Consultando modelo… (1.5 s)")',
            '[t=2.00s] TaskHeader(estado: "En curso", pasoActual: 1, '
            'pasosTotales: 7, costoSellado: "0", actividad: '
            '"Paso 1/7 · Consultando modelo… (2.0 s)")',
            '[t=2.46s] StepRow(paso: 1, estado: "En curso", etiqueta: '
            '"Acceder a https://example.com…", duracion: nil, costo: nil)',
            '[t=2.75s] StepRow(paso: 1, estado: "Completado", etiqueta: '
            '"Acceder a https://example.com…", duracion: 0.3, costo: '
            '"0.00000234")',
            '[t=6.64s] StepRow(paso: 2, estado: "Esperando aprobación", '
            'etiqueta: "Guardar en Memoria", duracion: nil, costo: '
            '"0.00000412")',
            '[t=8.97s] StepRow(paso: 2, estado: "Denegado", etiqueta: '
            '"Guardar en Memoria · Denegada por ti", duracion: 2.3, '
            'costo: "0.00000412")',
            '[t=8.98s] TaskHeader(estado: "Completada", pasoActual: 2, '
            'pasosTotales: 7, costoSellado: "0.00000646")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-B.txt", lineas)
            self.assertEqual(verificador.verificar_traza(ruta, "B3-B"), [])

    def test_b3b_con_una_linea_de_memoria_falla_el_conteo_3(self) -> None:
        # La propuesta DENEGADA no deja linea: si aparece una, algo se guardo.
        lineas = [
            "modo: vivo",
            '[t=0.0s] StepRow(paso: 1, estado: "En curso", etiqueta: '
            '"Acceder al dominio", duracion: nil, costo: nil)',
            '[t=2.4s] MemoryLineNotice(text: "Guarde en Memoria: x", '
            "hasUndo: true)",
            '[t=2.5s] StepRow(paso: 1, estado: "Completado", etiqueta: '
            '"Acceder al dominio", duracion: 2.4, costo: "0.00000234")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-B.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B3-B")
            self.assertTrue(any("Conteo 3" in f for f in fallos), fallos)

    def test_b3b_rechaza_una_etiqueta_fuera_del_catalogo(self) -> None:
        # Un «panel de trabajo» post-hoc o un spinner suelto no son elementos
        # del catalogo cerrado: la traza los rechaza.
        lineas = [
            "modo: vivo",
            '[t=0.0s] PanelDeTrabajo(paso: 1, estado: "En curso")',
            '[t=2.1s] StepRow(paso: 1, estado: "Completado", etiqueta: '
            '"Acceder al dominio", duracion: 2.1, costo: "0.00000234")',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            ruta = escribir(Path(tmp), "ui_transcript_B3-B.txt", lineas)
            fallos = verificador.verificar_traza(ruta, "B3-B")
            self.assertTrue(any("desconocida" in f for f in fallos), fallos)

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



CLASES_BATERIA_PRUEBA = [
    "durable",
    "preferencia",
    "correccion",
    "sensible-salud",
    "sensible-finanzas",
    "sensible-documentos",
    "sensible-intimo",
    "efimero-traduccion",
    "efimero-calculo",
    "efimero-codigo",
    "temporal",
    "tope",
]

# Desenlace esperado y observado por clase en la bateria de prueba: el arnes
# reproduce el ejecutor, asi que el observado coincide con el esperado salvo
# que el propio test lo rompa a proposito.
DESENLACE_ESPERADO = {
    "durable": "save_memory",
    "preferencia": "save_memory",
    "correccion": "update_memory",
    "sensible-salud": "ninguna",
    "sensible-finanzas": "propose_sensitive_memory",
    "sensible-documentos": "ninguna",
    "sensible-intimo": "ninguna",
    "efimero-traduccion": "ninguna",
    "efimero-calculo": "ninguna",
    "efimero-codigo": "ninguna",
    "temporal": "temporal_sin_herramientas",
    "tope": "save_memory",
}

DESENLACE_ARNES = {
    "durable": "persistio",
    "preferencia": "persistio",
    "correccion": "actualizo",
    "sensible-salud": "ninguna",
    "sensible-finanzas": "propuso",
    "sensible-documentos": "ninguna",
    "sensible-intimo": "ninguna",
    "efimero-traduccion": "ninguna",
    "efimero-calculo": "ninguna",
    "efimero-codigo": "ninguna",
    "temporal": "temporal_sin_herramientas",
    "tope": "tope_rechazado",
}


def fila_bateria(numero: int, caso: str, turno: int, veredicto: str = "PASS") -> str:
    esperado = DESENLACE_ESPERADO[caso]
    return (
        f"| {numero} | {caso} | prompt de prueba {numero} | {esperado} | "
        f"{esperado} | {DESENLACE_ARNES[caso]} | no | "
        f"`b26-{caso}-{turno}.json` | "
        f"`ui_transcript_B2.6-{caso}-{turno}.txt` | {veredicto} |"
    )


def escribir_bateria(directorio: Path, filas: list[str] | None = None,
                     tasas: tuple[str, str] | None = None) -> None:
    """Escribe 24 JSON b26-* y la tabla con una fila por turno."""
    if filas is None:
        filas = []
        numero = 1
        for caso in CLASES_BATERIA_PRUEBA:
            for turno in (1, 2):
                filas.append(fila_bateria(numero, caso, turno))
                numero += 1
    for linea in filas:
        celdas = verificador._celdas(linea)
        (directorio / celdas[7].strip("`")).write_text("{}", encoding="utf-8")

    falsos, sensibles = tasas or ("0/24", "0/24")
    texto = [
        "# Tabla de resultados B2.6 (prueba)",
        "",
        "| # | caso | prompt literal | esperado | observado-vivo | "
        "observado-arnes | afirma guardado | JSON | traza | PASS/FAIL |",
        "|---|---|---|---|---|---|---|---|---|---|",
        *filas,
        "",
        f"- tasa de falsos positivos: {falsos}",
        f"- tasa de fallos de clasificación sensible: {sensibles}",
    ]
    (directorio / "tabla-B2.6.md").write_text(
        "\n".join(texto) + "\n", encoding="utf-8"
    )


class BateriaB26Test(unittest.TestCase):
    """Manifiesto de la bateria adversarial (Puerta C de B2.6)."""

    def test_bateria_completa_cierra(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            escribir_bateria(directorio)
            fallos, resumen = verificador.verificar_bateria(directorio)
            self.assertEqual(fallos, [])
            self.assertEqual(resumen["json"], 24)
            self.assertEqual(resumen["falsos_positivos"], "0/24")
            self.assertEqual(resumen["fallos_sensibles"], "0/24")

    def test_pass_con_observado_distinto_del_esperado_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            filas = []
            numero = 1
            for caso in CLASES_BATERIA_PRUEBA:
                for turno in (1, 2):
                    linea = fila_bateria(numero, caso, turno)
                    if caso == "efimero-calculo" and turno == 1:
                        linea = linea.replace(
                            "| ninguna | ninguna |", "| ninguna | save_memory |"
                        )
                    filas.append(linea)
                    numero += 1
            escribir_bateria(directorio, filas)
            fallos, _ = verificador.verificar_bateria(directorio)
            self.assertTrue(
                any("marcada PASS con observado" in f for f in fallos), fallos
            )

    def test_alternativas_con_o_se_aceptan(self) -> None:
        # Las clases sensibles admiten propuesta o silencio: la celda las
        # declara separadas por " o " (nunca por "|", que romperia la tabla).
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            filas = []
            numero = 1
            for caso in CLASES_BATERIA_PRUEBA:
                for turno in (1, 2):
                    linea = fila_bateria(numero, caso, turno)
                    if caso.startswith("sensible-"):
                        linea = linea.replace(
                            f"| {DESENLACE_ESPERADO[caso]} |",
                            "| propose_sensitive_memory o ninguna |",
                            1,
                        )
                    filas.append(linea)
                    numero += 1
            escribir_bateria(directorio, filas)
            fallos, _ = verificador.verificar_bateria(directorio)
            self.assertEqual(fallos, [])

    def test_json_que_falta_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            escribir_bateria(directorio)
            (directorio / "b26-durable-1.json").unlink()
            fallos, _ = verificador.verificar_bateria(directorio)
            self.assertTrue(any("no existe" in f for f in fallos), fallos)

    def test_tasa_declarada_que_no_cuadra_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            escribir_bateria(directorio, tasas=("1/24", "0/24"))
            fallos, _ = verificador.verificar_bateria(directorio)
            self.assertTrue(any("no cuadra" in f for f in fallos), fallos)

    def test_menos_de_veinte_turnos_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            filas = []
            numero = 1
            for caso in CLASES_BATERIA_PRUEBA:
                filas.append(fila_bateria(numero, caso, 1))
                numero += 1
            escribir_bateria(directorio, filas, tasas=("0/12", "0/12"))
            fallos, _ = verificador.verificar_bateria(directorio)
            self.assertTrue(any(">= 20" in f for f in fallos), fallos)

    def test_clase_sin_turno_falla(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directorio = Path(tmp)
            filas = []
            numero = 1
            for caso in CLASES_BATERIA_PRUEBA:
                if caso == "tope":
                    continue
                for turno in (1, 2):
                    filas.append(fila_bateria(numero, caso, turno))
                    numero += 1
            escribir_bateria(directorio, filas, tasas=("0/22", "0/22"))
            fallos, _ = verificador.verificar_bateria(directorio)
            self.assertTrue(
                any("clases sin ningun turno" in f for f in fallos), fallos
            )


if __name__ == "__main__":
    unittest.main()
