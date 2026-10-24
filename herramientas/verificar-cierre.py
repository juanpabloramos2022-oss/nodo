#!/usr/bin/env python3
"""Puerta de cierre de la correccion v0.3.1 (CLOSE.1).

Bloquea la entrega si la trazabilidad no esta completa:

1. El log de construccion no tiene ninguna casilla `- [ ]` sin marcar.
2. Existen TODOS los JSON de humo vivo exigidos por las partidas.
3. La version coincide en NodoVersion.swift y en project.yml (todas las
   apariciones de MARKETING_VERSION / CFBundleShortVersionString).

Uso completo (mesa de la coordinacion, antes del merge y de entregar la IPA):
    python3 herramientas/verificar-cierre.py \
        --log ~/workspace/nodo/construccion-v0.3.1.md \
        --humos ~/workspace/nodo/humos \
        --ipa ~/workspace/your_files/Nodo-v0.3.1.ipa

Uso en CI (job compilar, antes de empaquetar): solo la parte que vive en el
repo, porque el log y los humos son internos y no se publican:
    python3 herramientas/verificar-cierre.py --solo-repo

Sale con codigo 1 y la lista de fallos si algo no cuadra; 0 si todo cierra.
"""
import argparse
import re
import sys
import zipfile
from pathlib import Path

HUMOS_EXIGIDOS = [
    "mcp-context7-tools-list.json",
    "dem-humo.json",
    "cost-lote-a.json",
    "cost-lote-b.json",
    "comp-plan-resumen.json",
    "comp-plan-turno.json",
    "mem-humo-1.json",
    "mem-humo-2.json",
    "mem-humo-3.json",
    "task-humo-1.json",
    "task-humo-2.json",
    "task-humo-3.json",
    "boost-humo.json",
    "spend-humo.json",
] + [
    f"pack-{slug}.json"
    for slug in [
        "grill-me", "en-cristiano", "guion-video", "prompt-en-ingles",
        "copy-fresco", "responder-cliente", "tutor-ia", "resume-enlace",
        "investiga", "traspaso", "memoria-orden", "crea-skills",
    ]
]


def version_desde_swift(repo: Path) -> str:
    texto = (repo / "NodoCore/Sources/NodoCore/NodoVersion.swift").read_text(
        encoding="utf-8"
    )
    m = re.search(r'public static let version = "([^"]+)"', texto)
    return m.group(1) if m else ""


def versiones_desde_yml(repo: Path) -> list[str]:
    texto = (repo / "project.yml").read_text(encoding="utf-8")
    return re.findall(
        r'(?:MARKETING_VERSION|CFBundleShortVersionString):\s*"([^"]+)"', texto
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path)
    parser.add_argument("--humos", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--solo-repo", action="store_true")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    fallos: list[str] = []

    # 3) Coherencia de version dentro del repo (siempre se comprueba).
    version = version_desde_swift(repo)
    if not version:
        fallos.append("No se pudo leer la version de NodoVersion.swift")
    for v in versiones_desde_yml(repo):
        if v != version:
            fallos.append(f"project.yml trae {v} y NodoVersion.swift {version}")

    if not args.solo_repo:
        # 1) Casillas del log.
        if not args.log or not args.log.exists():
            fallos.append("Falta el log de construccion (--log)")
        else:
            texto = args.log.read_text(encoding="utf-8")
            abiertas = [
                linea.strip()
                for linea in texto.splitlines()
                if linea.strip().startswith("- [ ]")
            ]
            for linea in abiertas:
                fallos.append(f"Casilla sin marcar en el log: {linea}")

        # 2) Humos exigidos.
        if not args.humos or not args.humos.exists():
            fallos.append("Falta el directorio de humos (--humos)")
        else:
            for nombre in HUMOS_EXIGIDOS:
                if not (args.humos / nombre).exists():
                    fallos.append(f"Falta el humo: {nombre}")

        # 4) La IPA entregada existe y es la version esperada.
        if args.ipa:
            if not args.ipa.exists():
                fallos.append(f"No existe la IPA: {args.ipa}")
            else:
                try:
                    with zipfile.ZipFile(args.ipa) as z:
                        plists = [
                            n for n in z.namelist()
                            if n.endswith("Nodo.app/Info.plist")
                        ]
                        if not plists:
                            fallos.append("La IPA no contiene Nodo.app/Info.plist")
                        else:
                            contenido = z.read(plists[0]).decode(
                                "utf-8", "replace"
                            )
                            if version not in contenido:
                                fallos.append(
                                    f"El Info.plist de la IPA no trae {version}"
                                )
                except zipfile.BadZipFile:
                    fallos.append("La IPA no es un zip valido")

    if fallos:
        print("CIERRE BLOQUEADO:")
        for f in fallos:
            print(f"  - {f}")
        return 1
    print(f"Cierre verificado: version {version} coherente, trazabilidad completa.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
