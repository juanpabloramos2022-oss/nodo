import XCTest

@testable import NodoCore

/// Prueba minima de la cadena de compilacion.
///
/// No comprueba logica de negocio: comprueba que el paquete se compila y que
/// `swift test` corre. Si esto falla, el problema esta en el entorno, no en el
/// codigo.
final class NodoVersionTests: XCTestCase {
    func testDescripcionIncluyeLaVersion() {
        XCTAssertEqual(NodoVersion.descripcion, "Nodo v0.3.1")
    }

    func testVersionYBuildNoEstanVacios() {
        XCTAssertEqual(NodoVersion.version, "0.3.1")
        XCTAssertEqual(NodoVersion.build, "5")
    }
}
