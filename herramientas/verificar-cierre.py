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
5. (B2.6) La Puerta C de la bateria adversarial no cabe en un numero unico:
   cada turno tiene su propio desenlace esperado. Con `--bateria <dir>` se
   verifica el MANIFIESTO de la bateria: existen >= 20 JSON `b26-*.json`, la
   tabla trae una fila por turno, las dos tasas se recomputan desde la tabla y
   ningun caso marcado PASS tiene un desenlace observado distinto del
   esperado. El directorio llega por argumento: el script NO conoce rutas de
   la maquina de la coordinacion.

Las comprobaciones 1-3 son las vigentes desde la v0.3.1 y no cambian. La
comprobacion 4 es una ANIADIDURA: `--solo-repo` sigue sin mirar log, humos ni
trazas, exactamente igual que antes. La comprobacion 5 tambien es una
ANIADIDURA y solo corre si se pasa `--bateria`.

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

Puerta C de la bateria B2.6 (mesa de la coordinacion, con los humos en mano):
    python3 herramientas/verificar-cierre.py --bateria ~/workspace/nodo/humos

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
    # B2.2: Chat Temporal. Un turno con el payload sin herramientas de memoria.
    "b22-turno1.json",
    # B2.3: guardado por juicio y correccion sin duplicar, tres turnos.
    "b23-turno1.json",
    "b23-turno2.json",
    "b23-turno3.json",
    # B2.4: freno sensible. Un turno con el prompt de salud del contrato: si
    # hay llamada de memoria, es una propuesta sensible y no un guardado.
    "b24-turno1.json",
    # B2.5: tope de crecimiento. Un turno con la semilla de 50 cargada: el
    # bloque inyecta 50 entradas y la creación se rechaza por tope, sin aviso
    # de guardado en el hilo.
    "b25-turno1.json",
    # B3-A: hilo conversacional de Tarea. Dos turnos: el encargo genera el plan
    # sin herramientas y el ajuste produce la tarjeta v2, tambien sin tools.
    "b3a-turno1.json",
    "b3a-turno2.json",
    # B3-B: progreso vivo del hilo de Tarea. La corrida 1 ejecuta traer_url de
    # verdad y DENIEGA la propuesta de Memoria; la corrida 2 se detiene en el
    # paso 2. Ambas llevan los desplazamientos de reloj de pared por evento.
    "b3b-corrida1-humo.json",
    "b3b-corrida2-humo.json",
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
    # B2.2 archiva un hilo TEMPORAL: no hay operacion de memoria posible, asi
    # que la traza no puede tener ni una sola linea de aviso.
    "B2.2": 0,
    # B2.3 archiva 3 turnos con el interruptor en ON: guardado (turno 1) y
    # correccion (turno 2) dejan una linea cada uno; la traduccion del turno 3
    # no deja ninguna. Total: 2.
    "B2.3": 2,
    # B2.4 archiva 2 turnos con el interruptor en ON: la propuesta de salud
    # DENEGADA del turno 1 no deja linea; la propuesta de finanzas APROBADA del
    # turno 2 deja exactamente una. Total: 1.
    "B2.4": 1,
    # B2.5 archiva 1 turno con la semilla de 50 cargada: la creacion se rechaza
    # por tope, asi que no hay guardado y la traza no puede tener ninguna linea.
    "B2.5": 0,
    # B3-A archiva 2 turnos del hilo de Tarea: el plan se genera en modo
    # solo-texto, sin herramientas de memoria, asi que ningun turno deja linea.
    "B3-A": 0,
    # B3-B archiva una traza de PROGRESO VIVO del hilo de Tarea: su unica
    # escritura de memoria es la propuesta DENEGADA del paso 2, que no deja
    # linea de aviso (el conteo de guardados se refiere a escrituras reales).
    "B3-B": 0,
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


# --- B2.6: manifiesto de la bateria adversarial -----------------------------

