import XCTest

@testable import NodoCore

final class PoliticaAprobacionTests: XCTestCase {
    func testTodaHerramientaMCPPideAprobacion() {
        XCTAssertTrue(
            PoliticaAprobacion.requiereAprobacion(
                esMCP: true,
                metodoHTTP: nil,
                nombreHerramienta: "crear_nota",
                exentas: []
            )
        )
    }

    func testHTTPGetNoPideAprobacion() {
        XCTAssertFalse(
            PoliticaAprobacion.requiereAprobacion(
                esMCP: false,
                metodoHTTP: "GET",
                nombreHerramienta: "traer_url",
                exentas: []
            )
        )
    }

    func testHTTPGetEnMinusculasTampocoPideAprobacion() {
        XCTAssertFalse(
            PoliticaAprobacion.requiereAprobacion(
                esMCP: false,
                metodoHTTP: "get",
                nombreHerramienta: "traer_url",
                exentas: []
            )
        )
    }

    func testHTTPPostPideAprobacion() {
        XCTAssertTrue(
            PoliticaAprobacion.requiereAprobacion(
                esMCP: false,
                metodoHTTP: "POST",
                nombreHerramienta: "enviar_datos",
                exentas: []
            )
        )
    }

    func testLaListaDeExentasGanaInclusoSiEsMCP() {
        XCTAssertFalse(
            PoliticaAprobacion.requiereAprobacion(
                esMCP: true,
                metodoHTTP: nil,
                nombreHerramienta: "crear_nota",
                exentas: ["crear_nota"]
            )
        )
    }

    func testUnaHerramientaDesconocidaPideAprobacion() {
        XCTAssertTrue(
            PoliticaAprobacion.requiereAprobacion(
                esMCP: false,
                metodoHTTP: nil,
                nombreHerramienta: "rara",
                exentas: []
            )
        )
    }
}
