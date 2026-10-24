import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// H6.3: la hoja del boton 🧠 (Memoria rapida) expone la Memoria como LISTA de
/// entradas, una por cada una, en vez de un unico texto pegado.
///
/// La prueba mira el modelo que alimenta a la vista (`MemoriaRapidaModelo`):
/// renderizar SwiftUI en un test unitario no es posible sin anadir dependencias,
/// pero la garantia que importa —una fila por entrada— si queda cubierta.
@MainActor
final class MemoriaRapidaTests: XCTestCase {

    func testConTresEntradasSembradasLaHojaExponeLasTres() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let entradas = [
            EntradaMemoria(texto: "Prefiere respuestas breves."),
            EntradaMemoria(texto: "Trabaja en Madrid."),
            EntradaMemoria(texto: "Usa Swift a diario.")
        ]
        arnes.estado.config.memoria = entradas

        let modelo = MemoriaRapidaModelo(memoria: arnes.estado.config.memoria)

        XCTAssertEqual(modelo.filas.count, 3)
        XCTAssertEqual(
            Set(modelo.filas.map(\.id)),
            Set(entradas.map(\.id)),
            "Cada fila debe conservar la identidad de su entrada"
        )
        XCTAssertEqual(
            Set(modelo.filas.map(\.texto)),
            Set(entradas.map(\.texto)),
            "Cada entrada tiene que quedar como una fila independiente, sin pegarse en un texto unico"
        )
    }

    /// Abrir (preparar) la hoja no toca la Memoria ni el hilo del chat: es una
    /// lista de consulta y los cambios solo los confirma su editor.
    func testLaListaDeLaHojaNoTocaLaMemoriaNiElChat() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let entradas = [
            EntradaMemoria(texto: "Uno"),
            EntradaMemoria(texto: "Dos"),
            EntradaMemoria(texto: "Tres")
        ]
        arnes.estado.config.memoria = entradas
        let mensajesAntes = arnes.estado.conversacion.mensajes.count

        _ = MemoriaRapidaModelo(memoria: arnes.estado.config.memoria)

        XCTAssertEqual(arnes.estado.config.memoria, entradas)
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, mensajesAntes)
    }
}