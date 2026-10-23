import XCTest

@testable import NodoCore

final class NombresLimpiosModeloTests: XCTestCase {
    func testIdentificadorConBarraRecortaElPrefijo() {
        XCTAssertEqual(NombresLimpios.modelo("vendedor/modelo"), "modelo")
        XCTAssertEqual(NombresLimpios.modelo("combo/deepseek-v4-1-flash"), "deepseek-v4-1-flash")
    }

    func testIdentificadorSinBarraSeQuedaIgual() {
        XCTAssertEqual(NombresLimpios.modelo("deepseek-chat"), "deepseek-chat")
        XCTAssertEqual(NombresLimpios.modelo("  gpt-6-astra  "), "gpt-6-astra")
    }

    func testElApodoMandaSobreElIdentificador() {
        XCTAssertEqual(
            NombresLimpios.modelo("vendedor/modelo", apodo: "Rapido"),
            "Rapido"
        )
        XCTAssertEqual(
            NombresLimpios.modelo("vendedor/modelo", apodo: "  Rapido  "),
            "Rapido"
        )
    }

    func testUnApodoVacioNoPisaElIdentificador() {
        XCTAssertEqual(NombresLimpios.modelo("vendedor/modelo", apodo: "   "), "modelo")
    }

    func testIdentificadorVacioDevuelveVacio() {
        XCTAssertEqual(NombresLimpios.modelo(""), "")
        XCTAssertEqual(NombresLimpios.modelo("   "), "")
        XCTAssertEqual(NombresLimpios.modelo("", apodo: ""), "")
    }
}

final class NombresLimpiosProveedorTests: XCTestCase {
    func testUnNombrePropioNoSeToca() {
        XCTAssertEqual(
            NombresLimpios.proveedor(nombre: "Mi Proveedor", baseURL: "https://api.inferhub.dev/v1"),
            "Mi Proveedor"
        )
    }

    func testCompatibleDerivaDelDominio() {
        XCTAssertEqual(
            NombresLimpios.proveedor(nombre: "Compatible", baseURL: "https://api.inferhub.dev/v1"),
            "Inferhub"
        )
        XCTAssertEqual(
            NombresLimpios.proveedor(nombre: "compatible", baseURL: "https://api.deepseek.com/v1"),
            "Deepseek"
        )
    }

    func testNombreVacioDerivaDelDominio() {
        XCTAssertEqual(
            NombresLimpios.proveedor(nombre: "   ", baseURL: "https://api.inferhub.dev/v1"),
            "Inferhub"
        )
    }

    func testSinDominioUtilizableDevuelveElRespaldo() {
        XCTAssertEqual(
            NombresLimpios.proveedor(nombre: "Compatible", baseURL: "esto no es una url"),
            "Compatible"
        )
        XCTAssertEqual(
            NombresLimpios.proveedor(nombre: "", baseURL: ""),
            "Proveedor"
        )
    }
}
