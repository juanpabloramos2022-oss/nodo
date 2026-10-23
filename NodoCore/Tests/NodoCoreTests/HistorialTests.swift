import XCTest

@testable import NodoCore

final class ConversationSinMemoriaTests: XCTestCase {
    func testUnJSONViejoSinElCampoDecodificaSinMemoriaFalse() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "titulo": "Vieja",
          "mensajes": [],
          "creada": 0.0,
          "actualizada": 0.0
        }
        """

        let conversacion = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))

        XCTAssertFalse(conversacion.sinMemoria)
        XCTAssertFalse(conversacion.modoTarea)
    }

    func testLosFlagsSobrevivenAlJSON() throws {
        let original = Conversation(
            titulo: "Nueva",
            sinMemoria: true,
            modoTarea: true
        )

        let vuelta = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertTrue(vuelta.sinMemoria)
        XCTAssertTrue(vuelta.modoTarea)
    }
}

final class HistorialTests: XCTestCase {
    private func conversacion(
        sinMemoria: Bool = false,
        mensajes: [ChatMessage] = [
            ChatMessage(rol: .usuario, texto: "hola"),
            ChatMessage(rol: .asistente, texto: "que tal")
        ]
    ) -> Conversation {
        Conversation(titulo: "Chat", mensajes: mensajes, sinMemoria: sinMemoria)
    }

    func testChatNormalIncluyeElPromptDeSistemaPrimero() {
        let historial = Historial.paraEnviar(
            conversacion: conversacion(),
            promptSistema: "Memoria curada"
        )

        XCTAssertEqual(historial.count, 3)
        XCTAssertEqual(historial.first?.rol, .sistema)
        XCTAssertEqual(historial.first?.texto, "Memoria curada")
    }

    func testChatSinMemoriaNoIncluyeElPrompt() {
        let historial = Historial.paraEnviar(
            conversacion: conversacion(sinMemoria: true),
            promptSistema: "Memoria curada"
        )

        XCTAssertEqual(historial.count, 2)
        XCTAssertFalse(historial.contains { $0.rol == .sistema })
        XCTAssertFalse(historial.contains { $0.texto == "Memoria curada" })
    }

    func testUnPromptVacioNoSeIncluyeNunca() {
        let normal = Historial.paraEnviar(
            conversacion: conversacion(),
            promptSistema: "   \n  "
        )
        let sinMemoria = Historial.paraEnviar(
            conversacion: conversacion(sinMemoria: true),
            promptSistema: ""
        )

        XCTAssertEqual(normal.count, 2)
        XCTAssertEqual(sinMemoria.count, 2)
        XCTAssertFalse(normal.contains { $0.rol == .sistema })
        XCTAssertFalse(sinMemoria.contains { $0.rol == .sistema })
    }

    func testLosMensajesVanCompletosYEnOrden() {
        let mensajes = [
            ChatMessage(rol: .usuario, texto: "uno"),
            ChatMessage(rol: .asistente, texto: "dos", tokensEntrada: 10, tokensSalida: 5),
            ChatMessage(rol: .herramienta, texto: "tres", toolCallId: "llamada-1"),
            ChatMessage(rol: .asistente, texto: "cuatro")
        ]

        let historial = Historial.paraEnviar(
            conversacion: conversacion(mensajes: mensajes),
            promptSistema: "sistema"
        )

        XCTAssertEqual(historial.count, mensajes.count + 1)
        XCTAssertEqual(Array(historial.dropFirst()), mensajes)
    }

    func testElPromptSeRecortaAntesDeEnviarse() {
        let historial = Historial.paraEnviar(
            conversacion: conversacion(),
            promptSistema: "  Memoria curada  "
        )

        XCTAssertEqual(historial.first?.texto, "Memoria curada")
    }
}
