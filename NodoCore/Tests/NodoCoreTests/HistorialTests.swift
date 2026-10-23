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
        XCTAssertFalse(conversacion.topeIgnorado)
        XCTAssertNil(conversacion.resumenCompactado)
        XCTAssertNil(conversacion.usoTrasCompactar)
    }

    func testLosCamposDeCompactacionSobrevivenAlJSON() throws {
        let original = Conversation(
            titulo: "Compactada",
            topeIgnorado: true,
            resumenCompactado: "Resumen guardado",
            usoTrasCompactar: UsoTokens(entrada: 30, salida: 12)
        )

        let vuelta = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertTrue(vuelta.topeIgnorado)
        XCTAssertEqual(vuelta.resumenCompactado, "Resumen guardado")
        XCTAssertEqual(vuelta.usoTrasCompactar, UsoTokens(entrada: 30, salida: 12))
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
        resumenCompactado: String? = nil,
        mensajes: [ChatMessage] = [
            ChatMessage(rol: .usuario, texto: "hola"),
            ChatMessage(rol: .asistente, texto: "que tal")
        ]
    ) -> Conversation {
        Conversation(
            titulo: "Chat",
            mensajes: mensajes,
            sinMemoria: sinMemoria,
            resumenCompactado: resumenCompactado
        )
    }

    private func entradas(_ textos: String...) -> [EntradaMemoria] {
        textos.map { EntradaMemoria(texto: $0) }
    }

    func testChatNormalIncluyeElBloqueDeMemoriaPrimero() {
        let memoria = entradas("Memoria curada")
        let historial = Historial.paraEnviar(
            conversacion: conversacion(),
            memoria: memoria
        )

        XCTAssertEqual(historial.count, 3)
        XCTAssertEqual(historial.first?.rol, .sistema)
        XCTAssertEqual(
            historial.first?.texto,
            Memoria.bloqueSistema(entradas: memoria)
        )
    }

    func testChatSinMemoriaNoIncluyeElBloque() {
        let historial = Historial.paraEnviar(
            conversacion: conversacion(sinMemoria: true),
            memoria: entradas("Memoria curada")
        )

        XCTAssertEqual(historial.count, 2)
        XCTAssertFalse(historial.contains { $0.rol == .sistema })
        XCTAssertFalse(historial.contains { $0.texto.contains("Memoria curada") })
    }

    func testUnaMemoriaVaciaSigueTeniendoBloqueDeCapacidad() {
        let normal = Historial.paraEnviar(
            conversacion: conversacion(),
            memoria: []
        )
        let sinMemoria = Historial.paraEnviar(
            conversacion: conversacion(sinMemoria: true),
            memoria: []
        )

        // En un chat con Memoria el bloque viaja aunque no haya entradas: es lo
        // que declara la capacidad de guardar la primera. En uno sin Memoria no
        // viaja nada.
        XCTAssertEqual(normal.count, 3)
        XCTAssertEqual(normal.first?.rol, .sistema)
        XCTAssertTrue(normal.first?.texto.contains(Memoria.cabeceraBloque) == true)
        XCTAssertTrue(normal.first?.texto.contains("ninguna") == true)
        XCTAssertEqual(sinMemoria.count, 2)
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
            memoria: entradas("sistema")
        )

        XCTAssertEqual(historial.count, mensajes.count + 1)
        XCTAssertEqual(Array(historial.dropFirst()), mensajes)
    }

    func testElBloqueListaTodasLasEntradasConSusIds() {
        let memoria = entradas("primera", "segunda")
        let historial = Historial.paraEnviar(
            conversacion: conversacion(),
            memoria: memoria
        )

        let bloque = historial.first?.texto ?? ""
        for entrada in memoria {
            XCTAssertTrue(bloque.contains(entrada.texto))
            XCTAssertTrue(bloque.contains(entrada.id.uuidString))
        }
    }

    func testElResumenVaComoUnSoloMensajeDeSistemaTrasElBloqueDeMemoria() {
        let chat = conversacion(resumenCompactado: "Resumen del chat\ncon dos lineas")
        let memoria = entradas("Memoria curada")

        let historial = Historial.paraEnviar(
            conversacion: chat,
            memoria: memoria
        )

        XCTAssertEqual(historial.count, chat.mensajes.count + 2)
        XCTAssertEqual(historial[0].rol, .sistema)
        XCTAssertEqual(
            historial[0].texto,
            Memoria.bloqueSistema(entradas: memoria)
        )
        XCTAssertEqual(historial[1].rol, .sistema)
        XCTAssertEqual(
            historial[1].texto,
            Historial.cabeceraResumen + "\nResumen del chat\ncon dos lineas"
        )
        XCTAssertEqual(Array(historial.dropFirst(2)), chat.mensajes)
    }

    func testElResumenNoSeInyectaEnUnChatSinMemoria() {
        let chat = conversacion(
            sinMemoria: true,
            resumenCompactado: "Resumen guardado"
        )

        let historial = Historial.paraEnviar(
            conversacion: chat,
            memoria: entradas("Memoria curada")
        )

        XCTAssertEqual(historial, chat.mensajes)
        XCTAssertFalse(historial.contains { $0.texto == "Resumen guardado" })
        XCTAssertFalse(historial.contains { $0.rol == .sistema })
    }

    func testChatSinMemoriaInyectaElResumenGuardado() {
        // COMP.2: el chat sin memoria no recibe la Memoria, pero si el
        // respaldo persistido de la ultima compactacion. Sin esto, /compact
        // resume y poda para siempre.
        let chat = conversacion(sinMemoria: true)

        let historial = Historial.paraEnviar(
            conversacion: chat,
            memoria: entradas("Memoria curada"),
            resumenGuardado: "EL DATO CLAVE ES 42"
        )

        XCTAssertEqual(historial.count, chat.mensajes.count + 1)
        XCTAssertEqual(historial.first?.rol, .sistema)
        XCTAssertEqual(
            historial.first?.texto,
            Historial.cabeceraResumen + "\nEL DATO CLAVE ES 42"
        )
        XCTAssertFalse(historial.contains { $0.texto.contains("Memoria curada") })
        XCTAssertEqual(Array(historial.dropFirst()), chat.mensajes)
    }

    func testElResumenGuardadoNoSeDuplicaSiLaMemoriaYaLoTrae() {
        let resumen = "EL DATO CLAVE ES 42"
        let chat = conversacion(resumenCompactado: resumen)
        let memoria = entradas(
            "Memoria curada\n" + Historial.cabeceraResumen + "\n" + resumen
        )

        let historial = Historial.paraEnviar(
            conversacion: chat,
            memoria: memoria,
            resumenGuardado: resumen
        )

        XCTAssertEqual(
            historial.filter { $0.texto.contains(Historial.cabeceraResumen) }.count,
            1,
            "La cabecera del resumen no puede viajar dos veces"
        )
        XCTAssertEqual(
            historial.first?.texto,
            Memoria.bloqueSistema(entradas: memoria)
        )
        XCTAssertEqual(Array(historial.dropFirst()), chat.mensajes)
    }

    func testUnResumenVacioNoSeInyecta() {
        let chat = conversacion(resumenCompactado: "  \n  ")

        let historial = Historial.paraEnviar(
            conversacion: chat,
            memoria: entradas("Memoria curada")
        )

        XCTAssertEqual(historial.count, chat.mensajes.count + 1)
        XCTAssertEqual(historial.filter { $0.rol == .sistema }.count, 1)
    }

    func testSinEntradasElResumenVaTrasElBloqueDeCapacidad() {
        let chat = conversacion(resumenCompactado: "Resumen guardado")

        let historial = Historial.paraEnviar(
            conversacion: chat,
            memoria: []
        )

        XCTAssertEqual(historial.first?.rol, .sistema)
        XCTAssertTrue(historial.first?.texto.contains(Memoria.cabeceraBloque) == true)
        XCTAssertEqual(historial[1].rol, .sistema)
        XCTAssertEqual(
            historial[1].texto,
            Historial.cabeceraResumen + "\nResumen guardado"
        )
        XCTAssertEqual(Array(historial.dropFirst(2)), chat.mensajes)
    }

    func testLasInstruccionesVanJustoAntesDelUltimoMensajeDeUsuario() {
        let historial = [
            ChatMessage(rol: .sistema, texto: "prompt"),
            ChatMessage(rol: .usuario, texto: "uno"),
            ChatMessage(rol: .asistente, texto: "dos"),
            ChatMessage(rol: .usuario, texto: "tres")
        ]

        let salida = Historial.insertarInstrucciones(
            historial,
            instrucciones: ["Regla A", "Regla B"]
        )

        XCTAssertEqual(
            salida.map(\.texto),
            ["prompt", "uno", "dos", "Regla A", "Regla B", "tres"]
        )
        XCTAssertEqual(
            salida.map(\.rol),
            [.sistema, .usuario, .asistente, .sistema, .sistema, .usuario]
        )
    }

    func testSinMensajeDeUsuarioLasInstruccionesVanAlFinal() {
        let historial = [
            ChatMessage(rol: .sistema, texto: "prompt"),
            ChatMessage(rol: .asistente, texto: "respuesta")
        ]

        let salida = Historial.insertarInstrucciones(
            historial,
            instrucciones: ["Regla"]
        )

        XCTAssertEqual(salida.map(\.texto), ["prompt", "respuesta", "Regla"])
    }

    func testLasInstruccionesVaciasSeOmiten() {
        let historial = [ChatMessage(rol: .usuario, texto: "hola")]

        let salida = Historial.insertarInstrucciones(
            historial,
            instrucciones: ["", "   ", "Regla"]
        )

        XCTAssertEqual(salida.map(\.texto), ["Regla", "hola"])
        XCTAssertEqual(salida.map(\.rol), [.sistema, .usuario])
    }

    func testSinInstruccionesUtilesElHistorialNoCambia() {
        let historial = [ChatMessage(rol: .usuario, texto: "hola")]

        XCTAssertEqual(
            Historial.insertarInstrucciones(historial, instrucciones: []),
            historial
        )
        XCTAssertEqual(
            Historial.insertarInstrucciones(historial, instrucciones: ["", "  "]),
            historial
        )
    }
}
