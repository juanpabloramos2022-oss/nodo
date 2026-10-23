#!/usr/bin/env python3
"""Extrae las capturas PNG y los adjuntos de texto de un .xcresult.

Uso:
    python3 herramientas/extraer-capturas.py <resultado.xcresult> <carpeta-salida>

Primero intenta `xcrun xcresulttool export attachments` (Xcode 16+). Si el
comando no existe o falla, busca las imagenes dentro del bundle del resultado.
Los adjuntos de texto que dejan los tests (por ejemplo la jerarquia de
accesibilidad de `diagnostico-jerarquia`) se copian junto a los PNG con
extension .txt. No usa librerias de terceros: solo la biblioteca estandar de
Python.
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

# Volcados automaticos de XCUITest por cada sondeo: no aportan a la revision
# y ensucian la rama de capturas; las jerarquias utiles van con nombre propio.
PREFIJOS_EXCLUIDOS = ("Debug-description", "App-UI-hierarchy")
# Extensiones con las que xcresulttool puede exportar un XCTAttachment de
# texto. Se normalizan a .txt al copiarlas.
EXTENSIONES_TEXTO = (".txt", ".text", ".log")
EXTENSIONES_ADJUNTO = EXTENSIONES_IMAGEN + EXTENSIONES_TEXTO

# Tipos uniformes con los que xcresulttool marca un adjunto de texto. Se miran
# antes que la extension porque una version de Xcode puede exportarlo como
# .dat (o sin extension) y aun asi ser texto plano.
TIPOS_TEXTO = (
    "public.plain-text",
    "public.utf8-plain-text",
    "public.text",
    "com.apple.traditional-mac-plain-text",
)


def _imagenes(directorio: str) -> Iterable[str]:
    """Recorre un arbol y devuelve las rutas de las imagenes encontradas."""
    for raiz, _, archivos in os.walk(directorio):
        for archivo in archivos:
            if archivo.lower().endswith(EXTENSIONES_IMAGEN):
                yield os.path.join(raiz, archivo)


def _adjuntos(directorio: str) -> Iterable[str]:
    """Recorre un arbol y devuelve imagenes y adjuntos de texto."""
    for raiz, _, archivos in os.walk(directorio):
        for archivo in archivos:
            if archivo.lower().endswith(EXTENSIONES_ADJUNTO):
                yield os.path.join(raiz, archivo)


def _nombre_limpio(texto: str, extension: str) -> str:
    """Convierte el nombre del adjunto en un nombre de archivo seguro."""
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", texto).strip("-._")
    if not base:
        base = "captura"
    if not base.lower().endswith(extension):
        base += extension
    return base


def _copiar(
    origen: str,
    salida: str,
    sugerido: Optional[str] = None,
    extension: Optional[str] = None,
) -> str:
    """Copia un adjunto a la carpeta de salida sin pisar otro del mismo nombre.

    `extension` permite normalizar el archivo copiado (por ejemplo, guardar
    como .txt un adjunto de texto que xcresulttool exporto con otra extension).
    """
    os.makedirs(salida, exist_ok=True)
    if os.path.basename(origen).startswith(PREFIJOS_EXCLUIDOS):
        return ""
    extension = (extension or os.path.splitext(origen)[1]).lower()
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


def _tipo_uniforme(entrada) -> str:
    """Tipo uniforme (UTI) del adjunto segun el manifest, en minusculas."""
    for clave in ("uniformTypeIdentifier", "uti", "typeIdentifier"):
        valor = entrada.get(clave)
        if isinstance(valor, str) and valor.strip():
            return valor.strip().lower()
    return ""


def _es_texto(entrada, origen: str) -> bool:
    """True si el adjunto es texto plano, por UTI o por extension."""
    tipo = _tipo_uniforme(entrada)
    if tipo:
        return tipo.startswith(TIPOS_TEXTO)
    return os.path.splitext(origen)[1].lower() in EXTENSIONES_TEXTO


def _parece_texto(origen: str) -> bool:
    """True si el archivo parece texto plano (UTF-8 sin bytes nulos).

    Red de seguridad para versiones de xcresulttool que exportan los adjuntos
    de texto con una extension opaca o sin extension: asi la jerarquia de
    diagnostico llega igualmente a la carpeta de salida.
    """
    try:
        with open(origen, "rb") as archivo:
            muestra = archivo.read(4096)
    except OSError:
        return False
    if b"\x00" in muestra:
        return False
    try:
        muestra.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


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
    """Copia imagenes y textos usando los nombres descriptivos del manifest."""
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
            for candidato in _adjuntos(exportado):
                if os.path.basename(candidato) == os.path.basename(exportado_nombre):
                    origen = candidato
                    break
        if not os.path.isfile(origen):
            continue

        extension = os.path.splitext(origen)[1].lower()
        sugerido = (
            entrada.get("suggestedHumanReadableName")
            or os.path.splitext(os.path.basename(origen))[0]
        )

        if extension in EXTENSIONES_IMAGEN:
            _copiar(origen, salida, str(sugerido))
            copiados += 1
        elif (
            extension in EXTENSIONES_TEXTO
            or _es_texto(entrada, origen)
            or _parece_texto(origen)
        ):
            # Los adjuntos de texto se normalizan a .txt: el nombre
            # descriptivo (por ejemplo "diagnostico-jerarquia") viaja en el
            # manifest y el contenido es la jerarquia de accesibilidad.
            _copiar(origen, salida, str(sugerido), extension=".txt")
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
                # las imagenes y los textos exportados tal cual.
                for origen in _adjuntos(exportado):
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
        print("No se encontro ningun adjunto en el .xcresult.", file=sys.stderr)
        return 1

    print(f"Adjuntos extraidos: {copiados}")
    for nombre in sorted(os.listdir(salida)):
        print(f"  {nombre}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
