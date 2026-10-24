import Foundation
import XCTest

@testable import NodoCore

/// Pruebas de la Memoria viva (MEM.1/D5).
///
/// La migracion y el respaldo son las dos puertas por las que puede perderse lo
/// que el dueno ya tenia escrito. Por eso se prueba el texto completo, no solo
/// que la lista tenga una entrada.
final class MemoriaTests: XCTestCase {
    private let idUno = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let idDos = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // MARK: - Migracion de la configuracion

    func testMigracionDelTextoLegadoAUnaSolaEntradaConservaElTextoCompleto() throws {
        let texto = "Primera linea\n\nSegunda linea con datos: 42\n- y un guion"
        let json: [String: Any] = [
            "version": 1,
            "proveedores": [],
            "systemPrompt": texto,
            "servidor": ["nombre": "Servidor", "url": "", "activo": false] as [String: Any]
        ]
        let datos = try JSONSerialization.data(withJSONObject: json)

        let config = try AppConfig.desde(json: datos)

        XCTAssertEqual(
            config.memoria.count,
            1,
            "El texto legado no puede trocearse en varias entradas"
        )
        XCTAssertEqual(
            config.memoria.first?.texto,
            texto,
            "La migracion tiene que conservar el texto completo, no una version recortada"
        )
    }

    func testUnTextoLegadoVacioNoCreaEntrada() throws {
        let json: [String: Any] = [
            "version": 1,
            "proveedores": [],
            "systemPrompt": "   \n  ",
            "servidor": ["nombre": "Servidor", "url": "", "activo": false] as [String: Any]
        ]
        let datos = try JSONSerialization.data(withJSONObject: json)

        let config = try AppConfig.desde(json: datos)

        XCTAssertTrue(config.memoria.isEmpty)
    }

    func testLaMemoriaNuevaSobreviveAlJSONDeLaConfiguracion() throws {
        let entradas = [
            EntradaMemoria(id: idUno, texto: "Vive en Madrid", fecha: Date(timeIntervalSince1970: 100)),
            EntradaMemoria(id: idDos, texto: "Prefiere respuestas breves", fecha: Date(timeIntervalSince1970: 200))
        ]
        let config = AppConfig(memoria: entradas)

        let vuelta = try AppConfig.desde(json: try config.json())

        XCTAssertEqual(vuelta.memoria, entradas)
    }

    // MARK: - Respaldo

    func testRespaldoIdaYVueltaConservaLasEntradas() throws {
        let entradas = [
            EntradaMemoria(id: idUno, texto: "Vive en Madrid", fecha: Date(timeIntervalSince1970: 100)),
            EntradaMemoria(id: idDos, texto: "Prefiere respuestas breves", fecha: Date(timeIntervalSince1970: 200))
        ]
        let config = AppConfig(memoria: entradas, topeAvisoCosto: 0.25)

        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: [:]
        )
        let leido = try RespaldoConfiguracion.desde(json: try respaldo.json())

        XCTAssertEqual(leido.memoria, entradas)

        let restaurada = RespaldoConfiguracion.aplicar(leido, sobre: AppConfig())
        XCTAssertEqual(restaurada.memoria, entradas)
    }

    func testUnRespaldoViejoConTextoPlanoImportaComoUnaEntrada() throws {
        let texto = "Memoria vieja completa\ncon dos lineas y datos: 42"
        let json = """
        {
          "memoria": "Memoria vieja completa\\ncon dos lineas y datos: 42",
          "skills": [],
          "ventanas": {},
          "proveedores": [],
          "topeGlobalUSD": 1.0
        }
        """

        let respaldo = try RespaldoConfiguracion.desde(json: Data(json.utf8))

        XCTAssertEqual(respaldo.memoria.count, 1)
        XCTAssertEqual(respaldo.memoria.first?.texto, texto)
        XCTAssertEqual(respaldo.versionFormato, 1)
    }

    // MARK: - Bloque de sistema

    func testElBloqueDeclaraLaCapacidadYListaLasEntradasConSusIds() {
        let entradas = [
            EntradaMemoria(id: idUno, texto: "Vive en Madrid"),
            EntradaMemoria(id: idDos, texto: "Prefiere respuestas breves")
        ]

        let bloque = Memoria.bloqueSistema(entradas: entradas)

        XCTAssertTrue(bloque.contains(Memoria.cabeceraBloque))
        XCTAssertTrue(bloque.contains(Memoria.nombreHerramientaChat))
        XCTAssertTrue(bloque.contains("guardar"))
        XCTAssertTrue(bloque.contains("actualizar"))
        XCTAssertTrue(bloque.contains("borrar"))
        for entrada in entradas {
            XCTAssertTrue(bloque.contains(entrada.id.uuidString))
            XCTAssertTrue(bloque.contains(entrada.texto))
        }
    }

    func testLaHerramientaDeChatDeclaraAccionTextoEId() {
        let definicion = Memoria.herramientaChat

        XCTAssertEqual(definicion.nombre, "memoria_chat")
        XCTAssertNotNil(definicion.parametros.propiedades["accion"])
        XCTAssertNotNil(definicion.parametros.propiedades["texto"])
        XCTAssertNotNil(definicion.parametros.propiedades["id"])
        XCTAssertTrue(definicion.parametros.requeridos.contains("accion"))
    }
}

