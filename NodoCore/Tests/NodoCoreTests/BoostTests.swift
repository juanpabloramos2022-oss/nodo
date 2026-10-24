import XCTest

@testable import NodoCore

/// Pruebas de las reglas puras de /boost: parseo de angulos, eleccion de combos
/// y tope de gasto. La ejecucion con red vive en NodoAppTests/BoostTests.
final class BoostTests: XCTestCase {
    private func proveedor(
        _ nombre: String,
        entrada: Double?,
        salida: Double?
    ) -> ProviderConfig {
        ProviderConfig(
            nombre: nombre,
            baseURL: "https://\(nombre).test/v1",
            modelo: "\(nombre)-modelo",
            precioEntradaPorMillon: entrada,
            precioSalidaPorMillon: salida
        )
    }

    func testAngulosAceptaNumeracionViñetasYEtiquetaDeAngulo() {
        let texto = """
        Aquí van los ángulos:
        1. Coste real de la migración
        - Riesgo de concurrencia estricta
        Ángulo 3: Coste de oportunidad
        """

        let desglose = Boost.angulos(desde: texto)

        XCTAssertFalse(desglose.parseoFallido)
        XCTAssertEqual(desglose.angulos, [
            "Coste real de la migración",
            "Riesgo de concurrencia estricta",
            "Coste de oportunidad"
        ])
    }

    func testAngulosSinListaConservaLaRespuestaEnteraYDeclaraElFallo() {
        let texto = "La migración conviene si el equipo puede asumir dos sprints."

        let desglose = Boost.angulos(desde: texto)

        XCTAssertTrue(
            desglose.parseoFallido,
            "Sin lista no se inventan angulos: se declara el fallo"
        )
        XCTAssertEqual(desglose.angulos, [texto])
    }

    func testAngulosNoPasaDelMaximo() {
        let texto = "1. Uno\n2. Dos\n3. Tres\n4. Cuatro"

        XCTAssertEqual(Boost.angulos(desde: texto).angulos.count, Boost.maxAngulos)
    }

    func testComboFuerteEsElMayorPrecioDeSalidaYLosBaratosVanAscendente() {
        let deepseek = proveedor("deepseek", entrada: 0.1, salida: 0.2)
        let glm = proveedor("glm", entrada: 0.5, salida: 0.8)
        let sol = proveedor("sol", entrada: 2, salida: 8)

        let fuerte = Boost.proveedorFuerte(
            en: [sol, deepseek, glm],
            preferido: deepseek
        )
        XCTAssertEqual(fuerte?.nombre, "sol")

        let combos = Boost.combosDeAngulos(
            cantidad: 2,
            proveedores: [sol, glm, deepseek],
            fuerte: fuerte
        )
        XCTAssertEqual(combos.map(\.nombre), ["deepseek", "glm"])
    }

    func testSinCombosBaratosSeRepiteElFuerteEnVezDeDejarUnAnguloSinCorrer() {
        let sol = proveedor("sol", entrada: 2, salida: 8)

        let combos = Boost.combosDeAngulos(
            cantidad: 2,
            proveedores: [sol],
            fuerte: sol
        )
        XCTAssertEqual(combos.map(\.nombre), ["sol", "sol"])
    }

    func testTopeNilOCeroNoDetieneLaTuberia() {
        XCTAssertFalse(Boost.excedeTope(acumulado: 100, tope: nil))
        XCTAssertFalse(Boost.excedeTope(acumulado: 100, tope: 0))
        XCTAssertFalse(Boost.excedeTope(acumulado: 0.5, tope: 1))
        XCTAssertTrue(Boost.excedeTope(acumulado: 1, tope: 1))
    }
}
