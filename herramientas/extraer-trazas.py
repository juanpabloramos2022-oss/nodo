#!/usr/bin/env python3
"""Extrae las trazas de vista del log de `xcodebuild test`.

Uso:
    python3 herramientas/extraer-trazas.py [log] [directorio-salida]

    log                Log completo de xcodebuild (por defecto
                       `xcodebuild-tests.log` en el directorio actual).
    directorio-salida  Carpeta donde se escriben los .txt (por defecto el
                       directorio de trabajo actual). Se crea si no existe.

POR QUE: `TrazaVistaTest` imprime cada traza a stdout con el formato

    TRAZA <nombre> (<ruta>):
    <contenido...>

y ademas la adjunta al .xcresult. El adjunto exige `xcresulttool` y permisos
de artefactos; el stdout del log es la copia que queda en disco sin depender de
nada mas. Este script convierte ese log en los `ui_transcript_*.txt` que la
Puerta B de la SPEC revisa con git.

Reglas (deliberadamente ruidosas: la evidencia ausente nunca es silencio):
  - Un bloque empieza en una linea `TRAZA <nombre> (<ruta>):` y termina en la
    primera linea NO vacia que no es una linea de traza (o al final del
    archivo). Una linea es de traza si casa con `[t=...s] Etiqueta(...)`, con
    sangria opcional cuando es un segmento anidado; la primera linea del
    bloque puede ser ademas una declaracion `modo: ...`. Asi el ruido que el
    runner de tests imprime despues de la traza (`Test Case ... passed`,
    resumenes de suites, `** TEST SUCCEEDED **`...) no se cuela en el .txt.
  - El nombre debe tener la forma `ui_transcript_<ID>.txt` o
    `ui_transcript_<ID>-<caso>.txt`, con `<ID>` un codigo de partida (P0.3,
    B2.6, B4-COD, IDEA1...). Cualquier otro nombre es error.
  - Cero bloques es error (sin trazas no hay evidencia que revisar).
  - Un bloque vacio es error (una traza vacia no es evidencia).
  - Si un nombre se repite, gana el ultimo bloque y se avisa por stderr.

No usa librerias de terceros: solo la biblioteca estandar de Python.
"""

from __future__ import annotations

import os
import re
import sys

LOG_POR_DEFECTO = "xcodebuild-tests.log"

# `ui_transcript_<ID>.txt` o `ui_transcript_<ID>-<caso>.txt`. El `<ID>` es el
# codigo de partida que ya usan `TrazaVistaTest` y la Puerta C; el `<caso>` es
# el sufijo libre de las partidas que archivan una traza por caso. La forma se
# valida sin cerrar la lista de partidas: una partida nueva no debe romper el
# extractor, pero un nombre que no sea una traza si. Las partidas adicionales
# de una version usan `IDEA<n>` (IDEA1, IDEA3...); el patron las admite todas
# sin tocar este archivo otra vez.
PATRON_NOMBRE_TRAZA = re.compile(
    r"^ui_transcript_"
    r"(?P<id>P[0-9]+\.[0-9]+|B[0-9]+(?:\.[0-9]+)?(?:-[A-Za-z]+)?|IDEA[0-9]+)"
    r"(?:-(?P<caso>[A-Za-z0-9][A-Za-z0-9-]*))?"
    r"\.txt$"
)

# Linea de cabecera que imprime `TrazaVistaTest.publicar`.
PATRON_LINEA_TRAZA = re.compile(
    r"^[ \t]*TRAZA (?P<nombre>[^\s]+) \((?P<ruta>.*)\):[ \t]*$"
)

# Linea de contenido de una traza: `[t=...s] Etiqueta(...)`, con sangria
# opcional para los segmentos anidados de una AssistantBubble. Es el mismo
# formato que exige la Puerta C (`verificar-cierre.py`).
PATRON_LINEA_CONTENIDO = re.compile(
    r"^[ \t]*\[t=[0-9]+(?:\.[0-9]+)?s\]\s+[A-Za-z][A-Za-z0-9]*\b"
)


