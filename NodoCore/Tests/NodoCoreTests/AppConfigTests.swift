import XCTest

@testable import NodoCore

final class ProviderConfigTests: XCTestCase {
    func testProveedorValidoPasa() throws {
        XCTAssertNoThrow(try Ayudas.proveedor().validar())
    }

    func testURLVaciaFalla() {
        let config = ProviderConfig(nombre: "x", baseURL: "  ", modelo: "m")
        XCTAssertThrowsError(try config.validarURL()) { error in
            XCTAssertEqual(error as? ErrorConfig, .urlInvalida)
        }
    }

    func testHTTPNoLocalFalla() {
        let config = ProviderConfig(nombre: "x", baseURL: "http://api.ejemplo.test/v1", modelo: "m")
        XCTAssertThrowsError(try config.validarURL()) { error in
            XCTAssertEqual(error as? ErrorConfig, .urlNoSegura)
        }
    }

    func testHTTPLocalSePermite() {
        let config = ProviderConfig(nombre: "local", baseURL: "http://localhost:11434/v1", modelo: "m")
        XCTAssertNoThrow(try config.validarURL())
    }

    func testHTTPEnIPLocalSePermite() {
        let config = ProviderConfig(nombre: "local", baseURL: "http://127.0.0.1:11434/v1", modelo: "m")
        XCTAssertNoThrow(try config.validarURL())
    }

    func testEsquemaRaroFalla() {
        let config = ProviderConfig(nombre: "x", baseURL: "ftp://a.test/x", modelo: "m")
        XCTAssertThrowsError(try config.validarURL())
    }

    func testModeloVacioFalla() {
        let config = ProviderConfig(nombre: "x", baseURL: "https://a.test", modelo: " ")
        XCTAssertThrowsError(try config.validar()) { error in
            XCTAssertEqual(error as? ErrorConfig, .modeloVacio)
        }
    }

    func testNombreVacioFalla() {
        let config = ProviderConfig(nombre: "", baseURL: "https://a.test", modelo: "m")
        XCTAssertThrowsError(try config.validar()) { error in
            XCTAssertEqual(error as? ErrorConfig, .nombreVacio)
        }
    }

    func testEndpointChatCompletions() throws {
        XCTAssertEqual(
            try Ayudas.proveedor().endpointChat().absoluteString,
            "https://api.ejemplo.test/v1/chat/completions"
        )
    }

    func testEndpointAnthropic() throws {
        let config = Ayudas.proveedor(base: "https://api.anthropic.com", protocolo: .anthropic)
        XCTAssertEqual(
            try config.endpointChat().absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
    }

    func testClaveKeychainEsUnicaPorProveedor() {
        let uno = Ayudas.proveedor()
        let otro = Ayudas.proveedor()
        XCTAssertNotEqual(uno.claveKeychain, otro.claveKeychain)
        XCTAssertTrue(uno.claveKeychain.hasPrefix("proveedor-"))
    }
}

final class AppConfigTests: XCTestCase {
    func testJSONIdaYVuelta() throws {
        let original = AppConfig(
            proveedores: [Ayudas.proveedor()],
            proveedorActivo: nil,
            systemPrompt: "se breve",
            servidor: ServerConfig(nombre: "s", url: "https://s.test/mcp", activo: true)
        )

        let vuelta = try AppConfig.desde(json: try original.json())

        XCTAssertEqual(vuelta.systemPrompt, "se breve")
        XCTAssertEqual(vuelta.proveedores.count, 1)
        XCTAssertEqual(vuelta.servidor.url, "https://s.test/mcp")
        XCTAssertTrue(vuelta.servidor.activo)
    }

    func testJSONExportadoNoContieneCredenciales() throws {
        let config = AppConfig(proveedores: [Ayudas.proveedor()])
        let texto = String(decoding: try config.json(), as: UTF8.self).lowercased()

        XCTAssertFalse(texto.contains("apikey"))
        XCTAssertFalse(texto.contains("api_key"))
        XCTAssertFalse(texto.contains("bearer"))
        XCTAssertFalse(texto.contains("token"))
    }

    func testConfiguracionInicialTraeProveedorSeleccionado() {
        let config = AppConfig.inicial()
        XCTAssertEqual(config.proveedores.count, 1)
        XCTAssertNotNil(config.proveedorSeleccionado)
        XCTAssertEqual(config.proveedorActivo, config.proveedores.first?.id)
    }

    func testSeleccionCaeAlPrimeroSiElIdNoExiste() {
        let proveedor = Ayudas.proveedor()
        let config = AppConfig(proveedores: [proveedor], proveedorActivo: UUID())
        XCTAssertEqual(config.proveedorSeleccionado?.id, proveedor.id)
    }

    func testJSONCorruptoFalla() {
        XCTAssertThrowsError(try AppConfig.desde(json: Data("no soy json".utf8)))
    }

    func testPromptPorDefectoNoEstaVacio() {
        XCTAssertFalse(AppConfig.promptPorDefecto.isEmpty)
    }
}

final class ServerConfigTests: XCTestCase {
    func testSinHTTPSFalla() {
        let config = ServerConfig(url: "http://servidor.test/mcp", activo: true)
        XCTAssertThrowsError(try config.validarURL())
        XCTAssertFalse(config.estaConfigurado)
    }

    func testInactivoNoEstaConfigurado() {
        let config = ServerConfig(url: "https://servidor.test/mcp", activo: false)
        XCTAssertFalse(config.estaConfigurado)
    }

