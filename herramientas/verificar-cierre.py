#!/usr/bin/env python3
"""Puerta de cierre de la correccion v0.3.1 (CLOSE.1), extendida en P0.3.

Bloquea la entrega si la trazabilidad no esta completa:

1. El log de construccion no tiene ninguna casilla `- [ ]` sin marcar.
2. Existen TODOS los JSON de humo vivo exigidos por las partidas.
3. La version coincide en NodoVersion.swift y en project.yml (todas las
   apariciones de MARKETING_VERSION / CFBundleShortVersionString).
4. (P0.3) Existe la traza de vista `ui_transcript_<partida>.txt` de cada
   partida con puerta B, con nombres de elemento del catalogo cerrado de
   `UI_INVARIANTS.md` y con los cuatro conteos automaticos en el valor
   esperado. Las trazas de progreso vivo (B3-B) declaran su modo (`vivo` o
   `replay-temporizado`) y contienen una espera de red comprobada >= 2,0 s.

Las comprobaciones 1-3 son las vigentes desde la v0.3.1 y no cambian. La
comprobacion 4 es una ANIADIDURA: `--solo-repo` sigue sin mirar log, humos ni
trazas, exactamente igual que antes.

Uso completo (mesa de la coordinacion, antes del merge y de entregar la IPA):
    python3 herramientas/verificar-cierre.py \
        --log ~/workspace/nodo/construccion-v0.3.2.md \
        --humos ~/workspace/nodo/humos \
        --ipa ~/workspace/your_files/Nodo-v0.3.2.ipa

Para cerrar una partida suelta sin exigir aun las trazas de las demas:
    python3 herramientas/verificar-cierre.py \
        --log ~/workspace/nodo/construccion-v0.3.2.md \
        --humos ~/workspace/nodo/humos \
        --partidas P0.3

`--traza-dir` permite separar las trazas de los JSON de humo; por defecto se
buscan en el mismo directorio que `--humos`.

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
    # B2.1: esquema tipado de memoria, tres turnos del humo vivo.
    "b21-turno1.json",
    "b21-turno2.json",
    "b21-turno3.json",
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

# Catalogo CERRADO de `UI_INVARIANTS.md` (P0.1). Cada nombre de traza tiene un
# caso del catalogo y cada caso tiene un nombre: anadir uno aqui sin anadirlo
# al catalogo (o al reves) es fallo de spec, no motivo para editar el script.
ETIQUETAS_TRAZA_VALIDAS = {
    "UserBubble", "AssistantBubble", "TextSegment", "CodeBlock",
    "MemoryLineNotice", "Divider", "StreamingBubble", "ErrorBubble",
    "MemoryApprovalSheet", "TaskHeader", "PlanCard", "StepRow",
    "SearchResultRow", "SearchEmptyState",
}

# Partidas del hilo con puerta B (bloque 1, bloques 2 y 3 y bloque 4).
PARTIDAS_CON_PUERTA_B = [
    "P0.2", "P0.3",
    "B1.1", "B1.2", "B1.3",
    "B2.1", "B2.2", "B2.3", "B2.4", "B2.5", "B2.6",
    "B3-A", "B3-B",
    "B4-COD", "B4-BUS",
]

# Partidas que archivan varias trazas (una por caso, con sufijo tras un guion).
PARTIDAS_CON_VARIAS_TRAZAS = {"B2.6", "B4-COD"}

# Guardados de memoria declarados por partida (conteo 3 de G-04). `None`
# significa "como mucho uno": las partidas que no guardan no pueden inventar
# una linea y las que guardan declaran exactamente una en este bloque.
GUARDADOS_ESPERADOS = {
    "P0.2": 1,
    "P0.3": 0,
    "B1.1": 1,
    # B1.2 archiva 3 turnos: guardado (turno 1) y actualizacion (turno 3)
    # dejan una linea cada uno; la consulta del turno 2 no deja ninguna.
    "B1.2": 2,
    "B1.3": 1,
    # B2.1 archiva 3 turnos: actualizacion, guardado (el segundo guardado del
    # turno se rechaza) y borrado. Cada turno con operacion deja una linea.
    "B2.1": 3,
}

# Lista CERRADA de nombres tecnicos de herramienta (conteo 4 de G-04).
NOMBRES_TECNICOS_HERRAMIENTA = [
    "memoria_chat",
    "traer_url",
    "proponer_memoria",
    "save_memory",
    "update_memory",
    "propose_sensitive_memory",
    "delete_memory",
]

# `ui_transcript_<ID>.txt` o `ui_transcript_<ID>-<caso>.txt`, con los codigos
# de partida vigentes. Ninguna otra forma de nombre es valida.
PATRON_NOMBRE_TRAZA = re.compile(
    r"^ui_transcript_"
    r"(?P<id>P0\.[23]|B1\.[123]|B2\.[1-6]|B3-A|B3-B|B4-COD|B4-BUS)"
    r"(?:-(?P<caso>[A-Za-z0-9][A-Za-z0-9-]*))?"
    r"\.txt$"
)

PATRON_LINEA_TRAZA = re.compile(
    r"^(?P<sangria>[ \t]*)"
    r"\[t=(?P<tiempo>[0-9]+(?:\.[0-9]+)?)s\]\s+"
    r"(?P<etiqueta>[A-Za-z][A-Za-z0-9]*)\b"
)

PATRON_UUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)

MODO_VIVO = "vivo"
MODO_REPLAY = "replay-temporizado"
ESPERA_MINIMA_REPLAY = 2.0
# Latido renovado de la Partida B: una racha con huecos <= 1,5 s es continua.
LATIDO_MAXIMO = 1.5


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


def nombre_traza_valido(nombre: str) -> bool:
    """True si el nombre cumple `ui_transcript_<ID>[-<caso>].txt`."""
    return PATRON_NOMBRE_TRAZA.match(nombre) is not None


def partidas_desde_arg(valor: str | None) -> list[str]:
    """Partidas a verificar: las de `--partidas` o todas las de puerta B."""
    if not valor:
        return list(PARTIDAS_CON_PUERTA_B)
    return [parte.strip() for parte in valor.split(",") if parte.strip()]


def _lineas_de_traza(ruta: Path) -> list[str]:
    return ruta.read_text(encoding="utf-8").splitlines()


def _verificar_modo(lineas: list[str], partida: str) -> list[str]:
    """Valida la declaracion de modo y el tramo de espera de red comprobada.

    La primera linea `modo: ...` es la unica linea que no es un elemento. Una
    traza B3-B (progreso vivo) esta obligada a declararla; cualquier otra traza
    que la declare entra tambien en esta validacion.

    La prueba de la espera es un tramo continuo >= 2,0 s, en cualquiera de
    estas dos formas, ambas sobre los tiempos del archivo sin edits:

    - un hueco >= 2,0 s entre dos lineas consecutivas (el reproductor espero
      ese tiempo real); o
    - una racha de lineas separadas por <= 1,5 s (el latido renovado de la
      Partida B) cuya primera y ultima marca disten >= 2,0 s.

    Se exige en los dos modos: una captura `vivo` sin ese tramo tampoco prueba
    que el latido se ejercitara durante una espera de red.
    """
    fallos: list[str] = []
    primera = lineas[0].strip() if lineas else ""
    declara = primera.lower().startswith("modo:")

    if partida == "B3-B" and not declara:
        fallos.append(
            "B3-B: la traza de progreso vivo no declara modo "
            "(`vivo` o `replay-temporizado`)"
        )
        return fallos

    if not declara:
        return fallos

    modo = primera.split(":", 1)[1].strip().lower()
    if modo not in (MODO_VIVO, MODO_REPLAY):
        fallos.append(
            f"Traza con modo desconocido: {modo!r} "
            "(solo `vivo` o `replay-temporizado`)"
        )
        return fallos

    tiempos: list[float] = []
    for linea in lineas[1:]:
        m = PATRON_LINEA_TRAZA.match(linea)
        if m is not None:
            tiempos.append(float(m.group("tiempo")))

    for a, b in zip(tiempos, tiempos[1:]):
        if b - a >= ESPERA_MINIMA_REPLAY:
            return fallos

    if tiempos:
        inicio_racha = tiempos[0]
        for a, b in zip(tiempos, tiempos[1:]):
            if b - a > LATIDO_MAXIMO:
                if a - inicio_racha >= ESPERA_MINIMA_REPLAY:
                    return fallos
                inicio_racha = b
        if tiempos[-1] - inicio_racha >= ESPERA_MINIMA_REPLAY:
            return fallos

    fallos.append(
        f"Traza `{modo}` sin un tramo continuo de espera de red "
        f"comprobada >= {ESPERA_MINIMA_REPLAY:.1f} s"
    )
    return fallos


def verificar_traza(
    ruta: Path,
    partida: str,
    guardados_esperados: int | None = None,
) -> list[str]:
    """Valida UNA traza contra G-01.5 y los cuatro conteos de G-04.

    Devuelve la lista de fallos; vacia significa que la traza cierra. No
    reescribe ni normaliza el archivo: lo lee tal como lo volco el arnes.
    """
    fallos: list[str] = []
    if not ruta.exists():
        return [f"Falta la traza: {ruta.name}"]
    if not nombre_traza_valido(ruta.name):
        fallos.append(f"Nombre de traza no valido: {ruta.name}")

    lineas = _lineas_de_traza(ruta)
    fallos.extend(_verificar_modo(lineas, partida))

    etiquetas: list[str] = []
    en_burbuja_asistente = False
    for numero, linea in enumerate(lineas, start=1):
        texto = linea.strip()
        if not texto:
            continue
        if numero == 1 and texto.lower().startswith("modo:"):
            continue

        m = PATRON_LINEA_TRAZA.match(linea)
        if m is None:
            fallos.append(
                f"Linea {numero}: no tiene el formato [t=...s] Etiqueta(...)"
            )
            continue

        etiqueta = m.group("etiqueta")
        anidada = m.group("sangria") != ""
        etiquetas.append(etiqueta)

        if etiqueta not in ETIQUETAS_TRAZA_VALIDAS:
            fallos.append(
                f"Linea {numero}: etiqueta desconocida {etiqueta!r} "
                "(G-01.5)"
            )
            continue

        if anidada:
            if etiqueta not in ("TextSegment", "CodeBlock"):
                fallos.append(
                    f"Linea {numero}: la linea anidada {etiqueta!r} no es "
                    "un segmento de AssistantBubble"
                )
            elif not en_burbuja_asistente:
                fallos.append(
                    f"Linea {numero}: {etiqueta!r} anidada fuera de una "
                    "AssistantBubble"
                )
        else:
            if etiqueta in ("TextSegment", "CodeBlock"):
                fallos.append(
                    f"Linea {numero}: {etiqueta!r} solo es valida anidada "
                    "dentro de una AssistantBubble"
                )
            en_burbuja_asistente = etiqueta == "AssistantBubble"

    if not etiquetas:
        fallos.append("La traza no contiene ningun elemento")

    texto_completo = ruta.read_text(encoding="utf-8")

    # Conteo 1: el rotulo HERRAMIENTA no aparece nunca.
    if "HERRAMIENTA" in texto_completo:
        fallos.append(
            "Conteo 1: la traza contiene el rotulo HERRAMIENTA"
        )

    # Conteo 2: ningun UUID en las cadenas visibles.
    if PATRON_UUID.search(texto_completo):
        fallos.append(
            "Conteo 2: la traza contiene un UUID visible"
        )

    # Conteo 3: una linea de memoria por turno con guardado.
    if guardados_esperados is None:
        guardados_esperados = GUARDADOS_ESPERADOS.get(partida)
    memorias = sum(1 for e in etiquetas if e == "MemoryLineNotice")
    if guardados_esperados is None:
        if memorias > 1:
            fallos.append(
                f"Conteo 3: {memorias} MemoryLineNotice en un turno que "
                "declara como mucho 1"
            )
    elif memorias != guardados_esperados:
        fallos.append(
            f"Conteo 3: {memorias} MemoryLineNotice y la partida declara "
            f"{guardados_esperados}"
        )

    # Conteo 4: ningun nombre tecnico de herramienta, ni como etiqueta ni
    # dentro de una burbuja o un segmento.
    for nombre in NOMBRES_TECNICOS_HERRAMIENTA:
        ocurrencias = texto_completo.count(nombre)
        if ocurrencias:
            fallos.append(
                f"Conteo 4: {ocurrencias} ocurrencia(s) de {nombre!r} "
                "(nombre tecnico de herramienta)"
            )

    return fallos


def trazas_de_partida(directorio: Path, partida: str) -> list[Path]:
    """Trazas de una partida: la exacta o, si archiva varias, las de caso."""
    exacta = directorio / f"ui_transcript_{partida}.txt"
    con_caso = sorted(directorio.glob(f"ui_transcript_{partida}-*.txt"))
    if partida in PARTIDAS_CON_VARIAS_TRAZAS:
        return con_caso
    return [exacta] if exacta.exists() else []


def verificar_trazas(
    directorio: Path,
    partidas: list[str],
) -> list[str]:
    """Valida el directorio de trazas completo y las partidas pedidas."""
    fallos: list[str] = []

    if not directorio.is_dir():
        return [f"Falta el directorio de trazas: {directorio}"]

    # Cualquier archivo que se presente como traza debe cumplir el patron,
    # incluso si la variante del nombre no empieza por `ui_transcript_`
    # (por ejemplo, sin guion bajo o en mayusculas).
    for ruta in sorted(directorio.iterdir()):
        if not ruta.is_file():
            continue
        if "transcript" in ruta.name.lower() and not nombre_traza_valido(
            ruta.name
        ):
            fallos.append(
                f"Nombre de traza no valido: {ruta.name} "
                "(se exige ui_transcript_<ID>.txt o "
                "ui_transcript_<ID>-<caso>.txt)"
            )

    for partida in partidas:
        if partida not in PARTIDAS_CON_PUERTA_B:
            fallos.append(f"Partida sin puerta B declarada: {partida}")
            continue
        rutas = trazas_de_partida(directorio, partida)
        if not rutas:
            if partida in PARTIDAS_CON_VARIAS_TRAZAS:
                fallos.append(
                    f"Falta la traza de {partida}: no hay ningun "
                    f"ui_transcript_{partida}-<caso>.txt"
                )
            else:
                fallos.append(
                    f"Falta la traza de {partida}: "
                    f"ui_transcript_{partida}.txt"
                )
            continue
        for ruta in rutas:
            fallos.extend(verificar_traza(ruta, partida))

    return fallos


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path)
    parser.add_argument("--humos", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument(
        "--traza-dir",
        type=Path,
        help="Directorio de trazas; por defecto, el mismo que --humos.",
    )
    parser.add_argument(
        "--partidas",
        help=(
            "Codigos de partida con puerta B separados por comas. Por defecto "
            "se exigen todas las de la fase."
        ),
    )
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

        # 5) Trazas de vista de las partidas con puerta B (P0.3).
        traza_dir = args.traza_dir or args.humos
        if traza_dir and traza_dir.is_dir():
            fallos.extend(
                verificar_trazas(
                    traza_dir,
                    partidas_desde_arg(args.partidas),
                )
            )
        elif args.traza_dir:
            fallos.append("Falta el directorio de trazas (--traza-dir)")

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