// MARK: - Operaciones de lista (MEM.3)

/// Pruebas puras de aplicar y deshacer acciones sobre la lista.
///
/// Viven aparte de la migracion porque aqui no importa el formato guardado:
/// importa que el inverso devuelva EXACTAMENTE el estado anterior.
final class MemoriaOperacionesTests: XCTestCase {
    private let idUno = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let idDos = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testGuardarAnadeUnaEntradaYDeshacerLaQuita() {
        var entradas: [EntradaMemoria] = []

        let resultado = Memoria.aplicar(
            .guardar(texto: "Vive en Madrid"),
            en: &entradas
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una accion aplicada")
        }
        XCTAssertEqual(entradas.map(\.texto), ["Vive en Madrid"])

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertTrue(entradas.isEmpty)
    }

    func testActualizarCambiaSoloLaEntradaIndicadaYDeshacerRestauraElTexto() {
        let original = EntradaMemoria(
            id: idUno,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        let otra = EntradaMemoria(
            id: idDos,
            texto: "Prefiere respuestas breves",
            fecha: Date(timeIntervalSince1970: 200)
        )
        var entradas = [original, otra]

        let resultado = Memoria.aplicar(
            .actualizar(id: idUno, texto: "Vive en Barcelona"),
            en: &entradas
        )

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una accion aplicada")
        }
        XCTAssertEqual(entradas[0].texto, "Vive en Barcelona")
        XCTAssertEqual(entradas[1], otra)

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertEqual(entradas, [original, otra])
    }

    func testBorrarQuitaLaEntradaYDeshacerLaReinsertaEnSuPosicionConSuId() {
        let original = EntradaMemoria(
            id: idUno,
            texto: "Vive en Madrid",
            fecha: Date(timeIntervalSince1970: 100)
        )
        let otra = EntradaMemoria(
            id: idDos,
            texto: "Prefiere respuestas breves",
            fecha: Date(timeIntervalSince1970: 200)
        )
        var entradas = [original, otra]

        let resultado = Memoria.aplicar(.borrar(id: idUno), en: &entradas)

        guard case .aplicada(let cambio) = resultado else {
            return XCTFail("Se esperaba una accion aplicada")
        }
        XCTAssertEqual(entradas, [otra])

        Memoria.deshacer(cambio, en: &entradas)
        XCTAssertEqual(entradas, [original, otra])
    }

    func testUnIdDesconocidoSeRechazaSinTocarLaLista() {
        let original = EntradaMemoria(id: idUno, texto: "Vive en Madrid")
        var entradas = [original]

        let resultado = Memoria.aplicar(
            .actualizar(id: idDos, texto: "No debe entrar"),
            en: &entradas
        )

        guard case .rechazada(let motivo) = resultado else {
            return XCTFail("Se esperaba un rechazo")
        }
        XCTAssertTrue(motivo.contains(idDos.uuidString))
        XCTAssertEqual(entradas, [original])
    }

    func testLaAccionSeLeeDeLosArgumentosYSeRechazaLoQueFalta() throws {
        let accion = try Memoria.accion(
            desdeArgumentos: #"{"accion":"guardar","texto":"Hola"}"#
        )
        XCTAssertEqual(accion, .guardar(texto: "Hola"))

        XCTAssertThrowsError(
            try Memoria.accion(desdeArgumentos: #"{"accion":"renombrar"}"#)
        )
        XCTAssertThrowsError(
            try Memoria.accion(
                desdeArgumentos: #"{"accion":"actualizar","texto":"sin id"}"#
            )
        )
    }
}
