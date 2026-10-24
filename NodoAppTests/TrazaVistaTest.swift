import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Suite del arnes de traza de vista (P0.3).
///
/// POR QUE: desde P0.3 un humo vivo sin `ui_transcript_<partida>.txt` no
/// cierra ninguna partida que toque el hilo. Estos tests generan la traza
/// desde `EstadoApp` real con el transporte que reproduce la respuesta
/// archivada, y comprueban el formato, el orden y los conteos que la Puerta C
/// volvera a verificar sobre el archivo.
///
/// En CI las trazas se escriben en el directorio temporal del simulador y se
/// adjuntan al `xcresult`; para archivarlas en `humos/`, la coordinacion
/// ejecuta con `NODO_TRAZA_DIR` apuntando a ese directorio y
/// `NODO_HUMOS_DIR` al de los JSON vivos.
@MainActor
final class TrazaVistaTest: XCTestCase {

    // MARK: - Fixture (b) de P0.2

    /// Primera llamada de `humos/mem-humo-1.json` (v0.3.1), migrada al esquema
    /// tipado de B2.1. El archivo trae dos llamadas; el contrato de P0.2 exige
    /// UN artefacto de memoria por turno, asi que el fixture inyecta la primera
    /// y deja constancia. La segunda era «Prefiere respuestas cortas».
    private static let llamadaMemoriaArchivada = ToolCall(
        id: "call_00_WVjAe73tY4ubrvEhwMnB9307",
        nombre: Memoria.nombreGuardar,
        argumentos: #"{"content": "Palabra clave de la barbería: LUNA-7", "category": "durable_fact"}"#
    )

    private static let promptMemoria =
        "Recuerda que mi palabra clave de la barbería es LUNA-7 y que prefiero respuestas cortas."

    private static let respuestaMemoriaFixture =
        "Listo: lo guarde en tu Memoria."

    /// Respuesta viva de la corrida de estreno (P0.3), archivada en
    /// `humos/p03-humo-ok.json`: `content` = "ok", usage 527/2. Si
    /// `NODO_HUMOS_DIR` esta definido, el test lee el JSON exacto en su lugar.
    private static let respuestaEstreno = "ok"
    private static let usoEstreno = UsoTokens(entrada: 527, salida: 2)

    // MARK: - (1) Volcado del fixture (b): lineas exactas en orden

