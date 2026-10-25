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

    // MARK: - (5c) Traza de la partida B2.5 (creación rechazada en tope)

    /// Guion literal de B2.5 en un chat normal con el interruptor en ON y una
    /// semilla de 50 entradas.
    ///
    /// Turno 1: el dueño enuncia un dato de preferencia sin pedir guardarlo; el
    /// modelo invoca `save_memory` y el ejecutor lo rechaza por tope. La traza
    /// tiene que quedar en 0 `MemoryLineNotice` (no hubo guardado), 0 UUIDs, 0
    /// bloques crudos y 0 nombres técnicos, y el payload tiene que inyectar
    /// exactamente 50 entradas.
    private static let promptB25 = "Mi color favorito de prueba es el verde"

    private static func semillaB25(_ cantidad: Int) -> [EntradaMemoria] {
        let categorias = CategoriaMemoria.paraActualizar
        return (1...cantidad).map { numero in
            EntradaMemoria(
                id: UUID(
                    uuidString: String(
                        format: "%08X-0000-4000-8000-%012X",
                        UInt32(numero),
                        UInt32(numero)
                    )
                )!,
                texto: String(format: "prueba-%02d", numero),
                fecha: Date(timeIntervalSince1970: TimeInterval(numero)),
                categoria: categorias[numero % categorias.count]
            )
        }
    }

    func testElGuionB25ProduceLaTrazaB25() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = Self.semillaB25(50)
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_B2.5.txt")
        let sesion = try SesionTraza(ruta: ruta)
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b25-traza-1",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"mi color favorito de prueba es el verde","category":"preference"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido: tu color de prueba es el verde.",
            uso: UsoTokens(entrada: 60, salida: 8)
        )
        arnes.estado.enviar(Self.promptB25)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        // El ejecutor rechazó la creación: 0 entradas nuevas y 0 avisos.
        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            50,
            "Con el tope lleno no puede entrar ninguna entrada nueva"
        )
        XCTAssertEqual(
            Self.cuenta(sesion.contenido, "MemoryLineNotice"),
            0,
            "Sin guardado no hay línea de aviso en el hilo"
        )
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, "call-b25-traza-1")
        XCTAssertTrue(rechazo.texto.contains("memoria en tope"), rechazo.texto)

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"],
            "Solo las dos burbujas: la herramienta no es un elemento visible"
        )
        XCTAssertFalse(contenido.contains("{"))
        XCTAssertFalse(contenido.contains("tool_calls"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        // El payload inyecta exactamente 50 entradas, ni una más.
        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        )
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let sistemaMensaje = try XCTUnwrap(
            mensajes.first { $0["role"] as? String == "system" }
        )
        let sistema = try XCTUnwrap(sistemaMensaje["content"] as? String)
        XCTAssertEqual(
            sistema.components(separatedBy: "\n- id: ").count - 1,
            50,
            "El bloque inyectado suma exactamente 50 entradas"
        )

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

    // MARK: - (6) Traza de la partida B3-A (hilo de Tarea, 2 turnos)

    /// Guion literal de B3-A: crear tarea, enviar el encargo y, antes de
    /// [Empezar], enviar un ajuste.
    ///
    /// La traza tiene que dejar SOLO etiquetas del catalogo cerrado, en el
    /// orden del contrato: encargo (UserBubble) -> tarjeta de plan v1
    /// (PlanCard) -> turno de ajuste (UserBubble) -> tarjeta v2 (PlanCard).
    /// Cero `MemoryLineNotice`, cero UUIDs, cero resultados de herramienta y
    /// cero elementos de formulario. No se toca [Empezar]: la ejecucion es el
    /// humo de B3-B.
    private static let encargoB3A = "Consulta https://example.com y proponé "
        + "guardar en Memoria una frase sobre ese dominio"
    private static let ajusteB3A = "Que la frase sea corta"

    func testElGuionB3AProduceLaTrazaDelHiloDeTarea() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let tarea = arnes.estado.crearTarea()
        let hilo = HiloTareaViewModel()

        func capturar() {
            guard let actual = arnes.estado.tareas.first(
                where: { $0.id == tarea.id }
            ) else { return }
            hilo.reconstruir(
                con: actual,
                proyeccion: arnes.estado.elementosVisiblesDeTarea(actual)
            )
        }

        // E0: tarea nueva, hilo vacio.
        capturar()

        // Turno 1: el encargo entra como burbuja; la cabecera pasa a
        // Planificando. El plan se pide sin herramientas.
        arnes.transporte.guionar(
            texto: "1. Consultar https://example.com\n"
                + "2. Proponer guardar en Memoria una frase sobre el dominio"
        )
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(
                id: tarea.id,
                texto: Self.encargoB3A
            )
        )
        capturar()

        await arnes.estado.solicitarPlanTarea(id: tarea.id)
        capturar()

        // Turno 2: el ajuste. Se retiene la red para capturar el estado E1
        // (plan viejo invalidado, turno ya en el hilo) antes de la respuesta.
        arnes.transporte.retenerStream(en: 2)
        arnes.transporte.guionar(
            texto: "1. Consultar https://example.com\n"
                + "2. Proponer una frase corta sobre el dominio"
        )
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(
                id: tarea.id,
                texto: Self.ajusteB3A
            )
        )
        let peticion = Task {
            await arnes.estado.solicitarPlanTarea(id: tarea.id)
        }
        try await arnes.esperar(
            {
                guard let actual = arnes.estado.tareas.first(
                    where: { $0.id == tarea.id }
                ) else { return false }
                return actual.plan == nil
                    && arnes.estado.idTareaPlanificando == tarea.id
            },
            mensaje: "El plan anterior no se invalidó antes de pedir el nuevo"
        )
        capturar()
        arnes.transporte.liberarStreamRetenido()
        await peticion.value
        capturar()

        let contenido = hilo.trazaTexto
        let ruta = try Self.rutaDeTraza("ui_transcript_B3-A.txt")
        try TrazaVista.escribir(hilo.traza, a: ruta)

        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            [
                "TaskHeader", "TaskHeader", "UserBubble",
                "TaskHeader", "PlanCard",
                "TaskHeader", "UserBubble",
                "TaskHeader", "PlanCard"
            ],
            "La traza del hilo sigue el guion: encargo, plan v1, ajuste, plan v2"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "PlanCard"),
            2,
            "El ajuste produce una tarjeta nueva (v1 y v2 visibles en el guion)"
        )
        XCTAssertTrue(contenido.contains("version: 1"), contenido)
        XCTAssertTrue(contenido.contains("version: 2"), contenido)
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)

        // El plan no ejecuto nada: cero libro y payload sin herramientas.
        let actual = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertTrue(actual.pasos.isEmpty)
        XCTAssertEqual(arnes.transporte.peticionesRegistradas.count, 2)
        for peticion in arnes.transporte.peticionesRegistradas {
            let cuerpo = try XCTUnwrap(peticion.cuerpo)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
            )
            XCTAssertNil(json["tools"])
        }

        XCTAssertFalse(contenido.contains("ToolRawOutput"))
        XCTAssertFalse(contenido.contains("HERRAMIENTA"))
        XCTAssertFalse(contenido.contains("TextEditor"))
        XCTAssertFalse(contenido.contains("instruccion-tarea"))
        XCTAssertNil(
            contenido.range(
                of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                options: .regularExpression
            ),
            "La traza del hilo no puede llevar UUIDs"
        )
        Self.comprobarConteosDeLaPuertaC(contenido)

        Self.publicar(ruta, contenido, en: self)
    }


    // MARK: - (7) Traza de la partida B3-B (progreso vivo en el hilo de Tarea)

    /// Espera real de la corrida viva, en segundos, y textos archivados.
    ///
    /// Los valores salen de `humos/b3b-corrida1-humo.json` (controlador vivo
    /// `humos/humo_b3b.py`, modelo combo/deepseek-v4-1-flash). En CI no hay
    /// directorio de humos: este fixture reproduce los MISMOS tiempos de reloj
    /// de pared de la captura, y el replay los espera de verdad. La traza se
    /// sigue produciendo el ViewModel, nunca a mano.
    ///
    /// La fidelidad es de TIEMPOS, no byte a byte: la prosa y el HTML de los
    /// textos archivados van adaptados (sin la envoltura del JSON vivo), asi
    /// que la traza no es copia literal del archivo del humo.
    private static let contenidoArchivadoDelDominio = """
    <!doctype html><html lang=en><head><meta charset=utf-8><title>Example \
    Domain</title></head><body><p>This domain is for use in documentation \
    examples without needing permission. This is not a service; avoid relying \
    on it for testing and monitoring purposes.</p></body></html>
    """

    private static let respuestaFinalArchivada = """
    He consultado https://example.com correctamente (título "Example Domain"; \
    el propio sitio indica que es un dominio para ejemplos de documentación y \
    que no es un servicio).\n\nPropuse guardar en Memoria la frase: «example.com \
    es un dominio reservado para ejemplos de documentación» (9 palabras).\n\nEl \
    dueño denegó la propuesta, así que no se escribió nada en Memoria.
    """

    /// Registro temporizado de la corrida 1: plan, tres piernas y sus esperas.
    private static func registroB3B(piernas: Int = 3) throws -> RegistroB3B {
        let plan = [
            "Acceder a https://example.com mediante una consulta HTTP y registrar el código de estado y el contenido devuelto.",
            "Verificar que la respuesta sea correcta (código 200) y anotar el título y el propósito visible del sitio.",
            "Extraer los datos clave del dominio example.com (nombre, uso previsto y contenido principal).",
            "Redactar una frase breve sobre el dominio, con un máximo de 10 palabras.",
            "Comprobar que la frase cumpla el límite de extensión y describa lo observado.",
            "Presentar la frase corta al usuario como propuesta de guardado en Memoria.",
            "Guardar la frase en Memoria solo tras la confirmación explícita del usuario."
        ]
        let llamadaUrl = ToolCall(
            id: "call_00_archivada_url",
            nombre: "traer_url",
            argumentos: #"{"url": "https://example.com"}"#
        )
        let llamadaMemoria = ToolCall(
            id: "call_00_archivada_memoria",
            nombre: Memoria.nombreHerramientaTarea,
            argumentos: #"{"accion": "guardar", "texto": "example.com es un dominio reservado para ejemplos de documentación."}"#
        )

        let todas = [
            RegistroB3B.Pierna(
                http: 200,
                primerEvento: 2.4553,
                ultimoEvento: 2.7448,
                texto: "I'll fetch the page first.",
                llamadas: [llamadaUrl],
                uso: UsoTokens(entrada: 770, salida: 48),
                resultadosDeHerramienta: [:]
            ),
            RegistroB3B.Pierna(
                http: 200,
                primerEvento: 6.6347,
                ultimoEvento: 6.6408,
                texto: "",
                llamadas: [llamadaMemoria],
                uso: UsoTokens(entrada: 989, salida: 221),
                resultadosDeHerramienta: [
                    llamadaUrl.id: contenidoArchivadoDelDominio
                ]
            ),
            RegistroB3B.Pierna(
                http: 200,
                primerEvento: 8.9301,
                ultimoEvento: 8.9716,
                texto: respuestaFinalArchivada,
                llamadas: [],
                uso: UsoTokens(entrada: 1229, salida: 119),
                resultadosDeHerramienta: [:]
            )
        ]
        return RegistroB3B(
            modo: "replay-temporizado",
            piernas: Array(todas.prefix(max(1, piernas))),
            plan: plan
        )
    }

    /// Carga el registro desde los humos vivos si la coordinacion los expone.
    private static func registroVivoB3B() throws -> RegistroB3B {
        if let ruta = rutaDelHumo("b3b-corrida1-humo.json") {
            return try RegistroB3B.cargar(ruta)
        }
        return try registroB3B()
    }

    /// Guion del nivel 2 de B3-B: replay temporizado de la corrida viva.
    ///
    /// El motor (ToolLoop), el ViewModel del hilo y la traza son los de
    /// produccion. Lo unico que cambia es el transporte: entrega las respuestas
    /// archivadas despues de una espera REAL igual al desplazamiento de reloj
    /// de pared que midio el controlador vivo. Por eso la traza prueba el
    /// latido (renovacion cada <=1,5 s durante una espera >=2,0 s) y la primera
    /// senal (<=300 ms desde el toque), y no una reproduccion en frio.
    func testElGuionVivoB3BProduceLaTrazaDeProgresoVivo() async throws {
        let registro = try Self.registroVivoB3B()
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // El plan aprobado que viaja en el mensaje de ejecucion archivado.
        let textoDelPlan = registro.plan.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        XCTAssertFalse(registro.plan.isEmpty, "El humo archivado no trae plan")
        arnes.transporte.guionar(texto: textoDelPlan)

        let tarea = arnes.estado.crearTarea(
            instruccion: "Consulta https://example.com y proponé guardar en "
                + "Memoria una frase sobre ese dominio"
        )
        await arnes.estado.generarPlan(id: tarea.id)

        // Streaming 1 = plan. Los siguientes son las piernas archivadas, cada
        // una precedida por su espera real.
        for (indice, pierna) in registro.piernas.enumerated() {
            let numeroDeStream = indice + 2
            let espera = indice == 0
                ? registro.esperaInicial
                : registro.retraso(dePierna: indice)
            arnes.transporte.retrasarStream(en: numeroDeStream, segundos: espera)
            arnes.transporte.guionar(
                texto: pierna.texto,
                uso: pierna.uso,
                toolCalls: pierna.llamadas
            )
            for resultado in pierna.resultadosDeHerramienta.values {
                arnes.transporte.guionarUnaria(
                    HTTPRespuesta(
                        estado: 200,
                        cabeceras: ["Content-Type": "text/html"],
                        cuerpo: Data(resultado.utf8)
                    )
                )
            }
        }

        let hilo = HiloTareaViewModel()
        hilo.conectar(a: arnes.estado, tareaID: tarea.id)

        hilo.marcarToqueEmpezar()
        let toque = try XCTUnwrap(hilo.toqueEmpezar)
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        // (b) Primera senal: se emite en el ciclo inmediato al toque.
        let senal = try XCTUnwrap(hilo.primeraSenal, "No hubo primera señal")
        let latencia = senal.timeIntervalSince(toque)
        XCTAssertLessThanOrEqual(
            latencia,
            0.3,
            "La primera señal tardó \(latencia) s (cota 300 ms)"
        )

        // La primera senal ya nombra el paso real y un estado dinamico real.
        // M1: el denominador es el libro, que acaba de resetearse, asi que la
        // primera senal es «Paso 1/1» aunque el plan tenga siete pasos.
        let trasElToque = hilo.traza.first { $0.contains("actividad:") }
        let lineaSenal = try XCTUnwrap(trasElToque)
        XCTAssertTrue(
            lineaSenal.contains("Consultando modelo"),
            "La primera señal no tiene estado dinámico real: \(lineaSenal)"
        )
        XCTAssertTrue(
            lineaSenal.contains("Paso 1/1"),
            "La primera señal no nombra el paso del libro: \(lineaSenal)"
        )

        // El paso 1 (traer_url) se completa ANTES de que el dueno decida nada:
        // la aprobacion es del paso 2.
        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            timeout: 30,
            mensaje: "La propuesta de Memoria no llegó a la hoja"
        )
        let filaUno = try Self.fila(hilo, paso: 1)
        XCTAssertEqual(filaUno.estado, .completado)
        XCTAssertNotNil(filaUno.duracion)
        XCTAssertNotNil(filaUno.costo)
        XCTAssertEqual(try Self.fila(hilo, paso: 2).estado, .esperandoAprobacion)
        XCTAssertEqual(hilo.cabecera.estado, .esperandoAprobacion)

        // La hoja se decidio EN EL HILO y se DENIEGA.
        arnes.estado.denegarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada, timeout: 30)

        let filaDenegada = try Self.fila(hilo, paso: 2)
        XCTAssertEqual(filaDenegada.estado, .denegado)
        XCTAssertTrue(
            arnes.estado.config.memoria.isEmpty,
            "Tras denegar, la entrada existe en Memoria"
        )

        // La cabecera cierra con el sello del libro, no con una cifra propia.
        let enLibro = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(
            hilo.cabecera.costoSellado,
            Decimal(enLibro.costoAcumuladoUSD ?? 0)
        )

        // M1: la cabecera cierra en 2/2. El plan tiene siete pasos y el libro
        // dos; el denominador es el libro, nunca el plan.
        XCTAssertEqual(hilo.cabecera.estado, .completada)
        XCTAssertEqual(hilo.cabecera.pasoActual, 2)
        XCTAssertEqual(hilo.cabecera.pasosTotales, 2)
        XCTAssertEqual(enLibro.pasos.count, 2)
        XCTAssertEqual(enLibro.plan?.pasos.count, 7)

        let contenido = "modo: \(registro.modo)\n" + hilo.trazaTexto
        let ruta = try Self.rutaDeTraza("ui_transcript_B3-B.txt")
        try contenido.write(to: ruta, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            contenido.contains(
                "estado: \"Completada\", pasoActual: 2, pasosTotales: 2"
            ),
            "La traza no cierra en Completada 2/2:\n\(contenido)"
        )

        // M1-2: el hueco entre pasos no anticipa el paso siguiente. El plan
        // tiene siete pasos, pero la traza no puede nombrar un «Paso 3/»
        // porque ese paso no llegó a existir.
        XCTAssertFalse(
            contenido.contains("Paso 3/"),
            "La traza anticipó un paso que el motor no ejecutó:\n\(contenido)"
        )

        // M1-3: la burbuja final declara los pasos del plan que quedaron sin
        // ejecutar, y el texto guardado en la tarea no se reescribe.
        XCTAssertTrue(
            contenido.contains(
                "Los pasos 3–7 del plan quedaron sin ejecutar: "
                    + "la tarea se completó sin ellos."
            ),
            "La burbuja final no declara el abandono del plan:\n\(contenido)"
        )
        // El motor acumula el texto de todas las piernas del bucle
        // (`ToolLoop` concatena sin separador: m3, preexistente), asi que el
        // guardado es «I'll fetch the page first.» + la prosa final. Por eso
        // se comprueba que la prosa esta, no que encabece.
        XCTAssertTrue(
            enLibro.resultado?.contains("He consultado https://example.com")
                == true,
            "El resultado guardado no conserva la prosa del modelo"
        )
        XCTAssertFalse(
            enLibro.resultado?.contains("quedaron sin ejecutar") == true,
            "La declaración de abandono se escribió en el resultado guardado"
        )

        // Y la reapertura (proyección) dice lo mismo que el vivo: 2/2.
        let reabierto = HiloTareaViewModel()
        reabierto.reconstruir(
            con: enLibro,
            proyeccion: arnes.estado.elementosVisiblesDeTarea(enLibro)
        )
        XCTAssertEqual(reabierto.cabecera.estado, .completada)
        XCTAssertEqual(reabierto.cabecera.pasoActual, 2)
        XCTAssertEqual(reabierto.cabecera.pasosTotales, 2)

        // (a) Ninguna fila llega a Completado sin En curso previo, ni a
        // Denegado sin pasar por la hoja (denegar ocurre antes de ejecutar).
        let secuencia = Self.transicionesDePaso(hilo.traza)
        var vistos: [Int: Set<String>] = [:]
        for (paso, estado) in secuencia {
            if estado == "Completado" {
                XCTAssertTrue(
                    vistos[paso, default: []].contains("En curso"),
                    "El paso \(paso) llegó a Completado sin En curso previo"
                )
            }
            if estado == "Denegado" {
                XCTAssertTrue(
                    vistos[paso, default: []].contains("Esperando aprobación"),
                    "El paso \(paso) llegó a Denegado sin pasar por la hoja"
                )
            }
            vistos[paso, default: []].insert(estado)
        }
        XCTAssertTrue(secuencia.contains { $0.0 == 1 && $0.1 == "Completado" })
        XCTAssertTrue(secuencia.contains { $0.0 == 2 && $0.1 == "Denegado" })

        // (d) Latido: ningun tramo de la ejecucion queda sin actividad visible
        // mas de 1,5 s, y hay un tramo continuo >= 2,0 s de espera de red.
        let tiempos = Self.tiemposDeTraza(hilo.traza)
        XCTAssertGreaterThan(tiempos.count, 6)
        var huecoMaximo: TimeInterval = 0
        for (a, b) in zip(tiempos, tiempos.dropFirst()) {
            huecoMaximo = max(huecoMaximo, b - a)
        }
        XCTAssertLessThanOrEqual(
            huecoMaximo,
            1.5,
            "Hueco de \(huecoMaximo) s sin actividad visible (cota 1,5 s)"
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(tiempos.last) - (tiempos.first ?? 0),
            2.0,
            "La traza no cubre un tramo de espera de red >= 2,0 s"
        )

        // (g) Cero cadenas demolidas y cero etiquetas fuera del catalogo.
        for demolida in [
            "La ejecución acaba de empezar",
            "Los pasos aparecerán aquí"
        ] {
            XCTAssertFalse(contenido.contains(demolida), contenido)
        }
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)
        Self.comprobarConteosDeLaPuertaC(contenido)
        for linea in hilo.traza {
            let etiqueta = try XCTUnwrap(Self.etiqueta(linea))
            XCTAssertTrue(
                Self.etiquetasValidas.contains(etiqueta),
                "Etiqueta fuera del catálogo: \(etiqueta)"
            )
        }

        Self.publicar(ruta, contenido, en: self)
    }

    /// Corrida 2 archivada: el dueno detiene en el paso 2.
    ///
    /// El replay es el mismo regimen; lo que cambia es que el ViewModel recibe
    /// [Detener] mientras el paso 2 esta en curso. Se afirma la preservacion:
    /// paso 1 Completado con duracion y sello, paso 2 NO completado, sin paso 3.
    func testLaDetencionEnB3BPreservaElPaso1YNoCreaElPaso3() async throws {
        let registro = try Self.registroB3B(piernas: 2)
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: registro.plan.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        )
        let tarea = arnes.estado.crearTarea(
            instruccion: "Consulta https://example.com y proponé guardar en "
                + "Memoria una frase sobre ese dominio"
        )
        await arnes.estado.generarPlan(id: tarea.id)

        for (indice, pierna) in registro.piernas.enumerated() {
            let espera = indice == 0
                ? registro.esperaInicial
                : registro.retraso(dePierna: indice)
            arnes.transporte.retrasarStream(en: indice + 2, segundos: espera)
            arnes.transporte.guionar(
                texto: pierna.texto,
                uso: pierna.uso,
                toolCalls: pierna.llamadas
            )
            for resultado in pierna.resultadosDeHerramienta.values {
                arnes.transporte.guionarUnaria(
                    HTTPRespuesta(
                        estado: 200,
                        cabeceras: ["Content-Type": "text/html"],
                        cuerpo: Data(resultado.utf8)
                    )
                )
            }
        }

        let hilo = HiloTareaViewModel()
        hilo.conectar(a: arnes.estado, tareaID: tarea.id)
        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        // Detener durante el paso 2.
        try await arnes.esperar(
            {
                arnes.estado.solicitudAprobacion != nil
                    || arnes.estado.tareas.first { $0.id == tarea.id }?
                        .pasos.count == 2
            },
            timeout: 30,
            mensaje: "El paso 2 no llegó a abrirse"
        )
        arnes.estado.detenerTarea(id: tarea.id)

        try await arnes.esperar(
            {
                arnes.estado.tareas.first { $0.id == tarea.id }?.estado
                    == .detenida
            },
            timeout: 10,
            mensaje: "La tarea no quedó detenida"
        )

        let detenida = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(detenida.pasos.count, 2)
        XCTAssertEqual(detenida.pasos[0].estado, .terminado)
        XCTAssertNotNil(detenida.pasos[0].fechaFin)
        XCTAssertNotNil(detenida.pasos[0].costoUSD)
        XCTAssertNotEqual(detenida.pasos[1].estado, .terminado)
        XCTAssertNil(detenida.pasos[1].costoUSD)

        let filaUno = try Self.fila(hilo, paso: 1)
        XCTAssertEqual(filaUno.estado, .completado)
        XCTAssertNotNil(filaUno.duracion)
        XCTAssertNotNil(filaUno.costo)
        XCTAssertNotEqual(try Self.fila(hilo, paso: 2).estado, .completado)
        XCTAssertNil(
            hilo.filas.first { $0.paso == 3 },
            "Detener creó un paso 3 que nunca ocurrió"
        )
        XCTAssertEqual(hilo.cabecera.estado, .detenida)

        // El composer queda disponible y la redireccion no pierde lo preservado.
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(
                id: tarea.id,
                texto: "Mejor hazlo así: usa solo el título del dominio"
            )
        )
        let conRedireccion = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(conRedireccion.turnos.count, 2)
        XCTAssertTrue(conRedireccion.turnos[1].despuesDeEjecutar)
        XCTAssertEqual(conRedireccion.pasos.count, 2)

        hilo.sincronizarDesdeEstado()
        XCTAssertEqual(hilo.filas.count, 2)
        XCTAssertEqual(try Self.fila(hilo, paso: 1).estado, .completado)
    }

    // MARK: - (8) Trazas de la partida B4-COD (bloques de codigo)

    /// Guion literal de B4-COD: los dos prompts del contrato X y las respuestas
    /// REALES archivadas en `humos/b4cod-python.json` y `humos/b4cod-swift.json`
    /// (HTTP 200, modelo combo/deepseek-v4-1-flash). La traza no se escribe a
    /// mano: la produce `EstadoApp.elementosVisiblesDelHilo()`.
    private static let promptPythonB4COD =
        "Escribime una función en Python que sume dos números enteros y "
        + "devuélvela en un bloque de código."
    private static let promptSwiftB4COD =
        "Escribime una función en Swift que sume dos números enteros y "
        + "devuélvela en un bloque de código."

    private static let crudoPythonB4COD = #"""
    def sumar_enteros(a: int, b: int) -> int:
        """Devuelve la suma de dos números enteros."""
        return a + b
    """#
    private static let crudoSwiftB4COD = #"""
    func sumar(_ a: Int, _ b: Int) -> Int {
        return a + b
    }

    // Uso:
    let resultado = sumar(3, 5)   // 8
    """#

    private static let respuestaPythonB4COD = #"""
    ```python
    def sumar_enteros(a: int, b: int) -> int:
        """Devuelve la suma de dos números enteros."""
        return a + b
    ```

    Uso:

    ```python
    print(sumar_enteros(3, 5))  # 8
    ```

    Si querés que valide que los argumentos sean realmente enteros (y no `float` o `bool`), decime y te la ajusto.
    """#

    private static let respuestaSwiftB4COD = #"""
    ```swift
    func sumar(_ a: Int, _ b: Int) -> Int {
        return a + b
    }

    // Uso:
    let resultado = sumar(3, 5)   // 8
    ```

    Si preferís etiquetas en los parámetros, esta variante también es válida:

    ```swift
    func sumar(a: Int, b: Int) -> Int {
        a + b
    }

    let resultado = sumar(a: 3, b: 5)   // 8
    ```

    Nota: en Swift `Int` ya es un entero con signo del tamaño de la arquitectura, y la suma puede desbordarse; si necesitás controlar eso, usá `a.addingReportingOverflow(b)` o `&+` según el caso.
    """#

    func testElGuionB4CODPythonProduceLaTrazaDelBloque() async throws {
        try await ejecutarGuionB4COD(
            prompt: Self.promptPythonB4COD,
            respuesta: Self.respuestaPythonB4COD,
            lenguaje: "python",
            crudoEsperado: Self.crudoPythonB4COD,
            nombreTraza: "ui_transcript_B4-COD-python.txt"
        )
    }

    func testElGuionB4CODSwiftProduceLaTrazaDelBloque() async throws {
        try await ejecutarGuionB4COD(
            prompt: Self.promptSwiftB4COD,
            respuesta: Self.respuestaSwiftB4COD,
            lenguaje: "swift",
            crudoEsperado: Self.crudoSwiftB4COD,
            nombreTraza: "ui_transcript_B4-COD-swift.txt"
        )
    }

    // MARK: - (6) Traza de la partida B4-BUS (busqueda local)

    /// Prompt literal del contrato X de B4-BUS (nivel 2 de la ficha).
    private static let promptB4BUS =
        "Di solo esto: la palabra de prueba de búsqueda es ZAFIRO-4."

    /// Respuesta de respaldo si no esta `NODO_HUMOS_DIR` con el JSON vivo.
    ///
    /// Es el texto archivado en `humos/b4bus-turno1.json`; el test usa el
    /// archivo cuando existe y esta constante cuando CI corre sin humos.
    private static let respuestaB4BUS =
        "la palabra de prueba de búsqueda es ZAFIRO-4."

    /// Traza de la busqueda: una fila con la conversacion sembrada y el estado
    /// vacio de un termino ausente.
    ///
    /// El turno se reproduce con el JSON vivo archivado (o su texto literal en
    /// CI) y deja la conversacion PERSISTIDA con ZAFIRO-4. Despues se busca
    /// sobre el estado real de la app: la proyeccion devuelve exactamente esa
    /// conversacion, el termino ausente devuelve el estado vacio y la busqueda
    /// no genera ninguna peticion de red. La traza NO lleva ids ni UUIDs: la
    /// fila se identifica por titulo y vista previa.
    func testElGuionB4BUSProduceLaTrazaDeBusqueda() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        if let archivo = Self.rutaDelHumo("b4bus-turno1.json") {
            try arnes.transporte.guionarDesdeArchivo(archivo)
        } else {
            arnes.transporte.guionar(
                texto: Self.respuestaB4BUS,
                uso: UsoTokens(entrada: 30, salida: 12)
            )
        }

        arnes.estado.enviar(Self.promptB4BUS)
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)

        // La conversacion quedo persistida con la palabra sembrada.
        arnes.estado.recargarConversaciones()
        XCTAssertEqual(arnes.estado.conversaciones.count, 1)
        let sembrada = try XCTUnwrap(arnes.estado.conversaciones.first)
        XCTAssertTrue(
            sembrada.mensajes.contains { $0.texto.contains("ZAFIRO-4") },
            "El turno vivo deja ZAFIRO-4 en el historial persistido"
        )

        // Buscar: solo lectura y sin red.
        let peticionesAntes = arnes.transporte.cantidadDePeticiones
        let inicio = Date()
        let encontradas = arnes.estado.elementosVisiblesDeBusqueda(
            "ZAFIRO-4",
            segmento: .activos
        )
        let ausente = arnes.estado.elementosVisiblesDeBusqueda(
            "no-existe-9",
            segmento: .activos
        )
        XCTAssertEqual(
            arnes.transporte.cantidadDePeticiones,
            peticionesAntes,
            "Buscar no genera ninguna peticion de red"
        )

        XCTAssertEqual(
            encontradas,
            [
                .resultadoBusqueda(
                    titulo: sembrada.titulo,
                    vistaPrevia: Self.promptB4BUS
                )
            ],
            "Exactamente la conversacion sembrada, con su titulo y su vista previa"
        )
        XCTAssertEqual(ausente, [.sinResultados(termino: "no-existe-9")])

        let ruta = try Self.rutaDeTraza("ui_transcript_B4-BUS.txt")
        var lineas = TrazaVista.lineasBusqueda(
            encontradas,
            t: TrazaVista.tiempo(inicio, desde: inicio)
        )
        lineas += TrazaVista.lineasBusqueda(
            ausente,
            t: TrazaVista.tiempo(Date(), desde: inicio)
        )
        try TrazaVista.escribir(lineas, a: ruta)

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.cuenta(contenido, "SearchResultRow"),
            1,
            "Una fila: la conversacion sembrada"
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "SearchEmptyState"),
            1,
            "Y el estado vacio del termino ausente"
        )
        XCTAssertTrue(
            contenido.contains(
                "SearchResultRow(titulo: \"\(sembrada.titulo)\", "
                    + "vistaPrevia: \"\(Self.promptB4BUS)\")"
            ),
            contenido
        )
        XCTAssertTrue(
            contenido.contains(
                "SearchEmptyState(termino: \"no-existe-9\")"
            ),
            contenido
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            0,
            "La traza de busqueda no lleva lineas de memoria"
        )
        Self.comprobarConteosDeLaPuertaC(contenido)
        Self.publicar(ruta, contenido, en: self)
    }

    // MARK: - (9) Traza de la partida IDEA1 (lectura en voz alta)

    /// Guion literal de IDEA1: prosa, un bloque de codigo y prosa.
    ///
    /// No hay JSON vivo nuevo: la idea es local y su humo es $0,00. El guion es
    /// el mismo que usan los tests de estado de `LecturaEnVozAltaTests`, para
    /// que la traza y la lectura hablen de la MISMA respuesta.
    private static let promptIDEA1 =
        "Explícame qué hace esta función y muéstrame su código."
    private static let prosaIDEA1Antes =
        "La función recibe dos números enteros, los suma y devuelve el resultado."
    private static let prosaIDEA1Despues =
        "El bloque anterior es la implementación completa; el texto que sigue "
        + "es prosa normal."
    private static let codigoIDEA1 =
        "func sumar(_ a: Int, _ b: Int) -> Int { a + b }"

    private static let respuestaIDEA1 = #"""
    La función recibe dos números enteros, los suma y devuelve el resultado.

    ```swift
    func sumar(_ a: Int, _ b: Int) -> Int { a + b }
    ```

    El bloque anterior es la implementación completa; el texto que sigue es prosa normal.
    """#

    /// Traza de IDEA1: la lectura no gana ningun elemento de hilo.
    ///
    /// La proyeccion tiene que quedar en UserBubble + AssistantBubble con 2
    /// TextSegment y 1 CodeBlock (0 MemoryLineNotice). Despues se toca
    /// [Escuchar] sobre la respuesta y se archiva `lectura-IDEA1.txt` junto a
    /// la traza con las locuciones en orden: prosa, anuncio y prosa.
    func testElGuionIDEA1ProduceLaTrazaDeLectura() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: Self.respuestaIDEA1,
            uso: UsoTokens(entrada: 1446, salida: 209)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_IDEA1.txt")
        let sesion = try SesionTraza(ruta: ruta)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        arnes.estado.enviar(Self.promptIDEA1)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"],
            "La lectura no anade ningun elemento al hilo"
        )
        XCTAssertEqual(Self.cuenta(contenido, "TextSegment"), 2)
        XCTAssertEqual(Self.cuenta(contenido, "CodeBlock"), 1)
        XCTAssertTrue(
            contenido.contains(
                "CodeBlock(lenguaje: \"swift\", textoCrudo: "
                    + "\"\(Self.codigoIDEA1)\")"
            ),
            contenido
        )
        XCTAssertEqual(
            Self.cuenta(contenido, "MemoryLineNotice"),
            0,
            "El turno no pide guardar en Memoria"
        )
        XCTAssertTrue(contenido.contains("UserBubble(\"\(Self.promptIDEA1)"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        // [Escuchar] sobre la respuesta: el lector falso recibe las locuciones
        // en orden y el texto hablado no lleva codigo ni cercas.
        let mensaje = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .asistente }
        )
        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)
        XCTAssertEqual(
            arnes.lector.locuciones,
            [
                .texto(Self.prosaIDEA1Antes),
                .anuncioCodigoOmitido,
                .texto(Self.prosaIDEA1Despues)
            ]
        )

        let hablado = LecturaEnVozAlta.textoHablado(
            segmentos: SegmentoRespuesta.segmentos(de: mensaje.texto)
        )
        XCTAssertEqual(
            hablado,
            Self.prosaIDEA1Antes + Self.prosaIDEA1Despues
        )
        XCTAssertFalse(hablado.contains("func sumar"))
        XCTAssertFalse(hablado.contains("```"))

        // Registro de lectura junto a la traza: una linea por locucion.
        let rutaLectura = ruta.deletingLastPathComponent()
            .appendingPathComponent("lectura-IDEA1.txt")
        try TrazaVista.escribir(
            Self.lineasDeLectura(arnes.lector.locuciones),
            a: rutaLectura
        )
        let lectura = try String(contentsOf: rutaLectura, encoding: .utf8)
        XCTAssertTrue(
            lectura.contains(LecturaEnVozAlta.anuncioCodigoOmitido),
            lectura
        )
        XCTAssertFalse(lectura.contains("func sumar"), lectura)
        XCTAssertFalse(lectura.contains("```"), lectura)

        Self.publicar(ruta, contenido, en: self)
    }

    /// Lineas del registro de lectura: una por locucion, en orden.
    ///
    /// El anuncio del codigo va como locucion PROPIA, no dentro del texto
    /// hablado: esa es la invariante que tambien comprueban los tests de
    /// estado.
    private static func lineasDeLectura(
        _ locuciones: [LocucionLectura]
    ) -> [String] {
        locuciones.enumerated().map { indice, locucion in
            let numero = indice + 1
            switch locucion {
            case .texto(let texto):
                return "\(numero). texto: \"\(TrazaVista.escapar(texto))\""
            case .anuncioCodigoOmitido:
                return "\(numero). anuncio: \""
                    + TrazaVista.escapar(LecturaEnVozAlta.anuncioCodigoOmitido)
                    + "\""
            }
        }
    }

    // MARK: - (10) Traza de la partida IDEA3 (compartir)

    /// Guion literal de IDEA3: prosa, un bloque de codigo y prosa.
    ///
    /// No hay JSON vivo nuevo: la idea es local y su humo es $0,00. El guion es
    /// el MISMO que usan los tests de estado de `CompartirTests`, para que la
    /// traza y la exportacion hablen de la MISMA respuesta.
    private static let promptIDEA3 =
        "Escríbeme una función que sume dos enteros, con su explicación."
    private static let prosaIDEA3Antes =
        "La función recibe dos enteros y devuelve su suma."
    private static let prosaIDEA3Despues =
        "Ese es el bloque completo; el resto es prosa."
    private static let codigoIDEA3 =
        "func sumar(_ a: Int, _ b: Int) -> Int { a + b }"

    private static let respuestaIDEA3 = #"""
    La función recibe dos enteros y devuelve su suma.

    ```swift
    func sumar(_ a: Int, _ b: Int) -> Int { a + b }
    ```

    Ese es el bloque completo; el resto es prosa.
    """#

    private static let patronUUIDIDEA3 =
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    /// Traza de IDEA3: compartir la respuesta y el hilo no gana ningun elemento.
    ///
    /// La proyeccion queda en UserBubble + AssistantBubble con 2 TextSegment y
    /// 1 CodeBlock (0 MemoryLineNotice). Despues se comparten la respuesta y el
    /// hilo y se vuelve a capturar la proyeccion: el archivo no cambia ni un
    /// byte. El texto exportado queda junto a la traza como evidencia, SIN
    /// bloque `TRAZA` (el extractor solo acepta ui_transcript_<ID>.txt).
    func testElGuionIDEA3ProduceLaTrazaDeCompartir() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: Self.respuestaIDEA3,
            uso: UsoTokens(entrada: 1446, salida: 209)
        )

        let ruta = try Self.rutaDeTraza("ui_transcript_IDEA3.txt")
        let sesion = try SesionTraza(ruta: ruta)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        arnes.estado.enviar(Self.promptIDEA3)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"],
            "Compartir no anade ningun elemento al hilo"
        )
        XCTAssertEqual(Self.cuenta(contenido, "TextSegment"), 2)
        XCTAssertEqual(Self.cuenta(contenido, "CodeBlock"), 1)
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)
        XCTAssertTrue(contenido.contains("UserBubble(\"\(Self.promptIDEA3)"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        // Compartir la respuesta y el hilo: el texto sale de la proyeccion y
        // queda en la misma variable que observa la hoja del sistema.
        let respuesta = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .asistente }
        )
        let textoRespuesta = try XCTUnwrap(
            arnes.estado.textoDeRespuestaParaCompartir(respuesta)
        )
        let textoHilo = arnes.estado.markdownDelHilo()

        arnes.estado.compartirRespuesta(de: respuesta)
        XCTAssertEqual(arnes.estado.textoParaCompartirSolicitado, textoRespuesta)
        arnes.estado.textoParaCompartirSolicitado = nil
        arnes.estado.compartirHilo()
        XCTAssertEqual(arnes.estado.textoParaCompartirSolicitado, textoHilo)

        // Compartir es solo lectura: re-capturar la proyeccion deja el archivo
        // de traza intacto.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        XCTAssertEqual(
            try String(contentsOf: ruta, encoding: .utf8),
            contenido,
            "La exportacion no anadio ningun elemento al hilo"
        )

        XCTAssertFalse(textoRespuesta.contains("```"))
        XCTAssertNil(
            textoRespuesta.range(
                of: Self.patronUUIDIDEA3,
                options: .regularExpression
            )
        )
        XCTAssertNil(
            textoHilo.range(
                of: Self.patronUUIDIDEA3,
                options: .regularExpression
            )
        )

        // Chat Temporal: la accion no existe (puerta unica que consulta la
        // vista) y la exportacion no pide nada.
        arnes.estado.nuevaConversacionTemporal()
        XCTAssertFalse(
            arnes.estado.puedeCompartir,
            "En un Chat Temporal no existe forma de exportar"
        )
        arnes.estado.compartirHilo()
        XCTAssertNil(arnes.estado.textoParaCompartirSolicitado)

        // Evidencia del texto exportado junto a la traza, sin bloque TRAZA:
        // el extractor rechaza un nombre que no sea ui_transcript_<ID>.txt.
        let rutaTexto = ruta.deletingLastPathComponent()
            .appendingPathComponent("compartir-IDEA3.txt")
        try TrazaVista.escribir(
            Self.lineasDeTextosCompartidos(
                respuesta: textoRespuesta,
                hilo: textoHilo
            ),
            a: rutaTexto
        )

        Self.publicar(ruta, contenido, en: self)
    }

    /// Texto exportado en claro, para evidencia junto a la traza.
    private static func lineasDeTextosCompartidos(
        respuesta: String,
        hilo: String
    ) -> [String] {
        var lineas = ["== RESPUESTA COMPARTIDA =="]
        lineas.append(
            contentsOf: respuesta.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
        )
        lineas.append("")
        lineas.append("== HILO COMPARTIDO ==")
        lineas.append(
            contentsOf: hilo.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
        )
        return lineas
    }

    /// Un turno de B4-COD: prompt literal, respuesta viva guionizada y traza.
    ///
    /// La proyeccion tiene que entregar DOS bloques independientes con su
    /// lenguaje y su crudo exacto, y la traza solo etiquetas del catalogo.
    private func ejecutarGuionB4COD(
        prompt: String,
        respuesta: String,
        lenguaje: String,
        crudoEsperado: String,
        nombreTraza: String
    ) async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: respuesta,
            uso: UsoTokens(entrada: 1446, salida: 209)
        )

        let ruta = try Self.rutaDeTraza(nombreTraza)
        let sesion = try SesionTraza(ruta: ruta)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())
        arnes.estado.enviar(prompt)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo())

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(elementos.count, 2)
        guard case .burbujaUsuario(let promptVisible) = elementos[0],
              case .burbujaAsistente(let segmentos) = elementos[1] else {
            return XCTFail("La proyeccion no trae las dos burbujas del turno")
        }
        XCTAssertEqual(promptVisible, prompt)

        let bloques = segmentos.filter { segmento in
            if case .codigo = segmento { return true }
            return false
        }
        XCTAssertEqual(bloques.count, 2, "El guion vivo trae dos bloques")
        guard case .codigo(let lenguajeVisible, let crudo) = segmentos[0] else {
            return XCTFail("El primer segmento tiene que ser el bloque")
        }
        XCTAssertEqual(lenguajeVisible, lenguaje)
        XCTAssertEqual(
            crudo,
            crudoEsperado,
            "El crudo es identico al codigo sin cercas, caracter por caracter"
        )
        XCTAssertFalse(crudo.contains("```"))

        let contenido = sesion.contenido
        XCTAssertEqual(
            Self.cuenta(contenido, "CodeBlock(lenguaje: \"\(lenguaje)\""),
            2,
            "Cada bloque de la respuesta deja su CodeBlock en la traza"
        )
        XCTAssertEqual(Self.cuenta(contenido, "TextSegment"), 2)
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)
        XCTAssertTrue(contenido.contains("UserBubble(\"\(prompt)"))

        Self.comprobarConteosDeLaPuertaC(contenido)
        Self.publicar(ruta, contenido, en: self)
    }

    /// Fila viva del paso K, sin indice que pueda salirse del arreglo.
    private static func fila(
        _ hilo: HiloTareaViewModel,
        paso: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HiloTareaViewModel.FilaViva {
        try XCTUnwrap(
            hilo.filas.first { $0.paso == paso },
            "No hay fila para el paso \(paso)",
            file: file,
            line: line
        )
    }

    /// Transiciones `(paso, estado)` en el orden en que se emitieron.
    private static func transicionesDePaso(
        _ traza: [String]
    ) -> [(Int, String)] {
        var salida: [(Int, String)] = []
        for linea in traza where linea.contains("] StepRow(paso: ") {
            guard let rangoPaso = linea.range(of: "StepRow(paso: ") else {
                continue
            }
            let resto = linea[rangoPaso.upperBound...]
            guard let coma = resto.firstIndex(of: ","),
                  let paso = Int(resto[..<coma])
            else { continue }
            guard let rangoEstado = linea.range(of: "estado: \"") else {
                continue
            }
            let trasEstado = linea[rangoEstado.upperBound...]
            guard let cierre = trasEstado.firstIndex(of: "\"") else { continue }
            salida.append((paso, String(trasEstado[..<cierre])))
        }
        return salida
    }

    /// Tiempos `t` de la traza, en orden.
    private static func tiemposDeTraza(_ traza: [String]) -> [TimeInterval] {
        traza.compactMap { linea in
            guard let rango = linea.range(of: "[t=") else { return nil }
            let resto = linea[rango.upperBound...]
            guard let fin = resto.range(of: "s]") else { return nil }
            return TimeInterval(resto[..<fin.lowerBound])
        }
    }

    /// Etiquetas del catalogo cerrado (14), para el test negativo de B3-B.
    private static let etiquetasValidas: Set<String> = [
        "UserBubble", "AssistantBubble", "TextSegment", "CodeBlock",
        "MemoryLineNotice", "Divider", "StreamingBubble", "ErrorBubble",
        "MemoryApprovalSheet", "TaskHeader", "PlanCard", "StepRow",
        "SearchResultRow", "SearchEmptyState"
    ]

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

    // MARK: - (11) Traza de la partida IDEA4 (tope mensual de gasto)

    /// Guion literal de IDEA4: un turno normal y sellos ya acumulados.
    ///
    /// No hay JSON vivo nuevo: la idea es local y su humo es $0,00. El turno
    /// se reproduce con el transporte guionizado y los sellos se siembran en
    /// el libro del estado, sin llamar a InferHub.
    private static let promptIDEA4 =
        "Explícame en una frase qué es un sello de costo."
    private static let respuestaIDEA4 =
        "Un sello de costo es el importe que quedó cerrado en el mensaje "
        + "cuando se recibió la respuesta."

    /// Traza de IDEA4: la banda del tope vive FUERA del hilo.
    ///
    /// El hilo queda en UserBubble + AssistantBubble (0 elementos de banda).
    /// Después se cruzan el 80 % y el 100 % con sellos ya existentes y se
    /// vuelve a capturar: el archivo no cambia ni un byte. La evidencia de la
    /// banda y del composer operativo queda en `gasto-IDEA4.txt`, SIN bloque
    /// `TRAZA` (el extractor solo acepta ui_transcript_<ID>.txt).
    func testElGuionIDEA4ProduceLaTrazaDelTopeMensual() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.fijarTopeMensual(10.00)

        // Reloj fijo: la traza es determinista para la réplica en Python.
        let inicio = Date(timeIntervalSince1970: 1_000)
        let ahora = Date()
        arnes.estado.config.usoApp.registrar(
            uso: UsoTokens(entrada: 1_000, salida: 500),
            usd: 7.00,
            fecha: ahora,
            modelo: arnes.proveedor.modelo,
            conPrecio: true
        )

        arnes.transporte.guionar(texto: Self.respuestaIDEA4)
        let ruta = try Self.rutaDeTraza("ui_transcript_IDEA4.txt")
        let sesion = try SesionTraza(ruta: ruta, inicio: inicio)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        arnes.estado.enviar(Self.promptIDEA4)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"],
            "La banda no es un elemento del hilo"
        )
        XCTAssertEqual(Self.cuenta(contenido, "TextSegment"), 1)
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)
        XCTAssertTrue(contenido.contains("UserBubble(\"\(Self.promptIDEA4)"))
        Self.comprobarConteosDeLaPuertaC(contenido)

        // 70 %: todavía no hay banda.
        let inicial = arnes.estado.estadoTopeMensual(ahora: ahora)
        XCTAssertEqual(inicial.estado, .bajoUmbral)
        XCTAssertFalse(inicial.visible)

        // Cruzar el 80 % con sellos ya acumulados (sin InferHub).
        arnes.estado.config.usoApp.registrar(
            uso: UsoTokens(entrada: 100, salida: 50),
            usd: 1.00,
            fecha: ahora,
            modelo: arnes.proveedor.modelo,
            conPrecio: true
        )
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        let alOchenta = arnes.estado.estadoTopeMensual(ahora: ahora)
        XCTAssertEqual(alOchenta.estado, .aviso)
        XCTAssertTrue(alOchenta.visible)
        XCTAssertEqual(
            try String(contentsOf: ruta, encoding: .utf8),
            contenido,
            "La banda vive fuera del hilo: el archivo no gana elementos"
        )

        // Cruzar el 100 %.
        arnes.estado.config.usoApp.registrar(
            uso: UsoTokens(entrada: 100, salida: 50),
            usd: 2.00,
            fecha: ahora,
            modelo: arnes.proveedor.modelo,
            conPrecio: true
        )
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        let alCien = arnes.estado.estadoTopeMensual(ahora: ahora)
        XCTAssertEqual(alCien.estado, .alcanzado)
        XCTAssertEqual(
            try String(contentsOf: ruta, encoding: .utf8),
            contenido,
            "El tope alcanzado tampoco entra al hilo"
        )

        // Composer operativo con la banda visible: el segundo envío se acepta
        // y la respuesta se cierra. Nada se cancela solo.
        arnes.transporte.guionar(texto: "Sigo.")
        arnes.estado.enviar("Sigo con el tope alcanzado")
        try await arnes.esperarTurno()
        XCTAssertFalse(arnes.estado.enviando)
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.filter { $0.rol == .asistente }
                .count,
            2
        )

        // Evidencia de la banda y del composer junto a la traza, sin bloque
        // TRAZA: el extractor rechaza un nombre que no sea ui_transcript_<ID>.
        let rutaGasto = ruta.deletingLastPathComponent()
            .appendingPathComponent("gasto-IDEA4.txt")
        try TrazaVista.escribir(
            Self.lineasDelTopeMensual(
                inicial: inicial,
                alOchenta: alOchenta,
                alCien: alCien
            ),
            a: rutaGasto
        )

        Self.publicar(ruta, contenido, en: self)
    }

    /// Lineas de evidencia de la banda: una por umbral, con el composer.
    private static func lineasDelTopeMensual(
        inicial: TopeMensualGasto,
        alOchenta: TopeMensualGasto,
        alCien: TopeMensualGasto
    ) -> [String] {
        func dinero(_ valor: Double) -> String {
            "$" + String(format: "%.4f", valor)
        }
        return [
            "== TOPE MENSUAL (IDEA4) ==",
            "tope guardado: $10.00",
            "nota: \(TopeMensualGasto.nota)",
            "acumulado inicial: \(dinero(inicial.acumulado)) "
                + "(\(inicial.porcentajeEntero) %)",
            "banda inicial: \(inicial.estado.rawValue)",
            "acumulado al cruzar 80 %: \(dinero(alOchenta.acumulado)) "
                + "(\(alOchenta.porcentajeEntero) %)",
            "banda al 80 %: \(alOchenta.estado.rawValue)",
            "acumulado al cruzar 100 %: \(dinero(alCien.acumulado)) "
                + "(\(alCien.porcentajeEntero) %)",
            "banda al 100 %: \(alCien.estado.rawValue)",
            "hilo: 2 elementos (UserBubble + AssistantBubble); "
                + "0 elementos de banda",
            "composer: operativo (segundo envío aceptado con la banda visible)"
        ]
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

    // MARK: - (12) Traza de la partida IDEA5 (estadisticas locales)

    /// Guion literal de IDEA5: un turno normal y sellos ya existentes.
    ///
    /// No hay llamada nueva a InferHub: el turno se reproduce con el transporte
    /// guionizado y los sellos se siembran en conversaciones persistidas. El
    /// Chat Temporal tambien se siembra y NO puede aparecer en el desglose.
    private static let promptIDEA5 =
        "¿Cuánto llevo gastado en este dispositivo?"
    private static let respuestaIDEA5 =
        "Tu gasto sellado local está en Mi Contexto, sección Gasto."

    /// Fecha fija a mitad de mes: los tres tramos son estables en cualquier
    /// zona horaria (dia 15/16).
    private static let ahoraIDEA5 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Traza de IDEA5: la agregacion vive FUERA del hilo.
    ///
    /// El hilo queda en UserBubble + AssistantBubble. Abrir Gasto no anade ni
    /// un elemento: se vuelve a capturar y el archivo no cambia ni un byte. La
    /// evidencia de los agregados (Hoy / Este mes / Total historico con su
    /// reparto por modelo) queda en `gasto-IDEA5.txt`, SIN bloque `TRAZA` (el
    /// extractor solo acepta ui_transcript_<ID>.txt).
    func testElGuionIDEA5ProduceLaTrazaDeEstadisticas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // Dos modelos con sellos propios: el reparto por modelo es el del guion.
        var config = arnes.estado.config
        config.proveedores[0].modelo = "inferhub/modelo-alfa"
        let proveedorA = config.proveedores[0]
        let proveedorB = ProviderConfig(
            nombre: "Proveedor B",
            baseURL: "https://api.b.test/v1",
            modelo: "inferhub/modelo-beta"
        )
        config.proveedores.append(proveedorB)
        arnes.estado.config = config

        arnes.transporte.guionar(
            texto: Self.respuestaIDEA5,
            uso: UsoTokens(entrada: 40, salida: 12)
        )
        let inicio = Date(timeIntervalSince1970: 1_000)
        let ruta = try Self.rutaDeTraza("ui_transcript_IDEA5.txt")
        let sesion = try SesionTraza(ruta: ruta, inicio: inicio)

        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        arnes.estado.enviar(Self.promptIDEA5)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)

        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble"],
            "La agregacion no es un elemento del hilo"
        )
        XCTAssertEqual(Self.cuenta(contenido, "TextSegment"), 1)
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)
        Self.comprobarConteosDeLaPuertaC(contenido)

        // La agregacion se calcula al PRESENTAR la vista, sobre sellos ya
        // existentes: el transporte no recibe ninguna llamada mas.
        let sembradas = Self.conversacionesIDEA5(a: proveedorA, b: proveedorB)
        let estadisticas = arnes.estado.estadisticasDeGasto(
            en: sembradas,
            ahora: Self.ahoraIDEA5
        )
        XCTAssertEqual(estadisticas.hoy.mensajes, 3)
        XCTAssertEqual(estadisticas.hoy.usd, 2.25, accuracy: 1e-9)
        XCTAssertEqual(estadisticas.mes.mensajes, 5)
        XCTAssertEqual(estadisticas.mes.usd, 5.00, accuracy: 1e-9)
        XCTAssertEqual(estadisticas.total.mensajes, 6)
        XCTAssertEqual(estadisticas.total.usd, 8.00, accuracy: 1e-9)
        XCTAssertEqual(
            estadisticas.total.modelos.map(\.nombre),
            ["modelo-alfa", "modelo-beta"]
        )
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)

        // Abrir Gasto no toca el hilo: capturar otra vez deja el archivo igual.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        XCTAssertEqual(
            try String(contentsOf: ruta, encoding: .utf8),
            contenido,
            "La agregacion vive fuera del hilo: el archivo no gana elementos"
        )

        // Evidencia de los agregados junto a la traza, sin bloque TRAZA.
        let rutaGasto = ruta.deletingLastPathComponent()
            .appendingPathComponent("gasto-IDEA5.txt")
        try TrazaVista.escribir(
            Self.lineasDeEstadisticas(estadisticas),
            a: rutaGasto
        )

        Self.publicar(ruta, contenido, en: self)
    }

    /// Conversaciones sembradas del guion IDEA5: dos normales y una temporal.
    ///
    /// El mismo guion que reproduce `humos/replica_idea5.py`. Los sellos son
    /// fijos, asi que los tres tramos y el reparto por modelo son deterministas.
    private static func conversacionesIDEA5(
        a: ProviderConfig,
        b: ProviderConfig
    ) -> [Conversation] {
        let calendario = Calendar(identifier: .gregorian)
        let otroDia = calendario.date(
            byAdding: .day,
            value: -1,
            to: ahoraIDEA5
        ) ?? ahoraIDEA5
        let mesAnterior = calendario.date(
            byAdding: .month,
            value: -1,
            to: ahoraIDEA5
        ) ?? ahoraIDEA5

        func sellado(
            _ fecha: Date,
            _ proveedorID: UUID?,
            _ usd: Double
        ) -> ChatMessage {
            ChatMessage(
                rol: .asistente,
                texto: "Respuesta sellada.",
                fecha: fecha,
                tokensEntrada: 1_000,
                tokensSalida: 500,
                proveedorID: proveedorID,
                costoSelladoUSD: usd
            )
        }

        let normal1 = Conversation(
            titulo: "Normal 1",
            mensajes: [
                sellado(ahoraIDEA5, a.id, 1.50),
                sellado(ahoraIDEA5, b.id, 0.50),
                sellado(otroDia, a.id, 2.00),
                sellado(mesAnterior, a.id, 3.00)
            ],
            proveedorID: a.id
        )
        // El ultimo mensaje no trae proveedor propio: hereda el del chat.
        let normal2 = Conversation(
            titulo: "Normal 2",
            mensajes: [
                sellado(ahoraIDEA5, nil, 0.25),
                sellado(otroDia, b.id, 0.75)
            ],
            proveedorID: b.id
        )
        // Chat Temporal: su sello NO puede entrar en ningun tramo.
        let temporal = Conversation(
            titulo: "Temporal",
            mensajes: [sellado(ahoraIDEA5, a.id, 99.00)],
            proveedorID: a.id,
            esTemporal: true
        )
        return [normal1, normal2, temporal]
    }

    /// Lineas de evidencia de los agregados, identicas a la replica en Python.
    private static func lineasDeEstadisticas(
        _ estadisticas: EstadisticasGasto
    ) -> [String] {
        func dinero(_ valor: Double) -> String {
            "$" + String(format: "%.4f", valor)
        }
        func mensajes(_ cuenta: Int) -> String {
            "\(cuenta) " + (cuenta == 1 ? "mensaje" : "mensajes")
        }
        func tramo(_ etiqueta: String, _ valor: TramoEstadistica) -> [String] {
            var salida = [
                "\(etiqueta): \(mensajes(valor.mensajes)) | "
                    + "total \(dinero(valor.usd))"
            ]
            if valor.modelos.isEmpty {
                salida.append("  (sin sellos)")
            } else {
                for fila in valor.modelos {
                    salida.append(
                        "  \(fila.nombre): \(mensajes(fila.mensajes)) | "
                            + "\(dinero(fila.usd))"
                    )
                }
            }
            return salida
        }
        var lineas = [
            "== GASTO SELLADO LOCAL (IDEA5) ==",
            "rotulo: \(EstadisticasGasto.rotulo)"
        ]
        lineas += tramo("hoy", estadisticas.hoy)
        lineas += tramo("mes", estadisticas.mes)
        lineas += tramo("total", estadisticas.total)
        lineas.append("temporal: hilo temporal excluido del desglose")
        return lineas
    }

    // MARK: - (13) Traza de la partida IDEA6 (borrador por hilo)

    /// Guion literal de IDEA6: un turno normal, un borrador que se sale y se
    /// reabre, y un envio sin red.
    ///
    /// No hay llamada nueva a InferHub: el turno se reproduce con el
    /// transporte guionizado y el fallo de red tambien es guionizado. El humo
    /// es $0,00.
    private static let promptIDEA6 = "Hola, ¿me ayudas con una idea?"
    private static let respuestaIDEA6 =
        "Claro: dime la idea y la aterrizamos."
    private static let borradorIDEA6 =
        "Esto se queda en el composer sin enviar"
    private static let errorIDEA6 = "Sin conexión a internet."

    /// Traza de IDEA6: el borrador vive FUERA del hilo.
    ///
    /// Escribir, salir y reabrir el hilo no anade ni un elemento: el archivo
    /// no cambia ni un byte (esa es la evidencia de los 0 elementos nuevos).
    /// El envio sin red si deja lo que el catalogo ya tiene: el `UserBubble`
    /// del mensaje y el `ErrorBubble` del turno fallido. Ninguna burbuja
    /// «pendiente»: 0 casos nuevos en `ElementoHiloVisible`.
    ///
    /// La evidencia del borrador (texto restaurado y texto intacto tras el
    /// fallo) queda en `borrador-IDEA6.txt`, SIN bloque `TRAZA` (el extractor
    /// solo acepta ui_transcript_<ID>.txt).
    func testElGuionIDEA6ProduceLaTrazaDelBorrador() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: Self.respuestaIDEA6,
            uso: UsoTokens(entrada: 24, salida: 9)
        )
        let inicio = Date(timeIntervalSince1970: 1_000)
        let ruta = try Self.rutaDeTraza("ui_transcript_IDEA6.txt")
        let sesion = try SesionTraza(ruta: ruta, inicio: inicio)

        // Turno normal: UserBubble + AssistantBubble.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        arnes.estado.enviar(Self.promptIDEA6)
        try await arnes.esperarTurno()
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)

        let contenidoTrasTurno = try String(contentsOf: ruta, encoding: .utf8)

        // Borrador: se escribe, se sale del hilo y se reabre.
        let hilo = arnes.estado.conversacion
        arnes.estado.borrador = Self.borradorIDEA6
        arnes.estado.nuevaConversacion()
        arnes.estado.abrir(hilo)
        XCTAssertEqual(
            arnes.estado.borrador,
            Self.borradorIDEA6,
            "El borrador vuelve integro al reabrir el hilo"
        )

        // La operacion de borrador no toca el hilo: ni un elemento nuevo.
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)
        XCTAssertEqual(
            try String(contentsOf: ruta, encoding: .utf8),
            contenidoTrasTurno,
            "El borrador no es un elemento del hilo (0 nuevos)"
        )

        // Envio sin red: ErrorBubble existente y texto intacto.
        arnes.transporte.fallarProximoStream()
        arnes.estado.enviarTextoActual()
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.estado.errorDeTurno, Self.errorIDEA6)
        XCTAssertEqual(arnes.estado.borrador, Self.borradorIDEA6)
        XCTAssertEqual(
            arnes.estado.borradorGuardado(para: hilo.id),
            Self.borradorIDEA6
        )
        try sesion.capturar(arnes.estado.elementosVisiblesDelHilo(), en: inicio)

        let contenido = try String(contentsOf: ruta, encoding: .utf8)
        XCTAssertEqual(
            Self.etiquetasSuperiores(contenido),
            ["UserBubble", "AssistantBubble", "UserBubble", "ErrorBubble"],
            "El fallo de red deja el ErrorBubble existente, no una pendiente"
        )
        XCTAssertEqual(Self.cuenta(contenido, "TextSegment"), 1)
        XCTAssertEqual(Self.cuenta(contenido, "MemoryLineNotice"), 0)
        Self.comprobarConteosDeLaPuertaC(contenido)

        // Evidencia del borrador junto a la traza, sin bloque TRAZA.
        let rutaBorrador = ruta.deletingLastPathComponent()
            .appendingPathComponent("borrador-IDEA6.txt")
        try TrazaVista.escribir(Self.lineasDelBorrador(), a: rutaBorrador)

        Self.publicar(ruta, contenido, en: self)
    }

    /// Lineas de evidencia del borrador, identicas a la replica en Python.
    private static func lineasDelBorrador() -> [String] {
        [
            "== BORRADOR POR HILO (IDEA6) ==",
            "hilo: \(borradorIDEA6)",
            "al reabrir: texto restaurado integro",
            "envio sin red: ErrorBubble visible y texto intacto",
            "elementos nuevos en el hilo por el borrador: 0"
        ]
    }
}
