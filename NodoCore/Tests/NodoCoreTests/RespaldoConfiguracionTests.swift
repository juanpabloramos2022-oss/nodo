import Foundation
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
            memoria: [
                EntradaMemoria(
                    texto: "Memoria de prueba con datos genericos.",
                    fecha: Date(timeIntervalSince1970: 100)
                )
            ],
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

        XCTAssertEqual(restaurada.memoria, config.memoria)
        XCTAssertEqual(restaurada.skills, config.skills)
        XCTAssertEqual(restaurada.proveedores, config.proveedores)
        XCTAssertEqual(restaurada.topeAvisoCosto, 0.25)
        XCTAssertEqual(RespaldoConfiguracion.ventanas(de: leido), ventanas)
    }

    func testLasVentanasSeDevuelvenAparteDeLaConfiguracion() throws {
        let respaldo = RespaldoConfiguracion(
            memoria: [EntradaMemoria(texto: "memoria")],
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
            memoria: [EntradaMemoria(texto: "Memoria de prueba sin credenciales")],
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

    func testElRespaldoIncluyeLaFontaneriaMCPSinToken() throws {
        let config = AppConfig(
            servidor: ServerConfig(
                nombre: "Servidor de prueba",
                url: "https://servidor.test/mcp",
                activo: true
            )
        )

        let respaldo = RespaldoConfiguracion.hacerRespaldo(config: config, ventanas: [:])
        let texto = String(
            decoding: try respaldo.json(),
            as: UTF8.self
        )

        // El formato total define un campo MCP con la fontaneria del servidor
        // (nombre, URL y activo), pero NUNCA con su token: ese vive en el
        // llavero bajo ServerConfig.tokenKeychain.
        XCTAssertEqual(respaldo.mcp?.nombre, "Servidor de prueba")
        XCTAssertEqual(respaldo.mcp?.url, "https://servidor.test/mcp")
        XCTAssertEqual(respaldo.mcp?.activo, true)
        XCTAssertFalse(texto.contains(ServerConfig.tokenKeychain))
        XCTAssertFalse(texto.lowercased().contains("\"token\""))
    }

    func testElCampoMCPQuedaVacioSiNoHayServidorConfigurado() {
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: AppConfig(),
            ventanas: [:]
        )

        XCTAssertNil(respaldo.mcp)
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
            memoria: [EntradaMemoria(texto: "nueva memoria")],
            proveedores: [proveedor],
            topeGlobalUSD: 0.10
        )

        let restaurada = RespaldoConfiguracion.aplicar(respaldo, sobre: base)

        XCTAssertEqual(restaurada.servidor, servidor)
        XCTAssertEqual(restaurada.proveedorActivo, proveedor.id)
        XCTAssertEqual(restaurada.memoria.map(\.texto), ["nueva memoria"])
    }

    // MARK: - Formato total v2 (BACK.1/BACK.2)

    func testElRespaldoTotalNoContieneNingunValorDeClave() throws {
        let centinela = "sk-centinela-de-prueba-no-debe-salir"
        let proveedor = Ayudas.proveedor()
        let llavero = AlmacenClavesMemoria()
        try llavero.guardar(centinela, para: proveedor.claveKeychain)
        try llavero.guardar(centinela, para: ServerConfig.tokenKeychain)

        let config = AppConfig(
            proveedores: [proveedor],
            memoria: [EntradaMemoria(texto: "Memoria sin credenciales")],
            servidor: ServerConfig(
                nombre: "MCP",
                url: "https://mcp.test/x",
                activo: true
            ),
            topeAvisoCosto: 1.00,
            skills: [
                SkillLocal(
                    nombre: "Prueba",
                    slug: "prueba",
                    instrucciones: "Instrucciones de prueba"
                )
            ],
            packSkillsVersion: PACK_VERSION
        )
        let conversacion = Conversation(
            mensajes: [ChatMessage(rol: .usuario, texto: "Mensaje de juguete")],
            resumenCompactado: "Resumen compactado de juguete"
        )
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: ["modelo/de-prueba": 128_000],
            conversaciones: [conversacion],
            tareas: [
                Tarea(
                    instruccion: "Tarea de juguete",
                    pasos: [Paso(descripcion: "Paso uno", estado: .terminado)]
                )
            ]
        )

        let texto = String(decoding: try respaldo.json(), as: UTF8.self)
        let minusculas = texto.lowercased()

        XCTAssertFalse(texto.contains(centinela))
        // Los campos de credencial se buscan como CLAVES JSON, no como prosa:
        // las instrucciones de las skills pueden usar "clave" en su sentido
        // normal y eso no es un secreto.
        for campo in [
            "apikey", "api_key", "clave", "token", "bearer",
            "secreto", "secret", "password", "authorization"
        ] {
            XCTAssertFalse(
                minusculas.contains("\"\(campo)\""),
                "El campo de credencial \(campo) apareció en el respaldo"
            )
        }
    }

    func testElManifiestoCuadraConElContenidoYLaVersion() throws {
        var usoApp = UsoApp()
        usoApp.registrar(
            uso: UsoTokens(entrada: 10, salida: 5),
            usd: 0.01,
            fecha: Date(timeIntervalSince1970: 0)
        )
        let config = AppConfig(
            proveedores: [Ayudas.proveedor()],
            memoria: [EntradaMemoria(texto: "una entrada")],
            skills: [
                SkillLocal(nombre: "S", slug: "s", instrucciones: "instrucciones")
            ],
            usoApp: usoApp
        )

        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: ["modelo": 100_000],
            conversaciones: [Conversation(), Conversation()],
            tareas: [Tarea(instruccion: "tarea")]
        )

        let manifiesto = try XCTUnwrap(respaldo.manifiesto)
        XCTAssertEqual(manifiesto.versionFormato, respaldo.versionFormato)
        XCTAssertEqual(manifiesto.versionFormato, RespaldoConfiguracion.formatoActual)
        XCTAssertEqual(manifiesto.conversaciones, 2)
        XCTAssertEqual(manifiesto.tareas, 1)
        XCTAssertEqual(manifiesto.memoria, 1)
        XCTAssertEqual(manifiesto.skills, 1)
        XCTAssertEqual(manifiesto.proveedores, 1)
        XCTAssertEqual(manifiesto.ventanas, 1)
        XCTAssertEqual(manifiesto.diasDeGasto, 1)
        XCTAssertEqual(manifiesto.mesesDeGasto, 1)
        XCTAssertTrue(manifiesto.cuadraCon(respaldo))

        // La ida y vuelta no puede perder el manifiesto ni el contenido.
        let leido = try RespaldoConfiguracion.desde(json: try respaldo.json())
        let manifiestoLeido = try XCTUnwrap(leido.manifiesto)
        XCTAssertEqual(manifiestoLeido, manifiesto)
        XCTAssertTrue(manifiestoLeido.cuadraCon(leido))
        XCTAssertEqual(leido.conversaciones, respaldo.conversaciones)
        XCTAssertEqual(leido.tareas, respaldo.tareas)
        XCTAssertEqual(leido.usoApp, respaldo.usoApp)
        XCTAssertEqual(leido.mcp, respaldo.mcp)
    }

    func testUnManifiestoQueNoCuadraSeRechazaSinAplicarse() throws {
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: AppConfig(memoria: [EntradaMemoria(texto: "memoria")]),
            ventanas: [:]
        )
        var manipulado = respaldo
        manipulado.manifiesto = ManifiestoRespaldo(
            versionFormato: respaldo.versionFormato,
            conversaciones: 99
        )

        XCTAssertThrowsError(try manipulado.validar()) { error in
            XCTAssertEqual(error as? ErrorRespaldo, .manifiestoIncoherente)
        }
    }

    func testUnRespaldoViejoSinManifiestoSigueSiendoValido() throws {
        let json = """
        {
          "memoria": "Memoria vieja",
          "skills": [],
          "ventanas": {},
          "proveedores": [],
          "topeGlobalUSD": 1.0
        }
        """
        let respaldo = try RespaldoConfiguracion.desde(json: Data(json.utf8))

        XCTAssertNil(respaldo.manifiesto)
        XCTAssertEqual(respaldo.versionFormato, 1)
        XCTAssertNoThrow(try respaldo.validar())
    }

    func testIdsOSlugsDuplicadosSeRechazan() {
        let skill = SkillLocal(nombre: "Repetida", slug: "repetida", instrucciones: "x")
        let respaldo = RespaldoConfiguracion(
            skills: [skill, skill],
            topeGlobalUSD: 1.0
        )

        XCTAssertThrowsError(try respaldo.validar()) { error in
            XCTAssertEqual(error as? ErrorRespaldo, .idsDuplicados)
        }
    }
}