    func testElFixtureBProduceLasLineasEsperadasEnOrden() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [Self.llamadaMemoriaArchivada]
        )
        arnes.transporte.guionar(
            texto: Self.respuestaMemoriaFixture,
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar(Self.promptMemoria)
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let lineas = TrazaVista.lineasHilo(elementos, t: "1.2")

        XCTAssertEqual(
            lineas,
            [
                "[t=1.2s] UserBubble(\"\(Self.promptMemoria)\")",
                "[t=1.2s] MemoryLineNotice(text: "
                    + "\"Guardado en memoria: Palabra clave de la barbería: "
                    + "LUNA-7\", hasUndo: true)",
                "[t=1.2s] AssistantBubble(\""
                    + "\(Self.respuestaMemoriaFixture)\")",
                "  [t=1.2s] TextSegment(\""
                    + "\(Self.respuestaMemoriaFixture)\")"
            ]
        )
    }

    func testVolcarHiloEscribeEnLaRutaIndicada() throws {
        let ruta = FileManager.default.temporaryDirectory
            .appendingPathComponent("traza-volcar-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: ruta) }

        let inicio = Date(timeIntervalSince1970: 100)
        try TrazaVista.volcarHilo(
            [.burbujaUsuario(texto: "Hola")],
            desde: inicio,
            a: ruta,
            hasta: inicio
        )

        XCTAssertEqual(
            try String(contentsOf: ruta, encoding: .utf8),
            "[t=0.0s] UserBubble(\"Hola\")\n"
        )
    }

    // MARK: - (2) Traza de la partida P0.3 (estreno «Di solo: ok»)

    func testElTurnoDeEstrenoProduceLaTrazaP03() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let guion: GuionRespuesta
        if let archivo = Self.rutaDelHumo("p03-humo-ok.json") {
            guion = try TransporteGuionizado.leerGuionDesdeArchivo(archivo)
            try arnes.transporte.guionarDesdeArchivo(archivo)
        } else {
            guion = GuionRespuesta(
                texto: Self.respuestaEstreno,
                uso: Self.usoEstreno,
                toolCalls: []
            )
            arnes.transporte.guionar(
                texto: guion.texto,
                uso: guion.uso,
                toolCalls: guion.toolCalls
            )
        }

        let ruta = try Self.rutaDeTraza("ui_transcript_P0.3.txt")
        let sesion = try SesionTraza(ruta: ruta)

        // Antes de enviar: la proyeccion esta vacia y no aporta lineas.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        arnes.estado.enviar("Di solo: ok")
        // Tras enviar: la burbuja del usuario ya esta; la de curso se filtra.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        try await arnes.esperarTurno()

        // Al cerrar la respuesta: exactamente las dos burbujas del turno.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        let lineas = contenido.split(separator: "\n").map { String($0) }

        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"]
        )
        XCTAssertEqual(lineas.count, 3)
        XCTAssertTrue(lineas[0].hasSuffix("UserBubble(\"Di solo: ok\")"))
        XCTAssertTrue(
            lineas[1].contains(
                "AssistantBubble(\"\(TrazaVista.escapar(guion.texto))\")"
            )
        )
        XCTAssertTrue(lineas[2].hasPrefix("  "))
        XCTAssertTrue(
            lineas[2].contains(
                "TextSegment(\"\(TrazaVista.escapar(guion.texto))\")"
            )
        )

        Self.comprobarConteosDeLaPuertaC(contenido)
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            0,
            "El turno de estreno no guarda memoria"
        )
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (3) Traza de la partida P0.2 (fixture b)

    func testElFixtureBProduceLaTrazaP02() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [Self.llamadaMemoriaArchivada]
        )
        arnes.transporte.guionar(
            texto: Self.respuestaMemoriaFixture,
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_P0.2.txt")
        let sesion = try SesionTraza(ruta: ruta)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        arnes.estado.enviar(Self.promptMemoria)
        // Tras enviar: la burbuja del usuario ya esta; la de curso se filtra.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Tras ejecutar la herramienta: la linea de memoria ya es visible.
        try await arnes.esperar {
            arnes.estado.elementosVisiblesDelHilo().contains { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }
        }
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "MemoryLineNotice", "AssistantBubble"]
        )
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 1)
        XCTAssertTrue(
            contenido.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "Palabra clave de la barbería: LUNA-7\", hasUndo: true)"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"\(Self.respuestaMemoriaFixture)\")"
            )
        )
        XCTAssertTrue(contenido.contains("  [t="))
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 2)

        Self.comprobarConteosDeLaPuertaC(contenido)
        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (3) Traza de la partida B1.1 (guion literal de 2 turnos)

    /// Los dos turnos del contrato X de B1.1, con la prosa final sin UUID.
    private static let promptB11Turno1 =
        "Recuerda que mi palabra clave personal de ejemplo es LUNA-7"
    private static let promptB11Turno2 =
        "Consulta https://example.com y dime qué es ese dominio"

    func testElGuionB11ProduceLaTrazaB11() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // Turno 1: orden explicita de guardado. El modelo pide save_memory y
        // despues confirma sin repetir el id interno.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b11-memoria",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"Palabra clave personal de ejemplo: LUNA-7","category":"durable_fact"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Listo, lo guardé en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        // Turno 2: el modelo pide traer_url; el resultado vuelve al modelo como
        // mensaje interno y la respuesta llega como prosa normal.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b11-url",
                    nombre: "traer_url",
                    argumentos: #"{"url":"https://example.com"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "example.com es un dominio reservado para ejemplos de documentación.",
            uso: UsoTokens(entrada: 40, salida: 9)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B1.1.txt")
        let sesion = try SesionTraza(ruta: ruta)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        arnes.estado.enviar(Self.promptB11Turno1)
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 2)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        arnes.estado.enviar(Self.promptB11Turno2)
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "UserBubble",
                "MemoryLineNotice",
                "AssistantBubble",
                "UserBubble",
                "AssistantBubble"
            ],
            "Solo burbujas y el aviso de memoria: nada procedente de herramientas"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            1,
            "El turno 1 con guardado deja exactamente un aviso de memoria"
        )
        XCTAssertTrue(
            contenido.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "Palabra clave personal de ejemplo: LUNA-7\", hasUndo: true)"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"example.com es un dominio reservado "
                    + "para ejemplos de documentación.\")"
            )
        )
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (3) Traza de la partida B1.2 (guion literal de 3 turnos)

    /// Los tres turnos del contrato X de B1.2: guardado, consulta sin
    /// herramienta y actualizacion sobre la entrada existente.
    private static let promptB12Turno1 =
        "Recuerda que mi palabra clave personal de ejemplo es LUNA-7"
    private static let promptB12Turno2 =
        "¿Cuál es mi palabra clave personal de ejemplo?"
    private static let promptB12Turno3 =
        "Actualiza mi memoria: mi palabra clave ahora es LUNA-9"

    func testElGuionB12ProduceLaTrazaB12() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // Turno 1: orden explicita de guardado.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b12-guardar",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"Palabra clave personal de ejemplo: LUNA-7","category":"durable_fact"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Listo, lo guardé en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B1.2.txt")
        let sesion = try SesionTraza(ruta: ruta)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        arnes.estado.enviar(Self.promptB12Turno1)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(arnes.estado.config.memoria.count, 1)
        let contenidoTrasTurno1 = sesion.contenido
        XCTAssertEqual(
            Self.cuenta(contenidoTrasTurno1, "MemoryLineNotice"),
            1,
            "El turno 1 con guardado deja exactamente un aviso de memoria"
        )

        // Turno 2: consulta sin herramienta. El modelo responde desde la
        // Memoria y no anade otra linea.
        arnes.transporte.guionar(
            texto: "Tu palabra clave personal de ejemplo es LUNA-7.",
            uso: UsoTokens(entrada: 40, salida: 9)
        )
        arnes.estado.enviar(Self.promptB12Turno2)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            1,
            "La consulta sin tool_call no anade una segunda linea"
        )

        // Turno 3: actualizacion sobre la entrada existente. El id viaja en
        // los argumentos internos de la herramienta, nunca a la vista.
        let entradasAntes = arnes.estado.config.memoria.count
        let idEntrada = try XCTUnwrap(arnes.estado.config.memoria.first?.id)
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b12-actualizar",
                    nombre: Memoria.nombreActualizar,
                    argumentos: #"{"entry_id":"\#(idEntrada.uuidString)","content":"Palabra clave personal de ejemplo: LUNA-9","category":"correction"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Memoria actualizada.",
            uso: UsoTokens(entrada: 50, salida: 10)
        )

        arnes.estado.enviar(Self.promptB12Turno3)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            entradasAntes,
            "Actualizar no cambia el conteo de entradas (N -> N)"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.first?.texto,
            "Palabra clave personal de ejemplo: LUNA-9"
        )

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "UserBubble", "MemoryLineNotice", "AssistantBubble",
                "UserBubble", "AssistantBubble",
                "UserBubble", "MemoryLineNotice", "AssistantBubble"
            ],
            "Solo burbujas y una linea unica por turno con operacion de memoria"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            2,
            "Los turnos 1 y 3 dejan exactamente una linea cada uno"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice")
                - Self.cuenta(contenidoTrasTurno1, "MemoryLineNotice"),
            1,
            "El turno 3 anade exactamente una linea"
        )
        XCTAssertTrue(
            contenido.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "Palabra clave personal de ejemplo: LUNA-7\", "
                    + "hasUndo: true)"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "MemoryLineNotice(text: \"Memoria actualizada: "
                    + "Palabra clave personal de ejemplo: LUNA-9\", "
                    + "hasUndo: true)"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"Tu palabra clave personal de ejemplo "
                    + "es LUNA-7.\")"
            )
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "HERRAMIENTA"),
            0,
            "Conteo 1: la traza no puede llevar el rotulo HERRAMIENTA"
        )
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (3) Traza de la partida B1.3 (guion literal de 4 turnos)

    /// Los cuatro turnos del contrato X de B1.3: dato suelto sin orden,
    /// orden explicita de guardado, detalle efimero y pregunta literal sobre
    /// la memoria. Las respuestas son las de la corrida viva archivada en
    /// `humos/b13-turno*.json`.
    private static let promptB13Turno1 = "Mi color favorito es el verde"
    private static let promptB13Turno2 =
        "Recuerda que mi color favorito es el verde"
    private static let promptB13Turno3 =
        "Traduce al inglés: la casa es grande"
    private static let promptB13Turno4 = "¿Cómo funciona tu memoria?"

    private static let respuestaB13Turno1 =
        "El verde es una buena elección: naturaleza, calma y frescura. "
        + "¿Hay algún tono en particular que te guste más, como el verde "
        + "oliva, el esmeralda o el menta?"
    private static let respuestaB13Turno2 =
        "Listo, queda guardado. ¿Quieres que lo tenga en cuenta para algo en "
        + "concreto, como recomendaciones de ropa o diseños?"
    private static let respuestaB13Turno3 = "\"The house is big.\""
    private static let respuestaB13Turno4 =
        "Funciona así:\n\n"
        + "- Tengo una lista de entradas de memoria asociadas a ti (ahora "
        + "mismo hay una: tu color favorito, el verde).\n"
        + "- Solo guardo, actualizo o borro algo cuando tú me lo pides de "
        + "forma explícita. No lo hago por iniciativa propia ni en silencio.\n"
        + "- Para guardar añado una entrada nueva; para actualizar o borrar "
        + "necesito la entrada concreta (la identificación interna la manejo yo).\n"
        + "- La aplicación te avisa cada vez que ejecuto una de esas acciones, "
        + "y las entradas quedan visibles para ti.\n"
        + "- Si no ejecuto nada, simplemente respondo a la conversación sin "
        + "tocar la memoria.\n\n"
        + "¿Quieres que cambie, corrija o elimine alguna entrada?"

    func testElGuionB13ProduceLaTrazaB13() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B1.3.txt")
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Turno 1: dato suelto SIN orden. No hay tool_call y la respuesta habla
        // solo del color: cero lineas de memoria.
        arnes.transporte.guionar(
            texto: Self.respuestaB13Turno1,
            uso: UsoTokens(entrada: 657, salida: 84)
        )
        arnes.estado.enviar(Self.promptB13Turno1)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        XCTAssertTrue(arnes.estado.config.memoria.isEmpty)
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            0,
            "El turno sin orden no puede dejar linea de memoria"
        )

        // Turno 2: orden explicita. El modelo pide guardar y la app pinta la
        // linea unica; el acuse verbal es una sola frase de 3 palabras y la
        // segunda frase es la respuesta normal de seguimiento (19 en total).
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b13-guardar",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content": "Mi color favorito es el verde.", "category": "preference"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: Self.respuestaB13Turno2,
            uso: UsoTokens(entrada: 863, salida: 32)
        )
        arnes.estado.enviar(Self.promptB13Turno2)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        XCTAssertEqual(arnes.estado.config.memoria.count, 1)
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            1,
            "El turno con guardado deja exactamente un aviso de memoria"
        )

        // Turno 3: detalle efimero, sin herramienta ni menciones.
        arnes.transporte.guionar(
            texto: Self.respuestaB13Turno3,
            uso: UsoTokens(entrada: 909, salida: 14)
        )
        arnes.estado.enviar(Self.promptB13Turno3)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Turno 4: pregunta literal sobre el funcionamiento. Aqui SI se
        // explica, y aun asi no aparece otra linea de memoria.
        arnes.transporte.guionar(
            texto: Self.respuestaB13Turno4,
            uso: UsoTokens(entrada: 926, salida: 225)
        )
        arnes.estado.enviar(Self.promptB13Turno4)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(
            arnes.estado.config.memoria.first?.texto,
            "Mi color favorito es el verde."
        )

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "UserBubble", "AssistantBubble",
                "UserBubble", "MemoryLineNotice", "AssistantBubble",
                "UserBubble", "AssistantBubble",
                "UserBubble", "AssistantBubble"
            ],
            "Solo burbujas y una unica linea, en el turno con guardado"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            1,
            "El guion completo deja exactamente 1 MemoryLineNotice"
        )
        XCTAssertTrue(
            contenido.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "Mi color favorito es el verde.\", hasUndo: true)"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"El verde es una buena elección"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"Listo, queda guardado."
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"\\\"The house is big.\\\"\")"
            )
        )
        XCTAssertTrue(
            contenido.contains(
                "AssistantBubble(\"Funciona así:\\n\\n- Tengo una lista "
                    + "de entradas de memoria"
            )
        )
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (3) Traza de la partida B2.1 (guion literal de 3 turnos)

    /// Los tres turnos del contrato X de B2.1: actualizacion sobre semilla,
    /// turno con dos guardados (el segundo rechazado por el ejecutor) y borrado
    /// con orden explicita.
    private static let promptB21Turno1 =
        "Corrige mi fruta favorita de prueba: ya no es la manzana, es el mango"
    private static let promptB21Turno2 =
        "Recuerda dos cosas: mi color favorito de prueba es el verde "
        + "y mi animal favorito de prueba es el gato"
    private static let promptB21Turno3 =
        "Olvida mi fruta favorita de prueba"

    private static let semillaB21 = EntradaMemoria(
        id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
        texto: "mi fruta favorita de prueba es la manzana",
        fecha: Date(timeIntervalSince1970: 300),
        categoria: .durableFact
    )

    func testElGuionB21ProduceLaTrazaB21() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = [Self.semillaB21]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B2.1.txt")
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Turno 1: actualizacion sobre la semilla. Exactamente una linea y el
        // conteo de entradas no crece (N = N).
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b21-turno1",
                    nombre: Memoria.nombreActualizar,
                    argumentos: #"{"entry_id":"\#(Self.semillaB21.id.uuidString)","content":"mi fruta favorita de prueba es el mango","category":"correction"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Corregido.",
            uso: UsoTokens(entrada: 60, salida: 6)
        )
        arnes.estado.enviar(Self.promptB21Turno1)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(arnes.estado.config.memoria.count, 1)
        XCTAssertEqual(
            arnes.estado.config.memoria.first?.texto,
            "mi fruta favorita de prueba es el mango"
        )
        let contenidoTrasTurno1 = sesion.contenido
        XCTAssertEqual(
            Self.cuenta(contenidoTrasTurno1, "MemoryLineNotice"),
            1,
            "El turno 1 deja exactamente un aviso de memoria"
        )

        // Turno 2: DOS invocaciones de guardado en el mismo turno. La primera
        // aplica; la segunda la rechaza el ejecutor por el tope 1/turno. Debe
        // quedar una sola linea nueva y una sola entrada nueva.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b21-turno2-a",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"mi color favorito de prueba es el verde","category":"preference"}"#
                ),
                ToolCall(
                    id: "call-b21-turno2-b",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"mi animal favorito de prueba es el gato","category":"preference"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Listo.",
            uso: UsoTokens(entrada: 70, salida: 6)
        )
        arnes.estado.enviar(Self.promptB21Turno2)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            2,
            "Solo el primer guardado del turno 2 puede crear entrada"
        )
        XCTAssertTrue(
            arnes.estado.config.memoria.contains {
                $0.texto == "mi color favorito de prueba es el verde"
            }
        )
        XCTAssertFalse(
            arnes.estado.config.memoria.contains {
                $0.texto.contains("animal favorito")
            },
            "El segundo guardado se rechaza sin mutar el registro"
        )
        let contenidoTrasTurno2 = sesion.contenido
        XCTAssertEqual(
            Self.cuenta(contenidoTrasTurno2, "MemoryLineNotice"),
            2,
            "El turno 2 anade exactamente una linea, no dos"
        )
        XCTAssertEqual(
            Self.cuenta(contenidoTrasTurno2, "MemoryLineNotice")
                - Self.cuenta(contenidoTrasTurno1, "MemoryLineNotice"),
            1
        )

        // Turno 3: orden explicita de borrado. La linea es la de B1.2 y la
        // entrada deja de existir (N -> N-1).
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b21-turno3",
                    nombre: Memoria.nombreBorrar,
                    argumentos: #"{"entry_id":"\#(Self.semillaB21.id.uuidString)"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Olvidado.",
            uso: UsoTokens(entrada: 80, salida: 4)
        )
        arnes.estado.enviar(Self.promptB21Turno3)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // El borrado quita exactamente la semilla; la entrada del turno 2 sigue.
        XCTAssertEqual(arnes.estado.config.memoria.count, 1)
        XCTAssertFalse(
            arnes.estado.config.memoria.contains {
                $0.id == Self.semillaB21.id
            },
            "La entrada borrada deja de existir (N -> N-1)"
        )
        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            3,
            "El guion completo deja exactamente 3 lineas de memoria"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice")
                - Self.cuenta(contenidoTrasTurno2, "MemoryLineNotice"),
            1,
            "El turno 3 anade exactamente una linea"
        )
        XCTAssertTrue(
            contenido.contains(
                "MemoryLineNotice(text: \"Memoria: entrada borrada · "
                    + "mi fruta favorita de prueba es el mango\", "
                    + "hasUndo: true)"
            )
        )
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "UserBubble", "MemoryLineNotice", "AssistantBubble",
                "UserBubble", "MemoryLineNotice", "AssistantBubble",
                "UserBubble", "MemoryLineNotice", "AssistantBubble"
            ],
            "Solo burbujas y una unica linea por turno con operacion"
        )
        XCTAssertFalse(contenido.contains("{"))
        XCTAssertFalse(contenido.contains("tool_calls"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (4) Traza de la partida B2.2 (Chat Temporal)

    /// Prompt literal de la ficha B2.2: un dato durable sin verbos de orden.
    private static let promptB22 =
        "Mi palabra clave de prueba es LUNA-7 y prefiero respuestas cortas, úsalo en esta conversación"

    private static let semillaB22 = EntradaMemoria(
        id: UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!,
        texto: "Prefiere respuestas breves",
        fecha: Date(timeIntervalSince1970: 400),
        categoria: .preference
    )

    /// Guion literal de B2.2: un hilo temporal con el prompt de la ficha.
    ///
    /// La traza tiene que salir con 0 `MemoryLineNotice`: en un hilo temporal no
    /// hay ninguna operacion de Memoria que avisar. Al cerrar y releer el
    /// almacen no queda ni una conversacion ni una entrada nueva. El contraste
    /// positivo (el mismo guion en un chat normal si ofrece las herramientas)
    /// vive en `ChatTemporalTests`, para no mezclar dos hilos en una traza.
    func testElGuionB22ProduceLaTrazaB22() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = [Self.semillaB22]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B2.2.txt")
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        arnes.transporte.guionar(
            texto: "Entendido: LUNA-7, respuestas cortas.",
            uso: UsoTokens(entrada: 45, salida: 8)
        )

        arnes.estado.nuevaConversacionTemporal()
        let idTemporal = arnes.estado.conversacion.id
        arnes.estado.enviar(Self.promptB22)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // El payload del turno no ofrecio ninguna herramienta de Memoria.
        let peticion = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        let cuerpo = try XCTUnwrap(String(data: peticion, encoding: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        )
        XCTAssertNil(json["tools"], "El hilo temporal ofrecio herramientas")
        XCTAssertFalse(cuerpo.contains(Self.semillaB22.texto), cuerpo)

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            0,
            "Un hilo temporal no deja ninguna linea de aviso de memoria"
        )
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"],
            "Solo la burbuja del dueno y la respuesta"
        )
        XCTAssertFalse(contenido.contains("{"))
        XCTAssertFalse(contenido.contains("tool_calls"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        // Salida sin rastro: al cerrar y releer el almacen no hay conversacion
        // nueva, ni entrada nueva, ni archivo en disco.
        let memoriaAntes = arnes.estado.config.memoria
        arnes.estado.cerrarHiloTemporal()
        arnes.estado.recargarConversaciones()

        XCTAssertTrue(arnes.estado.conversaciones.isEmpty)
        XCTAssertEqual(arnes.estado.config.memoria, memoriaAntes)
        XCTAssertNil(arnes.estado.conversaciones.first { $0.id == idTemporal })
        let archivos = (try? FileManager.default.contentsOfDirectory(
            atPath: arnes.directorioStore.path
        )) ?? []
        XCTAssertTrue(
            archivos.filter { $0.hasSuffix(".json") }.isEmpty,
            "El hilo temporal dejo archivo: \(archivos)"
        )

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (5) Traza de la partida B2.3 (guion literal de 3 turnos)

    /// Guion literal de B2.3 con el interruptor «Memoria inteligente» en ON.
    ///
    /// Turno 1: un dato de preferencia sin verbos de orden; el modelo juzga y
    /// guarda. Turno 2: la correccion usa el `entry_id` real del turno 1, de
    /// modo que el conteo no crece (N = N). Turno 3: una traduccion puntual,
    /// sin llamada de memoria. La traza tiene que dejar 2 `MemoryLineNotice` en
    /// total (1 + 1 + 0), 0 UUIDs y 0 bloques crudos.
    private static let promptB23Turno1 =
        "Mi color favorito de prueba es el verde"
    private static let promptB23Turno2 =
        "Ya no es el verde, mi color favorito de prueba ahora es el azul"
    private static let promptB23Turno3 =
        "Traduce al inglés: la casa es grande"

    func testElGuionB23ProduceLaTrazaB23() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        // Chat nuevo: sin entradas previas. El interruptor se enciende de
        // forma explicita, como en el humo vivo de la ficha (nace en OFF).
        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B2.3.txt")
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Turno 1: guardado por juicio, sin orden explicita del dueno.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b23-turno1",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"mi color favorito de prueba es el verde","category":"preference"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Guardado. El verde queda como tu color de prueba.",
            uso: UsoTokens(entrada: 60, salida: 10)
        )
        arnes.estado.enviar(Self.promptB23Turno1)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            1,
            "El turno 1 crea exactamente una entrada"
        )
        let creada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(creada.categoria, .preference)
        XCTAssertEqual(
            creada.texto,
            "mi color favorito de prueba es el verde"
        )
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            1,
            "El turno 1 deja exactamente un aviso de guardado"
        )
        XCTAssertTrue(
            sesion.contenido.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "mi color favorito de prueba es el verde\", "
                    + "hasUndo: true)"
            ),
            sesion.contenido
        )

        // Turno 2: correccion sobre la MISMA entrada (entry_id real del
        // turno 1). El conteo no crece: N = N.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b23-turno2",
                    nombre: Memoria.nombreActualizar,
                    argumentos: #"{"entry_id":"\#(creada.id.uuidString)","content":"mi color favorito de prueba es el azul","category":"correction"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Actualizado: ahora es el azul.",
            uso: UsoTokens(entrada: 70, salida: 8)
        )
        arnes.estado.enviar(Self.promptB23Turno2)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            1,
            "Actualizar no hace crecer el conteo (N = N)"
        )
        XCTAssertEqual(arnes.estado.config.memoria.first?.id, creada.id)
        XCTAssertEqual(
            arnes.estado.config.memoria.first?.texto,
            "mi color favorito de prueba es el azul"
        )
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            2,
            "El turno 2 anade exactamente una linea"
        )
        XCTAssertTrue(
            sesion.contenido.contains(
                "MemoryLineNotice(text: \"Memoria actualizada: "
                    + "mi color favorito de prueba es el azul\", "
                    + "hasUndo: true)"
            ),
            sesion.contenido
        )

        // Turno 3 (negativo): una traduccion puntual no llama a memoria.
        arnes.transporte.guionar(
            texto: "The house is big.",
            uso: UsoTokens(entrada: 40, salida: 5)
        )
        arnes.estado.enviar(Self.promptB23Turno3)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            2,
            "El turno 3 no deja ninguna linea: total 2"
        )
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "UserBubble", "MemoryLineNotice", "AssistantBubble",
                "UserBubble", "MemoryLineNotice", "AssistantBubble",
                "UserBubble", "AssistantBubble"
            ],
            "Un aviso por turno con operacion y ninguno en el turno efimero"
        )

        // El turno 3 no ejecuto ninguna herramienta de memoria: solo los dos
        // turnos con operacion dejaron resultado interno en el historial.
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.filter {
                $0.rol == .herramienta
            }.count,
            2,
            "El turno 3 no puede dejar un resultado de herramienta"
        )
        let respuestaTurno3 = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .asistente }
        ).texto.lowercased()
        XCTAssertFalse(respuestaTurno3.contains("guard"))
        XCTAssertFalse(respuestaTurno3.contains("memoria"))
        XCTAssertFalse(respuestaTurno3.contains("anot"))

        // El payload del turno 1 lleva la instruccion de juicio con las cuatro
        // categorias; el del turno 3 inyecta la entrada corregida con su id.
        let peticiones = arnes.transporte.peticionesRegistradas
        let primerCuerpo = try XCTUnwrap(peticiones.first?.cuerpo)
        let primerPayload = try XCTUnwrap(
            String(data: primerCuerpo, encoding: .utf8)
        )
        XCTAssertTrue(primerPayload.contains("Memoria inteligente activada"))
        for categoria in [
            "durable_fact", "preference", "correction", "commitment"
        ] {
            XCTAssertTrue(primerPayload.contains(categoria), categoria)
        }
        let ultimoCuerpo = try XCTUnwrap(peticiones.last?.cuerpo)
        let ultimoPayload = try XCTUnwrap(
            String(data: ultimoCuerpo, encoding: .utf8)
        )
        XCTAssertTrue(
            ultimoPayload.contains(
                "mi color favorito de prueba es el azul"
            )
        )
        XCTAssertTrue(ultimoPayload.contains(creada.id.uuidString))

        XCTAssertFalse(contenido.contains("{"))
        XCTAssertFalse(contenido.contains("tool_calls"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (5b) Traza de la partida B2.4 (freno sensible, 2 turnos)

    /// Guion literal de B2.4 en un chat normal con el interruptor en ON.
    ///
    /// Turno 1: un dato de salud sin pedir que se guarde; el modelo propone y
    /// el dueno DENIEGA. Turno 2: un dato de finanzas; el modelo propone y el
    /// dueno APRUEBA. La traza tiene que dejar 0 avisos en el turno 1 y
    /// exactamente 1 en el turno 2 (total 1), con la hoja como unico artefacto
    /// mientras esta pendiente, 0 UUIDs, 0 bloques crudos y 0 nombres tecnicos.
    private static let promptB24Turno1 =
        "Dato de prueba de salud: mi presión arterial de prueba es 120 sobre 80, ¿qué significa?"
    private static let promptB24Turno2 =
        "Dato de prueba de finanzas: mi presupuesto de prueba es 500 al mes, ¿cómo lo reparto?"

    func testElGuionB24ProduceLaTrazaB24() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B2.4.txt")
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Turno 1 (denegacion): propuesta de salud, hoja, [Denegar].
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b24-traza-1",
                    nombre: Memoria.nombreProponerSensible,
                    argumentos: #"{"content":"mi presión arterial de prueba es 120 sobre 80","sensitive_category":"health"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido: es una lectura normal de prueba.",
            uso: UsoTokens(entrada: 60, salida: 9)
        )
        arnes.estado.enviar(Self.promptB24Turno1)
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta de salud no apareció"
        )

        // Mientras la hoja esta pendiente es el UNICO artefacto del turno.
        let pendientes = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            pendientes,
            [
                .burbujaUsuario(texto: Self.promptB24Turno1),
                .hojaAprobacionMemoria(
                    texto: "mi presión arterial de prueba es 120 sobre 80",
                    categoriaSensible: .health,
                    estado: .pendiente
                )
            ]
        )
        try sesion.capturar(pendientes)

        arnes.estado.denegarPropuestaSensible()
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(
            arnes.estado.config.memoria,
            [],
            "El turno 1 denegado no deja ninguna entrada"
        )
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            0,
            "El turno 1 no puede dejar aviso de guardado"
        )
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryApprovalSheet"),
            1,
            "El turno 1 deja la hoja como artefacto"
        )
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, "call-b24-traza-1")
        XCTAssertEqual(rechazo.texto, "denegado por el dueno")

        // Turno 2 (aprobacion): propuesta de finanzas, hoja, [Aprobar].
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b24-traza-2",
                    nombre: Memoria.nombreProponerSensible,
                    argumentos: #"{"content":"mi presupuesto de prueba es 500 al mes","sensitive_category":"finances"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Anotado: 500 al mes.",
            uso: UsoTokens(entrada: 70, salida: 8)
        )
        arnes.estado.enviar(Self.promptB24Turno2)
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta de finanzas no apareció"
        )
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        arnes.estado.aprobarPropuestaSensible()
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // Exactamente una entrada nueva, con su categoria sensible y su aviso.
        XCTAssertEqual(arnes.estado.config.memoria.count, 1)
        let creada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(creada.texto, "mi presupuesto de prueba es 500 al mes")
        XCTAssertEqual(creada.categoriaSensible, .finances)
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            1,
            "El turno 2 anade exactamente una linea (total 1)"
        )
        XCTAssertTrue(
            sesion.contenido.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "mi presupuesto de prueba es 500 al mes\", "
                    + "hasUndo: true)"
            ),
            sesion.contenido
        )
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryApprovalSheet"),
            2,
            "Cada turno deja constancia de su hoja"
        )

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "UserBubble", "MemoryApprovalSheet", "AssistantBubble",
                "UserBubble", "MemoryApprovalSheet", "MemoryLineNotice",
                "AssistantBubble"
            ],
            "Solo burbujas, la hoja de cada turno y una unica linea de aviso"
        )
        XCTAssertFalse(contenido.contains("{"))
        XCTAssertFalse(contenido.contains("tool_calls"))
        XCTAssertFalse(contenido.contains("health"))
        XCTAssertFalse(contenido.contains("finances"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (3b) Captura tras deshacer (si aplica)

    func testLaSesionRegistraElDeshacerDeLaLineaDeMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [Self.llamadaMemoriaArchivada]
        )
        arnes.transporte.guionar(
            texto: Self.respuestaMemoriaFixture,
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar(Self.promptMemoria)
        try await arnes.esperarTurno()

        let ruta = FileManager.default.temporaryDirectory
            .appendingPathComponent("traza-deshacer-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: ruta) }

        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let memorias = arnes.estado.eventosDeMemoriaVisibles(elementos)
        let indice = try XCTUnwrap(
            elementos.firstIndex { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }
        )
        let evento = try XCTUnwrap(memorias[indice])
        XCTAssertTrue(
            arnes.estado.deshacerCambioDeMemoria(id: evento.id)
        )

        // Tras deshacer, la misma linea cambia de estado: la sesion la vuelve
        // a emitir con hasUndo false.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(Self.cuenta(sesion.contenido, "MemoryLineNotice"), 2)
        XCTAssertTrue(sesion.contenido.contains("hasUndo: false"))
    }

    // MARK: - (4) La sesion no repite la misma foto en cada transicion

    func testLaSesionSoloEmiteElementosNuevosOCambiados() throws {
        let ruta = FileManager.default.temporaryDirectory
            .appendingPathComponent("traza-diff-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: ruta) }

        let usuario: ElementoHiloVisible = .burbujaUsuario(texto: "Hola")
        let asistente: ElementoHiloVisible = .burbujaAsistente(
            segmentos: [.texto("Listo")]
        )

        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar([])
        try sesion.capturar([usuario])
        try sesion.capturar([usuario, asistente])

        let lineas = sesion.contenido.split(separator: "\n")
        XCTAssertEqual(lineas.count, 3)
        XCTAssertEqual(
            Self.etiquetasSuperiores(sesion.contenido),
            ["UserBubble", "AssistantBubble"]
        )
    }

    func testLaSesionDeclaraElModoEnLaPrimeraLinea() throws {
        let ruta = FileManager.default.temporaryDirectory
            .appendingPathComponent("traza-modo-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: ruta) }

        let sesion = try SesionTraza(
            ruta: ruta,
            modo: "replay-temporizado"
        )
        try sesion.capturar([.burbujaUsuario(texto: "Hola")])

        let primera = sesion.contenido
            .split(separator: "\n")
            .first
            .map { String($0) } ?? ""
        XCTAssertEqual(primera, "modo: replay-temporizado")
    }

    // MARK: - (5) Formato de segmentos y del resto del catalogo

    func testElVolcadoAnidaProsaYCodigoBajoLaBurbuja() {
        let elementos: [ElementoHiloVisible] = [
            .burbujaAsistente(
                segmentos: [
                    .texto("Así:"),
                    .codigo(
                        lenguaje: "swift",
                        textoCrudo: "let x = \"LUNA-7\"\nprint(x)"
                    )
                ]
            )
        ]

        XCTAssertEqual(
            TrazaVista.lineasHilo(elementos, t: "0.0"),
            [
                "[t=0.0s] AssistantBubble(\"Así:\\n"
                    + "let x = \\\"LUNA-7\\\"\\nprint(x)\")",
                "  [t=0.0s] TextSegment(\"Así:\")",
                "  [t=0.0s] CodeBlock(lenguaje: \"swift\", "
                    + "textoCrudo: \"let x = \\\"LUNA-7\\\"\\nprint(x)\")"
            ]
        )
    }

    func testTareaYBusquedaUsanLasEtiquetasDelCatalogo() {
        let tarea: [ElementoTareaVisible] = [
            .cabeceraTarea(
                estado: .enCurso,
                pasoActual: 1,
                pasosTotales: 2,
                costoSellado: Decimal(0.5)
            ),
            .tarjetaPlan(
                pasos: [PasoPlan(orden: 1, texto: "Buscar fuentes")],
                version: 1
            ),
            .filaPaso(
                paso: 1,
                estado: .enCurso,
                etiquetaDinamica: "Paso 1",
                duracion: nil,
                costo: nil
            )
        ]
        XCTAssertEqual(
            TrazaVista.lineasTarea(tarea, t: "0.0").compactMap(Self.etiqueta),
            ["TaskHeader", "PlanCard", "StepRow"]
        )

        let busqueda: [ElementoBusquedaVisible] = [
            .resultadoBusqueda(titulo: "Recetas", vistaPrevia: "Hablemos"),
            .sinResultados(termino: "LUNA-7")
        ]
        XCTAssertEqual(
            TrazaVista.lineasBusqueda(busqueda, t: "0.0")
                .compactMap(Self.etiqueta),
            ["SearchResultRow", "SearchEmptyState"]
        )
    }

    // MARK: - Utilidades

    /// Ruta de archivo de humo si la coordinacion definio `NODO_HUMOS_DIR`.
    private static func rutaDelHumo(_ nombre: String) -> URL? {
        guard let directorio = ProcessInfo.processInfo.environment[
            "NODO_HUMOS_DIR"
        ], !directorio.isEmpty else { return nil }
        let ruta = URL(fileURLWithPath: directorio, isDirectory: true)
            .appendingPathComponent(nombre)
        return FileManager.default.fileExists(atPath: ruta.path) ? ruta : nil
    }

    /// Ruta de la traza: `NODO_TRAZA_DIR` o el temporal del simulador.
    private static func rutaDeTraza(_ nombre: String) throws -> URL {
        let base: URL
        if let directorio = ProcessInfo.processInfo.environment[
            "NODO_TRAZA_DIR"
        ], !directorio.isEmpty {
            base = URL(fileURLWithPath: directorio, isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("NodoTrazas", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        return base.appendingPathComponent(nombre)
    }

    /// Etiqueta de una linea `[t=...s] Etiqueta(...)`.
    private static func etiqueta(_ linea: String) -> String? {
        guard let rango = linea.range(of: "] ") else { return nil }
        let resto = linea[rango.upperBound...]
        guard let parentesis = resto.firstIndex(of: "(") else { return nil }
        return String(resto[..<parentesis])
    }

    /// Etiquetas de las lineas de primer nivel (sin sangria).
    private static func etiquetasSuperiores(_ contenido: String) -> [String] {
        contenido.split(separator: "\n").compactMap { linea in
            guard !linea.hasPrefix(" "), !linea.hasPrefix("\t") else {
                return nil
            }
            return etiqueta(String(linea))
        }
    }

    private static func cuenta(_ contenido: String, _ aguja: String) -> Int {
        contenido.components(separatedBy: aguja).count - 1
    }

    /// Los cuatro conteos de G-04 tal como los aplica la Puerta C.
    private static func comprobarConteosDeLaPuertaC(
        _ contenido: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            contenido.contains("HERRAMIENTA"),
            "Conteo 1: la traza no puede llevar el rotulo HERRAMIENTA",
            file: file,
            line: line
        )
        XCTAssertNil(
            contenido.range(
                of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                options: .regularExpression
            ),
            "Conteo 2: la traza no puede llevar UUIDs",
            file: file,
            line: line
        )
        for nombre in [
            "memoria_chat", "traer_url", "proponer_memoria", "save_memory",
            "update_memory", "propose_sensitive_memory", "delete_memory"
        ] {
            XCTAssertEqual(
                cuenta(contenido, nombre),
                0,
                "Conteo 4: la traza no puede citar \(nombre)",
                file: file,
                line: line
            )
        }
    }

    private static func publicar(
        _ ruta: URL,
        _ contenido: String,
        en test: XCTestCase
    ) {
        print("TRAZA \(ruta.lastPathComponent) (\(ruta.path)):\n\(contenido)")
        let adjunto = XCTAttachment(string: contenido)
        adjunto.name = ruta.lastPathComponent
        adjunto.lifetime = .keepAlways
        test.add(adjunto)
    }
}