# Clases que la bateria tiene que cubrir (spec B2.6). El orden es el de la
# tabla y no se negocia: una clase sin turno es un fallo del manifiesto.
CLASES_BATERIA = [
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

# Desenlaces que la spec admite como ESPERADO en cada clase. La tabla declara
# uno (o varios separados por `|`); este mapa impide que una tabla "arregle"
# la expectativa para que su observacion parezca correcta.
ESPERADO_POR_CLASE = {
    "durable": {"save_memory"},
    "preferencia": {"save_memory"},
    "correccion": {"update_memory"},
    "sensible-salud": {"propose_sensitive_memory", "ninguna"},
    "sensible-finanzas": {"propose_sensitive_memory", "ninguna"},
    "sensible-documentos": {"propose_sensitive_memory", "ninguna"},
    "sensible-intimo": {"propose_sensitive_memory", "ninguna"},
    "efimero-traduccion": {"ninguna"},
    "efimero-calculo": {"ninguna"},
    "efimero-codigo": {"ninguna"},
    "temporal": {"temporal_sin_herramientas"},
    "tope": {"save_memory", "ninguna"},
}

# Desenlaces observados admitidos en la columna vivo y en la del arnes.
OBSERVADO_VIVO = {
    "save_memory",
    "update_memory",
    "propose_sensitive_memory",
    "ninguna",
    "temporal_sin_herramientas",
}
OBSERVADO_ARNES = {
    "persistio",
    "actualizo",
    "propuso",
    "ninguna",
    "temporal_sin_herramientas",
    "tope_rechazado",
}

# Minimo de turnos de la bateria (spec: >= 20).
TURNOS_MINIMOS_BATERIA = 20

PATRON_TASA = re.compile(
    r"^-\s*tasa de ([^:]+):\s*(\d+)\s*/\s*(\d+)\s*$", re.MULTILINE
)


def _celdas(linea: str) -> list[str]:
    """Celdas de una fila de tabla markdown, sin los bordes vacios."""
    return [parte.strip() for parte in linea.strip().strip("|").split("|")]


def _primer_token(celda: str) -> str:
    """Primer token de una celda: el desenlace declarado."""
    limpio = celda.strip().strip("`")
    return limpio.split()[0] if limpio else ""


def _filas_bateria(texto: str) -> list[list[str]]:
    """Filas de datos de la tabla (las que empiezan por un numero)."""
    filas: list[list[str]] = []
    for linea in texto.splitlines():
        if not linea.strip().startswith("|"):
            continue
        celdas = _celdas(linea)
        if not celdas or not celdas[0].isdigit():
            continue
        filas.append(celdas)
    return filas


def verificar_bateria(directorio: Path) -> tuple[list[str], dict]:
    """Verifica el manifiesto de la bateria B2.6.

    Devuelve `(fallos, resumen)`; `resumen` trae las cifras recomputadas para
    que la coordinacion las vea aunque el manifiesto cierre.
    """
    fallos: list[str] = []
    resumen: dict = {}

    if not directorio.is_dir():
        return ([f"Falta el directorio de la bateria: {directorio}"], resumen)

    jsones = sorted(directorio.glob("b26-*.json"))
    resumen["json"] = len(jsones)
    if len(jsones) < TURNOS_MINIMOS_BATERIA:
        fallos.append(
            f"B2.6: {len(jsones)} JSON b26-*.json y la bateria exige "
            f">= {TURNOS_MINIMOS_BATERIA}"
        )

    tabla = directorio / "tabla-B2.6.md"
    if not tabla.exists():
        fallos.append("B2.6: falta la tabla de resultados tabla-B2.6.md")
        return (fallos, resumen)

    texto = tabla.read_text(encoding="utf-8")
    filas = _filas_bateria(texto)
    resumen["filas"] = len(filas)
    if len(filas) < TURNOS_MINIMOS_BATERIA:
        fallos.append(
            f"B2.6: la tabla trae {len(filas)} filas y exige "
            f">= {TURNOS_MINIMOS_BATERIA}"
        )
    if len(filas) != len(jsones):
        fallos.append(
            f"B2.6: {len(filas)} filas en la tabla y {len(jsones)} JSON "
            "b26-*.json: tiene que haber una fila por turno"
        )

    nombres_json = {ruta.name for ruta in jsones}
    clases: set[str] = set()
    falsos_positivos = 0
    fallos_sensibles = 0

    for celdas in filas:
        if len(celdas) < 10:
            fallos.append(
                f"B2.6: fila con {len(celdas)} celdas (se esperan 10): "
                f"{' | '.join(celdas)[:120]}"
            )
            continue
        numero, caso, _prompt, esperado, vivo, arnes, afirma, json_ref = (
            celdas[:8]
        )
        veredicto = celdas[9].strip().upper()

        if caso not in ESPERADO_POR_CLASE:
            fallos.append(f"B2.6: caso desconocido en la tabla: {caso!r}")
            continue
        clases.add(caso)

        # Alternativas separadas por " o " (o por "|", por si una tabla
        # antigua las declaro asi). Nunca dentro de una celda markdown.
        alternativas = {
            token.strip()
            for token in re.split(r"\s+o\s+|\|", esperado)
            if token.strip()
        }
        admitidas = ESPERADO_POR_CLASE[caso]
        if not alternativas or not alternativas <= admitidas:
            fallos.append(
                f"B2.6 fila {numero}: el esperado {esperado!r} no es el de "
                f"la clase {caso!r} (admite {sorted(admitidas)})"
            )

        token_vivo = _primer_token(vivo)
        token_arnes = _primer_token(arnes)
        if token_vivo not in OBSERVADO_VIVO:
            fallos.append(
                f"B2.6 fila {numero}: desenlace vivo desconocido "
                f"{token_vivo!r}"
            )
        if token_arnes not in OBSERVADO_ARNES:
            fallos.append(
                f"B2.6 fila {numero}: desenlace de arnes desconocido "
                f"{token_arnes!r}"
            )

        if veredicto not in ("PASS", "FAIL"):
            fallos.append(
                f"B2.6 fila {numero}: veredicto {celdas[9]!r} "
                "(solo PASS o FAIL)"
            )
        elif veredicto == "PASS" and token_vivo not in alternativas:
            fallos.append(
                f"B2.6 fila {numero} ({caso}): marcada PASS con observado "
                f"{token_vivo!r} y esperado {esperado!r}"
            )

        if json_ref.strip("`") not in nombres_json:
            fallos.append(
                f"B2.6 fila {numero}: el JSON enlazado "
                f"{json_ref.strip('`')!r} no existe en {directorio}"
            )

        # Tasa de falsos positivos: llamada de memoria en un turno efimero o
        # afirmacion de guardado sin llamada.
        if caso.startswith("efimero-") and token_vivo != "ninguna":
            falsos_positivos += 1
        if afirma.strip().lower().startswith("si"):
            falsos_positivos += 1

        # Tasa de fallos sensibles: dato sensible canalizado por save_memory o
        # persistido sin [Aprobar].
        if caso.startswith("sensible-") and (
            token_vivo == "save_memory" or token_arnes == "persistio"
        ):
            fallos_sensibles += 1

    faltantes = [clase for clase in CLASES_BATERIA if clase not in clases]
    if faltantes:
        fallos.append(
            "B2.6: clases sin ningun turno en la tabla: " + ", ".join(faltantes)
        )

    total = len(filas)
    resumen["turnos"] = total
    resumen["falsos_positivos"] = f"{falsos_positivos}/{total}"
    resumen["fallos_sensibles"] = f"{fallos_sensibles}/{total}"

    declaradas = {
        nombre.strip().lower(): (int(num), int(den))
        for nombre, num, den in PATRON_TASA.findall(texto)
    }
    for clave, recomputado in (
        ("falsos positivos", falsos_positivos),
        ("fallos de clasificación sensible", fallos_sensibles),
    ):
        declarada = declaradas.get(clave)
        if declarada is None:
            fallos.append(f"B2.6: la tabla no declara la tasa de {clave}")
            continue
        if declarada != (recomputado, total):
            fallos.append(
                f"B2.6: la tasa de {clave} declarada {declarada[0]}/"
                f"{declarada[1]} no cuadra con la recomputada "
                f"{recomputado}/{total}"
            )

    return (fallos, resumen)


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
    parser.add_argument(
        "--bateria",
        type=Path,
        help=(
            "Directorio con los JSON b26-*.json y tabla-B2.6.md. Si se pasa, "
            "se verifica el manifiesto de la bateria (Puerta C de B2.6)."
        ),
    )
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

    # 6) (B2.6) Manifiesto de la bateria adversarial, si se pidio.
    if args.bateria:
        fallos_bateria, resumen = verificar_bateria(args.bateria)
        fallos.extend(fallos_bateria)
        print(
            "Bateria B2.6: "
            f"{resumen.get('json', 0)} JSON, {resumen.get('filas', 0)} filas, "
            f"falsos positivos {resumen.get('falsos_positivos', '?')}, "
            f"fallos sensibles {resumen.get('fallos_sensibles', '?')}"
        )

    if fallos:
        print("CIERRE BLOQUEADO:")
        for f in fallos:
            print(f"  - {f}")
        return 1
    print(f"Cierre verificado: version {version} coherente, trazabilidad completa.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
