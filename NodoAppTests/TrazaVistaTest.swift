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

    /// Primera llamada de `humos/mem-humo-1.json` (v0.3.1). El archivo trae dos
    /// llamadas; el contrato de P0.2 exige UN artefacto de memoria por turno,
    /// asi que el fixture inyecta la primera y deja constancia. La segunda es
    /// `call_01_YbcqWVGKwT9QMSax5B2j5076` / «Prefiere respuestas cortas».
    private static let llamadaMemoriaArchivada = ToolCall(
        id: "call_00_WVjAe73tY4ubrvEhwMnB9307",
        nombre: Memoria.nombreHerramientaChat,
        argumentos: #"{"accion": "guardar", "texto": "Palabra clave de la barbería: LUNA-7"}"#
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

        // Turno 1: orden explicita de guardado. El modelo pide memoria_chat y
        // despues confirma sin repetir el id interno.
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b11-memoria",
                    nombre: Memoria.nombreHerramientaChat,
                    argumentos: #"{"accion":"guardar","texto":"Palabra clave personal de ejemplo: LUNA-7"}"#
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
                    nombre: Memoria.nombreHerramientaChat,
                    argumentos: #"{"accion":"guardar","texto":"Palabra clave personal de ejemplo: LUNA-7"}"#
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
                    nombre: Memoria.nombreHerramientaChat,
                    argumentos: #"{"accion":"actualizar","id":"\#(idEntrada.uuidString)","texto":"Palabra clave personal de ejemplo: LUNA-9"}"#
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
                    nombre: Memoria.nombreHerramientaChat,
                    argumentos: #"{"accion": "guardar", "texto": "Mi color favorito es el verde."}"#
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
