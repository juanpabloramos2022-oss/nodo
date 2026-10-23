import XCTest

@testable import NodoCore

/// Transporte que responde segun el metodo JSON-RPC de la peticion.
final class TransporteMCP: HTTPUnary {
    var respuestas: [String: HTTPRespuesta] = [:]
    var cabecerasExtra: [String: String] = [:]
    private(set) var peticiones: [HTTPRequest] = []

    func enviar(_ peticion: HTTPRequest) async throws -> HTTPRespuesta {
        peticiones.append(peticion)

        var metodo = ""
        if let cuerpo = peticion.cuerpo,
           let objeto = try? JSONSerialization.jsonObject(with: cuerpo) as? [String: Any] {
            metodo = objeto["method"] as? String ?? ""
        }

        guard var respuesta = respuestas[metodo] else {
            return HTTPRespuesta(estado: 200, cuerpo: Data("{\"jsonrpc\":\"2.0\",\"result\":{}}".utf8))
        }

        for (clave, valor) in cabecerasExtra {
            respuesta.cabeceras[clave] = valor
        }
        return respuesta
    }
}

final class MCPClientTests: XCTestCase {
    private func configurado() -> ServerConfig {
        ServerConfig(nombre: "Servidor", url: "https://servidor.test/mcp", activo: true)
    }

    private func respuestaJSON(_ objeto: [String: Any]) -> HTTPRespuesta {
        HTTPRespuesta(
            estado: 200,
            cabeceras: ["Content-Type": "application/json"],
            cuerpo: try! JSONSerialization.data(withJSONObject: objeto)
        )
    }

    func testRechazaServidorSinURL() {
        XCTAssertThrowsError(
            try MCPClient(transporte: TransporteMCP(), config: ServerConfig(), token: nil)
        )
    }

    func testExigeHTTPS() {
        let config = ServerConfig(nombre: "S", url: "http://servidor.test/mcp", activo: true)
        XCTAssertThrowsError(
            try MCPClient(transporte: TransporteMCP(), config: config, token: nil)
        )
    }

