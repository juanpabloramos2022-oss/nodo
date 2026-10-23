import XCTest

@testable import NodoCore

final class RespaldoConfiguracionTests: XCTestCase {
    func testIdaYVueltaRestauraMemoriaSkillsProveedoresYTope() throws {
        let proveedorUno = Ayudas.proveedor(nombre: "Uno")
        let proveedorDos = Ayudas.proveedor(
            nombre: "Dos",
            base: "https://api.otro.test/v1",
            modelo: "modelo-y"
        )
        let skill = SkillLocal(
            nombre: "Resumidor",
            slug: "resumidor",
            instrucciones: "Resume en tres puntos."
        )
        let config = AppConfig(
            proveedores: [proveedorUno, proveedorDos],
            proveedorActivo: proveedorDos.id,
            systemPrompt: "Memoria de prueba con datos genericos.",
            topeAvisoCosto: 0.25,
            skills: [skill]
        )
        let ventanas = ["modelo-x": 128_000, "vendedor/modelo-y": 200_000]

        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: ventanas
        )
        let leido = try RespaldoConfiguracion.desde(json: try respaldo.json())

        let vacia = AppConfig()
        let restaurada = RespaldoConfiguracion.aplicar(leido, sobre: vacia)

        XCTAssertEqual(restaurada.systemPrompt, config.systemPrompt)
        XCTAssertEqual(restaurada.skills, config.skills)
        XCTAssertEqual(restaurada.proveedores, config.proveedores)
        XCTAssertEqual(restaurada.topeAvisoCosto, 0.25)
        XCTAssertEqual(RespaldoConfiguracion.ventanas(de: leido), ventanas)
    }

    func testLasVentanasSeDevuelvenAparteDeLaConfiguracion() throws {
        let respaldo = RespaldoConfiguracion(
            memoria: "memoria",
            ventanas: ["modelo-x": 64_000],
            proveedores: [Ayudas.proveedor()],
            topeGlobalUSD: 0.50
        )

        let resultado = RespaldoConfiguracion.aplicarConVentanas(
            respaldo,
            sobre: AppConfig()
        )

        XCTAssertEqual(resultado.config.topeAvisoCosto, 0.50)
        XCTAssertEqual(resultado.ventanas, ["modelo-x": 64_000])
        XCTAssertEqual(respaldo.ventanas, ["modelo-x": 64_000])
    }

    func testElJSONDelRespaldoNoContieneClavesDeAPI() throws {
        // En este modelo no existe ningun campo de clave dentro de
        // ProviderConfig ni de ServerConfig: las credenciales viven en el
        // llavero. El centinela se guarda ahi y el respaldo ni siquiera recibe
        // el llavero, asi que no puede filtrarlo.
        let centinela = "sk-centinela-de-prueba-no-debe-salir"
        let proveedor = Ayudas.proveedor()
        let llavero = AlmacenClavesMemoria()
        try llavero.guardar(centinela, para: proveedor.claveKeychain)
        try llavero.guardar(centinela, para: ServerConfig.tokenKeychain)

        let config = AppConfig(
            proveedores: [proveedor],
            systemPrompt: "Memoria de prueba sin credenciales",
            topeAvisoCosto: 1.00,
            skills: [
                SkillLocal(
                    nombre: "Prueba",
                    slug: "prueba",
                    instrucciones: "Instrucciones de prueba"
                )
            ]
        )
        let respaldo = RespaldoConfiguracion.hacerRespaldo(config: config, ventanas: [:])

        let texto = String(decoding: try respaldo.json(), as: UTF8.self)
        let minusculas = texto.lowercased()

        XCTAssertFalse(texto.contains(centinela))
        XCTAssertFalse(minusculas.contains("apikey"))
        XCTAssertFalse(minusculas.contains("api_key"))
        XCTAssertFalse(minusculas.contains("clave"))
        XCTAssertFalse(minusculas.contains("token"))
        XCTAssertFalse(minusculas.contains("bearer"))
        XCTAssertFalse(minusculas.contains("secreto"))
    }

    func testElRespaldoNoIncluyeElServidorMCP() throws {
        let config = AppConfig(
            servidor: ServerConfig(
                nombre: "Servidor de prueba",
                url: "https://servidor.test/mcp",
                activo: true
            )
        )

        let texto = String(
            decoding: try RespaldoConfiguracion
                .hacerRespaldo(config: config, ventanas: [:])
                .json(),
            as: UTF8.self
        )

        // El token del MCP vive en el llavero bajo ServerConfig.tokenKeychain;
        // el respaldo no lleva ni la URL ni ese nombre de clave.
        XCTAssertFalse(texto.contains("servidor.test"))
        XCTAssertFalse(texto.contains(ServerConfig.tokenKeychain))
    }

    func testAplicarConservaElServidorYElProveedorActivoValido() {
        let proveedor = Ayudas.proveedor()
        let servidor = ServerConfig(nombre: "MCP", url: "https://mcp.test/x", activo: true)
        let base = AppConfig(
            proveedores: [proveedor],
            proveedorActivo: proveedor.id,
            servidor: servidor
        )
        let respaldo = RespaldoConfiguracion(
            memoria: "nueva memoria",
            proveedores: [proveedor],
            topeGlobalUSD: 0.10
        )

        let restaurada = RespaldoConfiguracion.aplicar(respaldo, sobre: base)

        XCTAssertEqual(restaurada.servidor, servidor)
        XCTAssertEqual(restaurada.proveedorActivo, proveedor.id)
        XCTAssertEqual(restaurada.systemPrompt, "nueva memoria")
    }
}