def _validar_nombre(nombre: str) -> bool:
    """True si el nombre es un `ui_transcript_<ID>[-<caso>].txt` valido."""
    if os.path.basename(nombre) != nombre or nombre in (".", ".."):
        return False
    return PATRON_NOMBRE_TRAZA.match(nombre) is not None


def _es_linea_de_traza(linea: str, primera: bool) -> bool:
    """True si `linea` es contenido de traza (o el `modo:` inicial)."""
    if PATRON_LINEA_CONTENIDO.match(linea):
        return True
    if primera and linea.strip().lower().startswith("modo:"):
        return True
    return False


def _bloques(lineas):
    """Recorre el log y devuelve (numero_de_linea, nombre, contenido) por bloque.

    El bloque termina en la primera linea no vacia que no es de traza: esa
    linea no se incluye. Las lineas en blanco intermedias se conservan y las
    finales se recortan en `main`, igual que antes.
    """
    actual = None
    primera_pendiente = False
    for numero, linea in enumerate(lineas, start=1):
        coincide = PATRON_LINEA_TRAZA.match(linea)
        if coincide:
            if actual is not None:
                yield actual
            actual = [numero, coincide.group("nombre"), []]
            primera_pendiente = True
            continue

        if actual is None:
            continue

        if not linea.strip():
            actual[2].append(linea)
            primera_pendiente = False
            continue

        if _es_linea_de_traza(linea, primera_pendiente):
            actual[2].append(linea)
            primera_pendiente = False
            continue

        # Primera linea no vacia que no es traza: el bloque acaba aqui y el
        # resto del ruido del runner queda fuera hasta la siguiente `TRAZA`.
        yield actual
        actual = None
        primera_pendiente = False

    if actual is not None:
        yield actual


def main(argv) -> int:
    if len(argv) > 3:
        print(
            "Uso: extraer-trazas.py [log] [directorio-salida]",
            file=sys.stderr,
        )
        return 2

    log = argv[1] if len(argv) > 1 else LOG_POR_DEFECTO
    salida = argv[2] if len(argv) > 2 else os.getcwd()

    if not os.path.isfile(log):
        print(f"No existe el log de xcodebuild: {log}", file=sys.stderr)
        return 1

    try:
        with open(log, encoding="utf-8", errors="replace") as archivo:
            lineas = archivo.read().splitlines()
    except OSError as error:
        print(f"No se pudo leer el log {log}: {error}", file=sys.stderr)
        return 1

    os.makedirs(salida, exist_ok=True)

    escritos = []
    for numero, nombre, contenido in _bloques(lineas):
        if not _validar_nombre(nombre):
            print(
                f"Linea {numero}: nombre de traza invalido: {nombre!r}. "
                "Se esperaba ui_transcript_<ID>.txt o "
                "ui_transcript_<ID>-<caso>.txt.",
                file=sys.stderr,
            )
            return 1

        # Se descartan las lineas en blanco del final: el bloque termina donde
        # empieza la siguiente traza, y ahi suele quedar el salto de linea.
        while contenido and not contenido[-1].strip():
            contenido.pop()
        if not contenido:
            print(
                f"Linea {numero}: la traza {nombre} esta vacia.",
                file=sys.stderr,
            )
            return 1

        if nombre in escritos:
            print(
                f"Linea {numero}: la traza {nombre} aparece mas de una vez; "
                "se conserva el ultimo bloque.",
                file=sys.stderr,
            )

        destino = os.path.join(salida, nombre)
        with open(destino, "w", encoding="utf-8") as archivo:
            archivo.write("\n".join(contenido) + "\n")
        if nombre not in escritos:
            escritos.append(nombre)

    if not escritos:
        print(
            f"No se encontro ninguna linea 'TRAZA <nombre> (<ruta>):' en {log}. "
            "Sin trazas no hay evidencia de la Puerta B.",
            file=sys.stderr,
        )
        return 1

    print(f"Trazas extraidas: {len(escritos)}")
    for nombre in sorted(escritos):
        print(f"  {os.path.join(salida, nombre)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