    func testValidoEstaConfigurado() {
        let config = ServerConfig(url: "https://servidor.test/mcp", activo: true)
        XCTAssertTrue(config.estaConfigurado)
    }

    func testURLVaciaFalla() {
        let config = ServerConfig(url: "   ", activo: true)
        XCTAssertFalse(config.estaConfigurado)
    }
}

final class AlmacenClavesMemoriaTests: XCTestCase {
    func testGuardarLeerBorrar() throws {
        let almacen = AlmacenClavesMemoria()
        try almacen.guardar("secreto", para: "k1")

        XCTAssertEqual(almacen.leer("k1"), "secreto")
        XCTAssertEqual(almacen.cantidad, 1)

        try almacen.borrar("k1")
        XCTAssertNil(almacen.leer("k1"))
        XCTAssertEqual(almacen.cantidad, 0)
    }

    func testLeerInexistenteDevuelveNil() {
        XCTAssertNil(AlmacenClavesMemoria().leer("nada"))
    }

    func testSobrescribirNoDuplica() throws {
        let almacen = AlmacenClavesMemoria()
        try almacen.guardar("uno", para: "k")
        try almacen.guardar("dos", para: "k")

        XCTAssertEqual(almacen.leer("k"), "dos")
        XCTAssertEqual(almacen.cantidad, 1)
    }
}

final class HttpFetchToolTests: XCTestCase {
    func testRechazaHTTPPlano() async {
        let transporte = TransporteFalso()
        let herramienta = HttpFetchTool(transporte: transporte)

        do {
            _ = try await herramienta.ejecutar(argumentos: "{\"url\":\"http://a.test\"}")
            XCTFail("deberia lanzar")
        } catch let error as ErrorHerramienta {
            XCTAssertEqual(error, .noPermitida("solo se admite https, no http"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }

        XCTAssertTrue(transporte.peticiones.isEmpty, "no debe llegar a la red")
    }

    func testFaltaLaURL() async {
        let herramienta = HttpFetchTool(transporte: TransporteFalso())

        do {
            _ = try await herramienta.ejecutar(argumentos: "{}")
            XCTFail("deberia lanzar")
        } catch let error as ErrorHerramienta {
            XCTAssertEqual(error, .argumentosInvalidos("falta la url"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }

    func testArgumentosQueNoSonJSON() async {
        let herramienta = HttpFetchTool(transporte: TransporteFalso())

        do {
            _ = try await herramienta.ejecutar(argumentos: "no soy json")
            XCTFail("deberia lanzar")
        } catch let error as ErrorHerramienta {
            XCTAssertEqual(error, .argumentosInvalidos("no es un objeto JSON"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }

    func testDevuelveElTextoDeLaPagina() async throws {
        let transporte = TransporteFalso(
            respuesta: HTTPRespuesta(estado: 200, cuerpo: Data("contenido util".utf8))
        )
        let herramienta = HttpFetchTool(transporte: transporte)

        let texto = try await herramienta.ejecutar(argumentos: "{\"url\":\"https://a.test\"}")
        XCTAssertEqual(texto, "contenido util")
        XCTAssertEqual(transporte.peticiones.first?.metodo, "GET")
    }

    func testRecortaElContenidoGrande() async throws {
        let grande = String(repeating: "x", count: 1_000)
        let transporte = TransporteFalso(
            respuesta: HTTPRespuesta(estado: 200, cuerpo: Data(grande.utf8))
        )
        let herramienta = HttpFetchTool(transporte: transporte, maxBytes: 100)

        let texto = try await herramienta.ejecutar(argumentos: "{\"url\":\"https://a.test\"}")
        XCTAssertTrue(texto.contains("recortado"))
        XCTAssertLessThan(texto.count, 400)
    }

    func testErrorHTTPSeDevuelveComoTexto() async throws {
        let transporte = TransporteFalso(respuesta: HTTPRespuesta(estado: 404))
        let herramienta = HttpFetchTool(transporte: transporte)

        let texto = try await herramienta.ejecutar(argumentos: "{\"url\":\"https://a.test/x\"}")
        XCTAssertTrue(texto.contains("404"))
    }

    func testPaginaVaciaSeExplica() async throws {
        let transporte = TransporteFalso(respuesta: HTTPRespuesta(estado: 200, cuerpo: Data()))
        let herramienta = HttpFetchTool(transporte: transporte)

        let texto = try await herramienta.ejecutar(argumentos: "{\"url\":\"https://a.test\"}")
        XCTAssertTrue(texto.contains("no devolvio texto"))
    }
}

final class ArgumentosTests: XCTestCase {
    func testLeeTexto() throws {
        let valores = try Argumentos.diccionario("{\"a\":\"hola\"}")
        XCTAssertEqual(Argumentos.texto(valores, clave: "a"), "hola")
    }

    func testNumeroSeConvierteATexto() throws {
        let valores = try Argumentos.diccionario("{\"n\":42}")
        XCTAssertEqual(Argumentos.texto(valores, clave: "n"), "42")
    }

    func testClaveAusenteDevuelveNil() throws {
        let valores = try Argumentos.diccionario("{}")
        XCTAssertNil(Argumentos.texto(valores, clave: "nada"))
    }

    func testTextoVacioDevuelveDiccionarioVacio() throws {
        XCTAssertTrue(try Argumentos.diccionario("  ").isEmpty)
    }
}
