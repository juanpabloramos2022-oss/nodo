import XCTest

@testable import NodoCore

final class AnthropicClientTests: XCTestCase {
    private func cliente(_ transporte: TransporteFalso) -> AnthropicClient {
        AnthropicClient(
            transporte: transporte,
            config: Ayudas.proveedor(base: "https://api.anthropic.com", protocolo: .anthropic),
            clave: "clave-anthropic"
        )
    }

    private func cuerpo(_ peticion: HTTPRequest) throws -> [String: Any] {
        let datos = try XCTUnwrap(peticion.cuerpo)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
    }

    /// Trozo SSE con el evento que se le pase.
    private func trozo(_ objeto: [String: Any]) -> String {
        "data: " + Ayudas.json(objeto) + "\n\n"
    }

    func testConstruyePeticionConSusCabeceras() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")],
            herramientas: []
        )

        XCTAssertEqual(peticion.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(peticion.cabeceras["x-api-key"], "clave-anthropic")
        XCTAssertEqual(peticion.cabeceras["anthropic-version"], "2023-06-01")
        XCTAssertNil(peticion.cabeceras["Authorization"])

        let contenido = try cuerpo(peticion)
        XCTAssertEqual(contenido["model"] as? String, "modelo-x")
        XCTAssertEqual(contenido["stream"] as? Bool, true)
        XCTAssertNotNil(contenido["max_tokens"])
    }

    func testSistemaVaSeparadoDeLosMensajes() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [
                ChatMessage(rol: .sistema, texto: "eres breve"),
                ChatMessage(rol: .usuario, texto: "hola")
            ],
            herramientas: []
        )

        let contenido = try cuerpo(peticion)
        XCTAssertEqual(contenido["system"] as? String, "eres breve")

        let mensajes = try XCTUnwrap(contenido["messages"] as? [[String: Any]])
        XCTAssertEqual(mensajes.count, 1)
        XCTAssertEqual(mensajes.first?["role"] as? String, "user")
    }

    func testSinMensajeDeSistemaNoHayCampoSystem() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")],
            herramientas: []
        )

        XCTAssertNil(try cuerpo(peticion)["system"])
    }

    func testResultadosDeHerramientaSeAgrupanEnUnMensajeDeUsuario() {
        let mensajes: [ChatMessage] = [
            ChatMessage(rol: .usuario, texto: "x"),
            ChatMessage(
                rol: .asistente,
                texto: "",
                toolCalls: [
                    ToolCall(id: "t1", nombre: "a", argumentos: "{}"),
                    ToolCall(id: "t2", nombre: "b", argumentos: "{}")
                ]
            ),
            ChatMessage(rol: .herramienta, texto: "r1", toolCallId: "t1"),
            ChatMessage(rol: .herramienta, texto: "r2", toolCallId: "t2")
        ]

        let (sistema, traducidos) = AnthropicClient.traducir(mensajes)
        XCTAssertNil(sistema)
        XCTAssertEqual(traducidos.count, 3)

        let ultimo = try? XCTUnwrap(traducidos.last)
        XCTAssertEqual(ultimo?["role"] as? String, "user")
        let bloques = ultimo?["content"] as? [[String: Any]]
        XCTAssertEqual(bloques?.count, 2)
        XCTAssertEqual(bloques?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(bloques?.first?["tool_use_id"] as? String, "t1")
    }

    func testBloqueToolUseLlevaEntradaParseada() {
        let mensajes: [ChatMessage] = [
            ChatMessage(rol: .usuario, texto: "x"),
            ChatMessage(
                rol: .asistente,
                texto: "",
                toolCalls: [ToolCall(id: "t1", nombre: "buscar", argumentos: "{\"q\":\"sol\"}")]
            )
        ]

        let (_, traducidos) = AnthropicClient.traducir(mensajes)
        let bloques = traducidos.last?["content"] as? [[String: Any]]
        let bloque = bloques?.first
        XCTAssertEqual(bloque?["type"] as? String, "tool_use")
        let entrada = bloque?["input"] as? [String: Any]
        XCTAssertEqual(entrada?["q"] as? String, "sol")
    }

    func testStreamDeTextoReportaParciales() async throws {
        let transporte = TransporteFalso(trozos: [
            trozo([
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": "Hola"]
            ]),
            trozo([
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": " adios"]
            ]),
            trozo(["type": "message_stop"])
        ])

        var parciales: [String] = []
        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: { parciales.append($0) }
        )

        XCTAssertEqual(respuesta.texto, "Hola adios")
        XCTAssertEqual(parciales, ["Hola", " adios"])
    }

    func testUsoRealLlegaEnMessageDeltaYSeGuardaEnElMensaje() async throws {
        let transporte = TransporteFalso(trozos: [
            trozo([
                "type": "message_start",
                "message": [
                    "id": "msg_1",
                    "usage": ["input_tokens": 0, "output_tokens": 0]
                ]
            ]),
            trozo([
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": "Hola"]
            ]),
            trozo([
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 11, "output_tokens": 5]
            ]),
            trozo(["type": "message_stop"])
        ])
        let bucle = ToolLoop(motor: cliente(transporte), herramientas: [])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "saluda")]
        )

        XCTAssertEqual(resultado.usoTotal, UsoTokens(entrada: 11, salida: 5))
        let mensaje = try XCTUnwrap(resultado.mensajesNuevos.last)
        XCTAssertEqual(mensaje.texto, "Hola")
        XCTAssertEqual(mensaje.tokensEntrada, 11)
        XCTAssertEqual(mensaje.tokensSalida, 5)
    }

    func testToolUseSeAcumulaDesdePartialJSON() async throws {
        let transporte = TransporteFalso(trozos: [
            trozo([
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "tool_use", "id": "tu_1", "name": "traer_url"]
            ]),
            trozo([
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": "{\"url\":"]
            ]),
            trozo([
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": "\"https://a.test\"}"]
            ]),
            trozo(["type": "content_block_stop", "index": 0]),
            trozo(["type": "message_stop"])
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.toolCalls.count, 1)
        XCTAssertEqual(respuesta.toolCalls.first?.id, "tu_1")
        XCTAssertEqual(respuesta.toolCalls.first?.nombre, "traer_url")
        XCTAssertEqual(respuesta.toolCalls.first?.argumentos, "{\"url\":\"https://a.test\"}")
    }

    func testMessageStopCortaElTurno() async throws {
        let transporte = TransporteFalso(trozos: [
            trozo(["type": "message_stop"]),
            Ayudas.trozoTexto("esto no deberia contar")
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.texto, "")
    }

    func testHerramientasSeEnvianComoInputSchema() throws {
        let herramienta = HttpFetchTool(transporte: TransporteFalso()).definicion
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [herramienta]
        )

        let herramientas = try XCTUnwrap(try cuerpo(peticion)["tools"] as? [[String: Any]])
        XCTAssertEqual(herramientas.first?["name"] as? String, "traer_url")
        XCTAssertNotNil(herramientas.first?["input_schema"])
    }
}
