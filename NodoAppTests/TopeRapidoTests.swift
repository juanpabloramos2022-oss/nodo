import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// H6.4: los chips de tope de gasto de Mi Contexto fijan el tope en el estado
/// sin pasar por el teclado numerico.
///
/// La prueba usa la misma lista que pinta los chips (`TopesRapidos.valores`) y
/// la misma puerta que dispara su toque (`fijarTopeAviso`), de modo que un
/// escalon nuevo queda cubierto sin tocar la prueba.
@MainActor
final class TopeRapidoTests: XCTestCase {

    func testLaListaDeChipsTieneValoresPositivos() {
        XCTAssertFalse(TopesRapidos.valores.isEmpty)
        XCTAssertTrue(
            TopesRapidos.valores.allSatisfy { $0 > 0 },
            "Un chip en cero desactivaria el aviso; los rapidos deben ser positivos"
        )
    }

    func testCadaChipRapidoFijaElTopeEnElEstadoYPersiste() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        for valor in TopesRapidos.valores {
            arnes.estado.fijarTopeAviso(valor)

            XCTAssertEqual(arnes.estado.config.topeAvisoCosto, valor)
            XCTAssertEqual(arnes.estado.config.topeAvisoCostoEfectivo, valor)
        }

        // El ultimo chip quedo persistido en las preferencias.
        let datos = try XCTUnwrap(arnes.defaults.data(forKey: "nodo.config.v1"))
        let releida = try AppConfig.desde(json: datos)
        XCTAssertEqual(
            releida.topeAvisoCosto,
            TopesRapidos.valores.last
        )
    }
}