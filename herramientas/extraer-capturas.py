#!/usr/bin/env python3
"""Extrae las capturas PNG de un .xcresult para publicarlas como artefacto.

Uso:
    python3 herramientas/extraer-capturas.py <resultado.xcresult> <carpeta-salida>

Primero intenta `xcrun xcresulttool export attachments` (Xcode 16+). Si el
comando no existe o falla, busca los PNG dentro del bundle del resultado. No
usa librerias de terceros: solo la biblioteca estandar de Python.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from typing import Iterable, Optional

EXTENSIONES_IMAGEN = (".png", ".jpg", ".jpeg")


def _imagenes(directorio: str) -> Iterable[str]:
    """Recorre un arbol y devuelve las rutas de las imagenes encontradas."""
    for raiz, _, archivos in os.walk(directorio):
        for archivo in archivos:
            if archivo.lower().endswith(EXTENSIONES_IMAGEN):
                yield os.path.join(raiz, archivo)


def _nombre_limpio(texto: str, extension: str) -> str:
    """Convierte el nombre del adjunto en un nombre de archivo seguro."""
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", texto).strip("-._")
    if not base:
        base = "captura"
    if not base.lower().endswith(extension):
        base += extension
    return base


def _copiar(origen: str, salida: str, sugerido: Optional[str] = None) -> str:
    """Copia una imagen a la carpeta de salida sin pisar otra del mismo nombre."""
    os.makedirs(salida, exist_ok=True)
    extension = os.path.splitext(origen)[1].lower()
    texto = sugerido or os.path.splitext(os.path.basename(origen))[0]
    nombre = _nombre_limpio(texto, extension)
    destino = os.path.join(salida, nombre)
    contador = 1
    while os.path.exists(destino):
        base, ext = os.path.splitext(nombre)
        destino = os.path.join(salida, f"{base}-{contador}{ext}")
        contador += 1
    shutil.copy2(origen, destino)
    return destino


def _entradas_manifest(datos):
    """Recorre el manifest de xcresulttool y devuelve las entradas de adjuntos."""
    if isinstance(datos, dict):
        if "exportedFileName" in datos:
            yield datos
        for valor in datos.values():
            yield from _entradas_manifest(valor)
    elif isinstance(datos, list):
        for valor in datos:
            yield from _entradas_manifest(valor)


def _copiar_desde_manifest(exportado: str, salida: str) -> int:
    """Copia las imagenes usando los nombres descriptivos del manifest."""
    manifest = os.path.join(exportado, "manifest.json")
    if not os.path.isfile(manifest):
        return 0

    with open(manifest, encoding="utf-8") as archivo:
        datos = json.load(archivo)

    copiados = 0
    for entrada in _entradas_manifest(datos):
        exportado_nombre = entrada.get("exportedFileName")
        if not exportado_nombre:
            continue

        origen = os.path.join(exportado, exportado_nombre)
        if not os.path.isfile(origen):
            # Algunas versiones guardan el archivo en una subcarpeta.
            for candidato in _imagenes(exportado):
                if os.path.basename(candidato) == os.path.basename(exportado_nombre):
                    origen = candidato
                    break
        if not os.path.isfile(origen):
            continue
        if not origen.lower().endswith(EXTENSIONES_IMAGEN):
            continue

        sugerido = (
            entrada.get("suggestedHumanReadableName")
            or os.path.splitext(os.path.basename(origen))[0]
        )
        _copiar(origen, salida, str(sugerido))
        copiados += 1

    return copiados


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Uso: extraer-capturas.py <resultado.xcresult> <carpeta-salida>",
            file=sys.stderr,
        )
        return 2

    resultado, salida = sys.argv[1], sys.argv[2]
    os.makedirs(salida, exist_ok=True)

    if not os.path.isdir(resultado):
        print(f"No existe el bundle de resultados: {resultado}", file=sys.stderr)
        return 1

    exportado = os.path.join(salida, "_exportado")
    shutil.rmtree(exportado, ignore_errors=True)

    copiados = 0
    proceso = None
    try:
        proceso = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "export",
                "attachments",
                "--path",
                resultado,
                "--output-path",
                exportado,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        # Sin xcrun se usa directamente el fallback sobre el bundle.
        print("No se encontro xcrun; se usa el fallback.", file=sys.stderr)
        proceso = None

    if proceso is not None and proceso.returncode != 0:
        print(
            "xcresulttool export attachments no esta disponible; se usa el fallback.",
            file=sys.stderr,
        )

    if proceso is not None and proceso.returncode == 0:
        try:
            copiados = _copiar_desde_manifest(exportado, salida)
            if copiados == 0:
                # El comando funciono pero no traia manifest util: se copian
                # las imagenes exportadas tal cual.
                for origen in _imagenes(exportado):
                    _copiar(origen, salida)
                    copiados += 1
        except Exception as error:  # noqa: BLE001 - el fallback debe seguir
            print(f"No se pudo leer el manifest: {error}", file=sys.stderr)
            copiados = 0

    if copiados == 0:
        # Ultimo recurso: los adjuntos viven dentro del bundle del resultado.
        for origen in _imagenes(resultado):
            _copiar(origen, salida)
            copiados += 1

    shutil.rmtree(exportado, ignore_errors=True)

    if copiados == 0:
        print("No se encontro ninguna captura en el .xcresult.", file=sys.stderr)
        return 1

    print(f"Capturas extraidas: {copiados}")
    for nombre in sorted(os.listdir(salida)):
        print(f"  {nombre}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
