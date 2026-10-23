import XCTest

@testable import NodoCore

final class ChatCompletionsClientTests: XCTestCase {
    private func cliente(_ transporte: TransporteFalso) -> ChatCompletionsClient {
        ChatCompletionsClient(
            transporte: transporte,
            config: Ayudas.proveedor(),
            clave: "clave-de-prueba"
        )
    }

    private func cuerpo(_ peticion: HTTPRequest) throws -> [String: Any] {
        let datos = try XCTUnwrap(peticion.cuerpo)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
    }

    func testConstruyePeticionConCabecerasYModelo() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")],
            herramientas: []
        )

        XCTAssertEqual(peticion.url.absoluteString, "https://api.ejemplo.test/v1/chat/completions")
        XCTAssertEqual(peticion.metodo, "POST")
        XCTAssertEqual(peticion.cabeceras["Authorization"], "Bearer clave-de-prueba")
        XCTAssertEqual(peticion.cabeceras["Content-Type"], "application/json")

        let contenido = try cuerpo(peticion)
        XCTAssertEqual(contenido["model"] as? String, "modelo-x")
        XCTAssertEqual(contenido["stream"] as? Bool, true)
        let opciones = try XCTUnwrap(contenido["stream_options"] as? [String: Any])
        XCTAssertEqual(opciones["include_usage"] as? Bool, true)
        let mensajes = try XCTUnwrap(contenido["messages"] as? [[String: Any]])
        XCTAssertEqual(mensajes.first?["role"] as? String, "user")
        XCTAssertEqual(mensajes.first?["content"] as? String, "hola")
    }

    func testBaseURLConBarraFinalNoDuplicaBarra() throws {
        let config = Ayudas.proveedor(base: "https://api.ejemplo.test/v1/")
        let peticion = try ChatCompletionsClient(
            transporte: TransporteFalso(),
            config: config,
            clave: "k"
        ).construirPeticion(mensajes: [], herramientas: [])

        XCTAssertEqual(peticion.url.absoluteString, "https://api.ejemplo.test/v1/chat/completions")
    }

    func testIncluyeHerramientasCuandoLasHay() throws {
        let herramienta = HttpFetchTool(transporte: TransporteFalso()).definicion
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "busca")],
            herramientas: [herramienta]
        )

        let contenido = try cuerpo(peticion)
        let herramientas = try XCTUnwrap(contenido["tools"] as? [[String: Any]])
        XCTAssertEqual(herramientas.count, 1)
        let funcion = try XCTUnwrap(herramientas.first?["function"] as? [String: Any])
        XCTAssertEqual(funcion["name"] as? String, "traer_url")
        let parametros = try XCTUnwrap(funcion["parameters"] as? [String: Any])
        XCTAssertEqual(parametros["type"] as? String, "object")
    }

    func testNoIncluyeToolsSiNoHayHerramientas() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: []
        )
        XCTAssertNil(try cuerpo(peticion)["tools"])
    }

    func testSistemaSeEnviaComoMensajeDeSistema() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [
                ChatMessage(rol: .sistema, texto: "se breve"),
                ChatMessage(rol: .usuario, texto: "hola")
            ],
            herramientas: []
        )

        let mensajes = try XCTUnwrap(try cuerpo(peticion)["messages"] as? [[String: Any]])
        XCTAssertEqual(mensajes.count, 2)
        XCTAssertEqual(mensajes.first?["role"] as? String, "system")
        XCTAssertEqual(mensajes.first?["content"] as? String, "se breve")
        XCTAssertEqual(mensajes.last?["role"] as? String, "user")
    }

    func testSinMensajeDeSistemaNoSeEnviaNinguno() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")],
            herramientas: []
        )

        let mensajes = try XCTUnwrap(try cuerpo(peticion)["messages"] as? [[String: Any]])
        XCTAssertFalse(mensajes.contains { $0["role"] as? String == "system" })
        XCTAssertEqual(mensajes.first?["role"] as? String, "user")
    }

    func testStreamAcumulaTextoYReportaParciales() async throws {
        let transporte = TransporteFalso(trozos: [
            Ayudas.trozoTexto("Hola"),
            Ayudas.trozoTexto(" mundo"),
            "data: [DONE]\n\n"
        ])

        var parciales: [String] = []
        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "saluda")],
            herramientas: [],
            alRecibirTexto: { parciales.append($0) }
        )

        XCTAssertEqual(respuesta.texto, "Hola mundo")
        XCTAssertEqual(parciales, ["Hola", " mundo"])
        XCTAssertTrue(respuesta.toolCalls.isEmpty)
    }

    func testStreamPartidoAMitadDeLinea() async throws {
        let entero = Ayudas.trozoTexto("entero")
        let corte = entero.index(entero.startIndex, offsetBy: 12)
        let transporte = TransporteFalso(trozos: [
            String(entero[..<corte]),
            String(entero[corte...])
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.texto, "entero")
    }

    func testStreamSinDoneConservaElParcial() async throws {
        let transporte = TransporteFalso(trozos: [Ayudas.trozoTexto("a medias")])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.texto, "a medias")
    }

    func testStreamConUsoGuardaLosTokensEnElMensaje() async throws {
        // El stream termina en el trozo de consumo, sin [DONE]: el uso tiene
        // que viajar tambien por el retorno de cierre del parser.
        let transporte = TransporteFalso(trozos: [
            Ayudas.trozoTexto("Hola"),
            Ayudas.trozoUso(entrada: 12, salida: 7)
        ])
        let bucle = ToolLoop(motor: cliente(transporte), herramientas: [])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "saluda")]
        )

        let mensaje = try XCTUnwrap(resultado.mensajesNuevos.last)
        XCTAssertEqual(mensaje.rol, .asistente)
        XCTAssertEqual(mensaje.texto, "Hola")
        XCTAssertEqual(mensaje.tokensEntrada, 12)
        XCTAssertEqual(mensaje.tokensSalida, 7)
        XCTAssertEqual(resultado.usoTotal, UsoTokens(entrada: 12, salida: 7))
    }

    func testStreamConUsoYConDoneTambienGuardaLosTokens() async throws {
        let transporte = TransporteFalso(trozos: [
            Ayudas.trozoTexto("Hola"),
            Ayudas.trozoUso(entrada: 3, salida: 2),
            "data: [DONE]\n\n"
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "saluda")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.texto, "Hola")
        XCTAssertEqual(respuesta.uso, UsoTokens(entrada: 3, salida: 2))
    }

    func testStreamSinUsoDejaElMensajeSinCifras() async throws {
        let transporte = TransporteFalso(trozos: [
            Ayudas.trozoTexto("Hola"),
            "data: [DONE]\n\n"
        ])
        let bucle = ToolLoop(motor: cliente(transporte), herramientas: [])

        let resultado = try await bucle.ejecutar(
            historial: [ChatMessage(rol: .usuario, texto: "saluda")]
        )

        let mensaje = try XCTUnwrap(resultado.mensajesNuevos.last)
        XCTAssertEqual(mensaje.texto, "Hola")
        XCTAssertNil(mensaje.tokensEntrada)
        XCTAssertNil(mensaje.tokensSalida)
        XCTAssertNil(resultado.usoTotal)
    }

    func testTrozoIlegibleNoRompeElStream() async throws {
        let transporte = TransporteFalso(trozos: [
            "data: esto no es json\n\n",
            Ayudas.trozoTexto("sigue"),
            "data: [DONE]\n\n"
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.texto, "sigue")
    }

    func testAcumulaToolCallPartidaEnTrozos() async throws {
        let primera: [String: Any] = [
            "index": 0,
            "id": "call_1",
            "function": ["name": "traer_url", "arguments": "{\"url\":"] as [String: Any]
        ]
        let segunda: [String: Any] = [
            "index": 0,
            "function": ["arguments": "\"https://a.test\"}"] as [String: Any]
        ]

        let transporte = TransporteFalso(trozos: [
            Ayudas.trozoToolCalls([primera]),
            Ayudas.trozoToolCalls([segunda]),
            "data: [DONE]\n\n"
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.toolCalls.count, 1)
        XCTAssertEqual(respuesta.toolCalls.first?.nombre, "traer_url")
        XCTAssertEqual(respuesta.toolCalls.first?.id, "call_1")
        XCTAssertEqual(respuesta.toolCalls.first?.argumentos, "{\"url\":\"https://a.test\"}")
    }

    func testDosToolCallsEnElMismoTurno() async throws {
        let una: [String: Any] = [
            "index": 0,
            "id": "a",
            "function": ["name": "una", "arguments": "{}"] as [String: Any]
        ]
        let otra: [String: Any] = [
            "index": 1,
            "id": "b",
            "function": ["name": "otra", "arguments": "{}"] as [String: Any]
        ]

        let transporte = TransporteFalso(trozos: [
            Ayudas.trozoToolCalls([una, otra]),
            "data: [DONE]\n\n"
        ])

        let respuesta = try await cliente(transporte).responder(
            mensajes: [ChatMessage(rol: .usuario, texto: "x")],
            herramientas: [],
            alRecibirTexto: nil
        )

        XCTAssertEqual(respuesta.toolCalls.map(\.nombre), ["una", "otra"])
        XCTAssertEqual(respuesta.toolCalls.map(\.id), ["a", "b"])
    }

    func testErrorAlAbrirStreamSePropaga() async {
        let transporte = TransporteFalso()
        transporte.errorAlAbrir = ErrorAPI.noAutorizado(401, "clave mala")

        do {
            _ = try await cliente(transporte).responder(
                mensajes: [ChatMessage(rol: .usuario, texto: "x")],
                herramientas: [],
                alRecibirTexto: nil
            )
            XCTFail("deberia haber lanzado")
        } catch let error as ErrorAPI {
            XCTAssertEqual(error, .noAutorizado(401, "clave mala"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }

    func testMensajeDeHerramientaIncluyeToolCallId() throws {
        let peticion = try cliente(TransporteFalso()).construirPeticion(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "x"),
                ChatMessage(rol: .asistente, texto: "", toolCalls: [
                    ToolCall(id: "c1", nombre: "traer_url", argumentos: "{}")
                ]),
                ChatMessage(rol: .herramienta, texto: "resultado", toolCallId: "c1")
            ],
            herramientas: []
        )

        let mensajes = try XCTUnwrap(try cuerpo(peticion)["messages"] as? [[String: Any]])
        XCTAssertEqual(mensajes.count, 3)

        let asistente = mensajes[1]
        let llamadas = try XCTUnwrap(asistente["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(llamadas.first?["id"] as? String, "c1")

        let herramienta = mensajes[2]
        XCTAssertEqual(herramienta["role"] as? String, "tool")
        XCTAssertEqual(herramienta["tool_call_id"] as? String, "c1")
    }
}

final class ErrorAPITests: XCTestCase {
    func testClasificacionDeEstados() {
        XCTAssertNil(ErrorAPI.desdeEstado(200, cuerpo: ""))
        XCTAssertNil(ErrorAPI.desdeEstado(201, cuerpo: ""))
        XCTAssertEqual(ErrorAPI.desdeEstado(401, cuerpo: ""), .noAutorizado(401, ""))
        XCTAssertEqual(ErrorAPI.desdeEstado(403, cuerpo: ""), .noAutorizado(403, ""))
        XCTAssertEqual(ErrorAPI.desdeEstado(429, cuerpo: ""), .limiteDeTasa(429, ""))
        XCTAssertEqual(ErrorAPI.desdeEstado(529, cuerpo: ""), .servidorSaturado(529, ""))
        XCTAssertEqual(ErrorAPI.desdeEstado(503, cuerpo: ""), .servidorSaturado(503, ""))
        XCTAssertEqual(ErrorAPI.desdeEstado(500, cuerpo: ""), .errorDelServidor(500, ""))
    }

    func testExtraeMensajeDelJSON() {
        XCTAssertEqual(
            ErrorAPI.mensajeDeError("{\"error\":{\"message\":\"clave invalida\"}}"),
            "clave invalida"
        )
    }

    func testExtraeMensajePlano() {
        XCTAssertEqual(ErrorAPI.mensajeDeError("{\"message\":\"sin cuota\"}"), "sin cuota")
    }

    func testTextoNoJSONSeDevuelveTalCual() {
        XCTAssertEqual(ErrorAPI.mensajeDeError("algo salio mal"), "algo salio mal")
    }

    func testCuerpoVacioDevuelveVacio() {
        XCTAssertEqual(ErrorAPI.mensajeDeError("   "), "")
    }

    func testReintentaSaturacion() async throws {
        let transporte = TransporteQueFalla(veces: 2, error: .servidorSaturado(529, "x"))

        _ = try await Reintento.conEspera(esperaInicial: .milliseconds(1)) {
            try await transporte.abrirStream(HTTPRequest(url: URL(string: "https://a.test")!))
        }

        XCTAssertEqual(transporte.llamadas, 3)
    }

    func testNoReintentaNoAutorizado() async {
        let transporte = TransporteQueFalla(veces: 99, error: .noAutorizado(401, "x"))

        do {
            _ = try await Reintento.conEspera(esperaInicial: .milliseconds(1)) {
                try await transporte.abrirStream(HTTPRequest(url: URL(string: "https://a.test")!))
            }
            XCTFail("deberia lanzar")
        } catch {
            XCTAssertEqual(transporte.llamadas, 1)
        }
    }

    func testSeRindeTrasLosIntentos() async {
        let transporte = TransporteQueFalla(veces: 99, error: .servidorSaturado(529, "x"))

        do {
            _ = try await Reintento.conEspera(intentos: 3, esperaInicial: .milliseconds(1)) {
                try await transporte.abrirStream(HTTPRequest(url: URL(string: "https://a.test")!))
            }
            XCTFail("deberia lanzar")
        } catch {
            XCTAssertEqual(transporte.llamadas, 3)
        }
    }
}

/// Transporte que falla un numero de veces y luego responde bien.
final class TransporteQueFalla: HTTPStreaming {
    private let veces: Int
    private let error: ErrorAPI
    private(set) var llamadas = 0

    init(veces: Int, error: ErrorAPI) {
        self.veces = veces
        self.error = error
    }

    func abrirStream(_ peticion: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        llamadas += 1
        if llamadas <= veces { throw error }
        return AsyncThrowingStream { $0.finish() }
    }
}
