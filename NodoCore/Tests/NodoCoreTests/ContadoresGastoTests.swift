import XCTest

@testable import NodoCore

final class ContadoresGastoTests: XCTestCase {
    // Nota: la inmunidad al borrado de chats no se prueba aqui porque el
    // contador vive en AppConfig y no en Conversation. Borrar una conversacion
    // no toca esta estructura; la app solo debe leer y escribir el `gasto` de
    // la configuracion, nunca recalcularlo desde los chats.

    func testRegistrarSumaEnLosDosContadores() {
        var contadores = ContadoresGasto()

        contadores.registrar(costo: 0.10, hoy: "2025-01-15")
        contadores.registrar(costo: 0.05, hoy: "2025-01-15")

        XCTAssertEqual(contadores.delDia, 0.15, accuracy: 0.0001)
        XCTAssertEqual(contadores.desdeReinicio, 0.15, accuracy: 0.0001)
        XCTAssertEqual(contadores.fechaDelDia, "2025-01-15")
    }

    func testCambioDeDiaReiniciaSoloElContadorDelDia() {
        var contadores = ContadoresGasto()
        contadores.registrar(costo: 0.40, hoy: "2025-01-15")

        contadores.registrar(costo: 0.25, hoy: "2025-01-16")

        XCTAssertEqual(contadores.delDia, 0.25, accuracy: 0.0001)
        XCTAssertEqual(contadores.fechaDelDia, "2025-01-16")
        XCTAssertEqual(contadores.desdeReinicio, 0.65, accuracy: 0.0001)
    }

    func testReiniciarSoloTocaElAcumuladoDesdeElReinicio() {
        var contadores = ContadoresGasto()
        contadores.registrar(costo: 0.30, hoy: "2025-01-15")

        contadores.reiniciar()

        XCTAssertEqual(contadores.delDia, 0.30, accuracy: 0.0001)
        XCTAssertEqual(contadores.desdeReinicio, 0, accuracy: 0.0001)
        XCTAssertEqual(contadores.fechaDelDia, "2025-01-15")
    }

    func testLosContadoresSobrevivenAlJSONDeLaConfiguracion() throws {
        var contadores = ContadoresGasto()
        contadores.registrar(costo: 0.12, hoy: "2025-01-15")
        let config = AppConfig(gasto: contadores)

        let recargada = try AppConfig.desde(json: try config.json())

        XCTAssertEqual(recargada.gasto, contadores)
    }

    func testConfiguracionSinGastoArrancaEnCero() throws {
        let json = """
        {
          "version": 1,
          "proveedores": [],
          "systemPrompt": "memoria",
          "servidor": {"nombre": "Servidor", "url": "", "activo": false}
        }
        """

        let config = try AppConfig.desde(json: Data(json.utf8))

        XCTAssertEqual(config.gasto, ContadoresGasto())
        XCTAssertEqual(config.gasto.delDia, 0, accuracy: 0.0001)
        XCTAssertEqual(config.gasto.desdeReinicio, 0, accuracy: 0.0001)
        XCTAssertEqual(config.gasto.fechaDelDia, "")
    }
}
