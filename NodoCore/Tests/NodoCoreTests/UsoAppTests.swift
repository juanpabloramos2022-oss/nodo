import XCTest

@testable import NodoCore

/// Libro de gasto por dia y por mes (COST.2).
///
/// Las fechas se construyen a mediodia para que ningun cambio de zona horaria
/// las mande al dia anterior; las cifras son de ejemplo, no de ningun proveedor
/// real.
final class UsoAppTests: XCTestCase {
    private func fecha(_ anio: Int, _ mes: Int, _ dia: Int) -> Date {
        var componentes = DateComponents()
        componentes.year = anio
        componentes.month = mes
        componentes.day = dia
        componentes.hour = 12
        return Calendar(identifier: .gregorian).date(from: componentes)!
    }

    func testRegistrarSumaPorDiaYPorMes() {
        var libro = UsoApp()
        let uno = fecha(2025, 1, 15)
        let dos = fecha(2025, 1, 16)
        let otroMes = fecha(2025, 2, 3)

        libro.registrar(
            uso: UsoTokens(entrada: 100, salida: 50),
            usd: 0.10,
            fecha: uno
        )
        libro.registrar(
            uso: UsoTokens(entrada: 200, salida: 100),
            usd: 0.20,
            fecha: uno
        )
        libro.registrar(
            uso: UsoTokens(entrada: 300, salida: 150),
            usd: 0.30,
            fecha: dos
        )
        libro.registrar(
            uso: UsoTokens(entrada: 400, salida: 200),
            usd: 0.40,
            fecha: otroMes
        )

        // Dos llamadas del mismo dia comparten tramo.
        XCTAssertEqual(libro.dia(uno).uso, UsoTokens(entrada: 300, salida: 150))
        XCTAssertEqual(libro.dia(uno).usd, 0.30, accuracy: 0.0000001)
        XCTAssertEqual(libro.dia(dos).uso, UsoTokens(entrada: 300, salida: 150))

        // El mes suma sus dos dias y no se mezcla con el mes siguiente.
        XCTAssertEqual(libro.mes(uno).uso, UsoTokens(entrada: 600, salida: 300))
        XCTAssertEqual(libro.mes(uno).usd, 0.60, accuracy: 0.0000001)
        XCTAssertEqual(libro.mes(otroMes).uso, UsoTokens(entrada: 400, salida: 200))
        XCTAssertEqual(libro.mes(otroMes).usd, 0.40, accuracy: 0.0000001)
    }

    func testLosTotalesSumanTodosLosTramos() {
        var libro = UsoApp()
        libro.registrar(
            uso: UsoTokens(entrada: 10, salida: 5),
            usd: 0.01,
            fecha: fecha(2025, 1, 15)
        )
        libro.registrar(
            uso: UsoTokens(entrada: 20, salida: 10),
            usd: 0.02,
            fecha: fecha(2025, 2, 1)
        )

        XCTAssertEqual(libro.totalDias.uso, UsoTokens(entrada: 30, salida: 15))
        XCTAssertEqual(libro.totalMeses.uso, UsoTokens(entrada: 30, salida: 15))
        XCTAssertEqual(libro.totalDias.usd, 0.03, accuracy: 0.0000001)
        XCTAssertEqual(libro.totalMeses.usd, 0.03, accuracy: 0.0000001)
    }

    func testMigrarVuelcaAlMesEnCursoYLosDiasEmpiezanHoy() {
        var libro = UsoApp()
        let hoy = fecha(2025, 3, 10)

        libro.migrar(
            uso: UsoTokens(entrada: 1_000, salida: 500),
            usd: 0.42,
            fecha: hoy
        )

        XCTAssertTrue(libro.migrado)
        XCTAssertEqual(libro.mes(hoy).uso, UsoTokens(entrada: 1_000, salida: 500))
        XCTAssertEqual(libro.mes(hoy).usd, 0.42, accuracy: 0.0000001)

        // El dia de hoy arranca vacio: la migracion no reparte historia.
        XCTAssertEqual(libro.dia(hoy).uso, UsoTokens())
        XCTAssertEqual(libro.dia(hoy).usd, 0, accuracy: 0.0000001)

        // Ni un solo dia anterior inventado: el libro diario empieza hoy.
        XCTAssertEqual(libro.dias.count, 1)
        XCTAssertEqual(Set(libro.dias.keys), Set([UsoApp.claveDia(hoy)]))
    }

    func testMigrarNoSeRepite() {
        var libro = UsoApp()
        let hoy = fecha(2025, 3, 10)

        libro.migrar(uso: UsoTokens(entrada: 100, salida: 50), usd: 0.10, fecha: hoy)
        libro.migrar(uso: UsoTokens(entrada: 100, salida: 50), usd: 0.10, fecha: hoy)

        XCTAssertEqual(libro.mes(hoy).uso, UsoTokens(entrada: 100, salida: 50))
        XCTAssertEqual(libro.mes(hoy).usd, 0.10, accuracy: 0.0000001)
    }

    func testClavesDeFecha() {
        let dia = fecha(2025, 1, 5)
        XCTAssertEqual(UsoApp.claveDia(dia), "2025-01-05")
        XCTAssertEqual(UsoApp.claveMes(dia), "2025-01")
    }

    func testJSONIdaYVueltaYLecturaTolerante() throws {
        var libro = UsoApp()
        libro.registrar(
            uso: UsoTokens(entrada: 10, salida: 5),
            usd: 0.01,
            fecha: fecha(2025, 1, 5)
        )

        let vuelta = try JSONDecoder().decode(
            UsoApp.self,
            from: JSONEncoder().encode(libro)
        )
        XCTAssertEqual(vuelta, libro)

        // Una configuracion guardada antes del libro arranca con el vacio.
        let json = """
        {
          "version": 1,
          "proveedores": [],
          "systemPrompt": "memoria",
          "servidor": {"nombre": "Servidor", "url": "", "activo": false}
        }
        """
        let config = try AppConfig.desde(json: Data(json.utf8))
        XCTAssertEqual(config.usoApp, UsoApp())
        XCTAssertFalse(config.usoApp.migrado)
    }
}