    func testInicializaYLeeInfoDelServidor() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["initialize"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "mesa", "version": "1.2.3"]
            ]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: "token-1")
        let info = try await cliente.inicializar()

        XCTAssertEqual(info.nombre, "mesa")
        XCTAssertEqual(info.version, "1.2.3")

        let peticion = try XCTUnwrap(transporte.peticiones.first)
        XCTAssertEqual(peticion.cabeceras["Authorization"], "Bearer token-1")

        let cuerpo = try XCTUnwrap(peticion.cuerpo)
        let objeto = try XCTUnwrap(JSONSerialization.jsonObject(with: cuerpo) as? [String: Any])
        XCTAssertEqual(objeto["method"] as? String, "initialize")
        XCTAssertEqual(objeto["jsonrpc"] as? String, "2.0")
    }

    func testListaHerramientasYTraduceEsquema() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/list"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "tools": [
                    [
                        "name": "mesa_cola",
                        "description": "Lista las tareas",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "limite": ["type": "integer", "description": "Cuantas devolver"]
                            ],
                            "required": ["limite"]
                        ]
                    ]
                ]
            ]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let herramientas = try await cliente.listarHerramientas()

        XCTAssertEqual(herramientas.count, 1)
        XCTAssertEqual(herramientas.first?.nombre, "mesa_cola")
        XCTAssertEqual(herramientas.first?.parametros.propiedades["limite"]?.tipo, "integer")
        XCTAssertEqual(herramientas.first?.parametros.requeridos, ["limite"])
    }

    func testGuardaLaSesionQueDevuelveElServidor() async throws {
        let transporte = TransporteMCP()
        transporte.cabecerasExtra["Mcp-Session-Id"] = "sesion-abc"
        transporte.respuestas["initialize"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["serverInfo": ["name": "s", "version": "1"]]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        _ = try await cliente.inicializar()
        _ = try? await cliente.listarHerramientas()

        let conSesion = transporte.peticiones.filter {
            $0.cabeceras["Mcp-Session-Id"] == "sesion-abc"
        }
        XCTAssertFalse(conSesion.isEmpty, "las peticiones posteriores deben llevar la sesion")
    }

    func testMandaLaVersionNegociadaEnLasPeticionesSiguientes() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["initialize"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "s", "version": "1"]
            ]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        _ = try await cliente.inicializar()
        _ = try await cliente.listarHerramientas()

        let peticion = try XCTUnwrap(transporte.peticiones.last)
        XCTAssertEqual(
            peticion.cabeceras["MCP-Protocol-Version"],
            "2025-06-18"
        )
    }

    func testLeeRespuestaEnFormatoSSE() async throws {
        let cuerpo = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"x","description":"y"}]}}

        """
        let transporte = TransporteMCP()
        transporte.respuestas["tools/list"] = HTTPRespuesta(
            estado: 200,
            cabeceras: ["Content-Type": "text/event-stream"],
            cuerpo: Data(cuerpo.utf8)
        )

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let herramientas = try await cliente.listarHerramientas()

        XCTAssertEqual(herramientas.first?.nombre, "x")
    }

    func testErrorJSONRPCSePropaga() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/list"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "error": ["code": -32601, "message": "metodo no encontrado"]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)

        do {
            _ = try await cliente.listarHerramientas()
            XCTFail("deberia lanzar")
        } catch let error as ErrorMCP {
            XCTAssertEqual(error, .errorDelServidor("metodo no encontrado"))
        }
    }

    func testHTTPNoAutorizadoSePropagaComoErrorDeAPI() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/list"] = HTTPRespuesta(
            estado: 401,
            cabeceras: ["Content-Type": "application/json"],
            cuerpo: Data("{\"error\":{\"message\":\"token invalido\"}}".utf8)
        )

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: "malo")

        do {
            _ = try await cliente.listarHerramientas()
            XCTFail("deberia lanzar")
        } catch let error as ErrorAPI {
            XCTAssertEqual(error, .noAutorizado(401, "token invalido"))
        }
    }

    func testLlamarHerramientaDevuelveTexto() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/call"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "content": [["type": "text", "text": "3 tareas en cola"]],
                "isError": false
            ]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let texto = try await cliente.llamar(nombre: "mesa_cola", argumentos: "{\"limite\":3}")

        XCTAssertEqual(texto, "3 tareas en cola")

        let peticion = try XCTUnwrap(transporte.peticiones.last)
        let cuerpo = try XCTUnwrap(peticion.cuerpo)
        let objeto = try XCTUnwrap(JSONSerialization.jsonObject(with: cuerpo) as? [String: Any])
        let parametros = try XCTUnwrap(objeto["params"] as? [String: Any])
        XCTAssertEqual(parametros["name"] as? String, "mesa_cola")
        let argumentos = parametros["arguments"] as? [String: Any]
        XCTAssertEqual(argumentos?["limite"] as? Int, 3)
    }

    func testHerramientaConErrorSeMarcaEnElTexto() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/call"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "content": [["type": "text", "text": "no existe esa tarea"]],
                "isError": true
            ]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let texto = try await cliente.llamar(nombre: "mesa_ver", argumentos: "{}")

        XCTAssertTrue(texto.hasPrefix("Error de la herramienta"))
    }

    func testProbarDevuelveInfoYHerramientas() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["initialize"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["serverInfo": ["name": "servidor", "version": "2"]]
        ])
        transporte.respuestas["tools/list"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["tools": [["name": "una", "description": "d"]]]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let (info, herramientas) = try await cliente.probar()

        XCTAssertEqual(info.nombre, "servidor")
        XCTAssertEqual(herramientas.count, 1)
    }

    func testHerramientaMCPDelegaEnElCliente() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/call"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["content": [["type": "text", "text": "hecho"]]]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let definicion = ToolDefinition(
            nombre: "remota",
            descripcion: "d",
            parametros: JSONSchema()
        )
        let herramienta = HerramientaMCP(cliente: cliente, definicion: definicion)

        let texto = try await herramienta.ejecutar(argumentos: "{\"a\":1}")
        XCTAssertEqual(texto, "hecho")
    }

    // MARK: - Context7 v4 y prefijo del servidor

    func testParseaLasHerramientasVigentesDeContext7YNoLaMuerta() async throws {
        let transporte = TransporteMCP()
        transporte.respuestas["tools/list"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "tools": [
                    [
                        "name": "resolve-library-id",
                        "description": "Resuelve el id de una libreria",
                        "inputSchema": ["type": "object"]
                    ],
                    [
                        "name": "query-docs",
                        "description": "Consulta la documentacion",
                        "inputSchema": ["type": "object"]
                    ]
                ]
            ]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let herramientas = try await cliente.listarHerramientas()
        let nombres = herramientas.map(\.nombre)

        XCTAssertEqual(nombres, ["resolve-library-id", "query-docs"])
    }

    func testElPrefijoDelServidorEvitaChoquesYElLlamadoUsaElNombreRemoto() async throws {
        XCTAssertEqual(HerramientaMCP.prefijo(servidor: "Context7"), "context7__")
        XCTAssertEqual(HerramientaMCP.prefijo(servidor: "  "), "mcp__")

        let transporte = TransporteMCP()
        transporte.respuestas["tools/call"] = respuestaJSON([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["content": [["type": "text", "text": "ok"]]]
        ])

        let cliente = try MCPClient(transporte: transporte, config: configurado(), token: nil)
        let base = ToolDefinition(
            nombre: "query-docs",
            descripcion: "Consulta",
            parametros: JSONSchema()
        )
        let herramienta = HerramientaMCP(
            cliente: cliente,
            definicion: base,
            prefijo: HerramientaMCP.prefijo(servidor: "Context7")
        )

        XCTAssertEqual(herramienta.definicion.nombre, "context7__query-docs")
        _ = try await herramienta.ejecutar(argumentos: "{}")

        let peticion = try XCTUnwrap(transporte.peticiones.last)
        let cuerpo = try XCTUnwrap(peticion.cuerpo)
        let objeto = try XCTUnwrap(JSONSerialization.jsonObject(with: cuerpo) as? [String: Any])
        let parametros = try XCTUnwrap(objeto["params"] as? [String: Any])
        XCTAssertEqual(parametros["name"] as? String, "query-docs")
    }
}
