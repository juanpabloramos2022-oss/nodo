import Foundation
import XCTest

@testable import NodoCore

/// Pruebas de la consulta de busqueda del historial (B4-BUS, BUS.1).
///
/// POR QUE viven en el nucleo: la busqueda es una consulta de SOLO LECTURA
/// sobre las conversaciones ya cargadas. Si el filtro viviera en la vista no
/// habria forma de probar que no muta nada, que no usa expresiones regulares y
/// que con el campo vacio la lista es exactamente la de siempre. Aqui se fija
/// el comportamiento con un almacen de prueba de tres conversaciones.
final class BusquedaHistorialTests: XCTestCase {

    // MARK: - Almacen de prueba (3 conversaciones)

    /// Una conversacion cuyo TITULO contiene la palabra clave.
    private static func soloEnTitulo() -> Conversation {
        Conversation(
            titulo: "Zafiro y oro",
            mensajes: [
                ChatMessage(
                    rol: .usuario,
                    texto: "Hablemos de joyas",
                    fecha: Date(timeIntervalSince1970: 100)
                )
            ],
            creada: Date(timeIntervalSince1970: 100),
            actualizada: Date(timeIntervalSince1970: 100)
        )
    }

    /// Una conversacion cuyo TEXTO de mensaje contiene la palabra clave.
    private static func soloEnMensaje() -> Conversation {
        Conversation(
            titulo: "Notas del taller",
            mensajes: [
                ChatMessage(
                    rol: .usuario,
                    texto: "La piedra zafiro brilla",
                    fecha: Date(timeIntervalSince1970: 200)
                ),
                ChatMessage(
                    rol: .asistente,
                    texto: "Queda anotado",
                    fecha: Date(timeIntervalSince1970: 200)
                )
            ],
            creada: Date(timeIntervalSince1970: 200),
            actualizada: Date(timeIntervalSince1970: 200)
        )
    }

    /// Una conversacion que no contiene la palabra clave por ningun lado.
    private static func sinLaPalabra() -> Conversation {
        Conversation(
            titulo: "Recetas",
            mensajes: [
                ChatMessage(
                    rol: .usuario,
                    texto: "Hablemos de sopas",
                    fecha: Date(timeIntervalSince1970: 300)
                )
            ],
            creada: Date(timeIntervalSince1970: 300),
            actualizada: Date(timeIntervalSince1970: 300)
        )
    }

    /// Las tres, en el orden de "lista completa de siempre": actividad reciente
    /// primero (Recetas, Notas, Zafiro).
    private static func almacen() -> [Conversation] {
        [soloEnTitulo(), soloEnMensaje(), sinLaPalabra()]
    }

    // MARK: - (1) Coincidencia por titulo y por texto

    func testZafiroDevuelveExactamenteLasDosQueLoTienen() {
        let encontradas = HistorialConversaciones.buscar(
            Self.almacen(),
            termino: "ZAFIRO"
        )

        XCTAssertEqual(
            encontradas.map(\.titulo),
            ["Notas del taller", "Zafiro y oro"],
            "Solo las dos que contienen la palabra, en el orden de la lista"
        )
        XCTAssertEqual(encontradas.count, 2)
    }

    func testLaComparacionIgnoraMayusculasYacentos() {
        let almacen = Self.almacen()

        for termino in ["zafiro", "ZAFIRO", "ZáfIrO", "ZÁFIRO"] {
            XCTAssertEqual(
                HistorialConversaciones.buscar(almacen, termino: termino)
                    .map(\.titulo),
                ["Notas del taller", "Zafiro y oro"],
                termino
            )
        }
    }

    func testUnTextoAusenteNoDevuelveNinguna() {
        XCTAssertTrue(
            HistorialConversaciones.buscar(
                Self.almacen(),
                termino: "esmeralda"
            ).isEmpty
        )
    }

    // MARK: - (2) Contencion literal, sin expresiones regulares

    func testLaBusquedaNoInterpretaExpresionesRegulares() {
        let almacen = Self.almacen()

        // Un patron que, como regex, casaria con cualquier texto: si la
        // busqueda lo interpretara, devolveria las tres.
        XCTAssertTrue(
            HistorialConversaciones.buscar(almacen, termino: ".*").isEmpty,
            "La busqueda es contencion literal: `.*` no casa con nada"
        )
        XCTAssertTrue(
            HistorialConversaciones.buscar(almacen, termino: "zaf.ro").isEmpty,
            "Un punto es un punto literal, no un comodin"
        )
        XCTAssertEqual(
            HistorialConversaciones.buscar(almacen, termino: "zafi").count,
            2,
            "La contencion literal si encuentra el prefijo escrito"
        )
    }

    // MARK: - (3) Campo vacio = lista completa de siempre

    func testElTerminoVacioDevuelveLasTresEnSuOrdenOriginal() {
        let almacen = Self.almacen()

        XCTAssertEqual(
            HistorialConversaciones.buscar(almacen, termino: "").map(\.titulo),
            ["Recetas", "Notas del taller", "Zafiro y oro"],
            "Sin busqueda no falta ninguna ni cambia el orden habitual"
        )
        XCTAssertEqual(
            HistorialConversaciones.buscar(almacen, termino: "   ").count,
            3,
            "Espacios en blanco cuentan como campo vacio"
        )
    }

    func testElOrdenMantieneLasFijadasPrimero() {
        // La fijada es la MAS VIEJA: si el orden se perdiera, quedaria ultima.
        var fijada = Self.soloEnTitulo()
        fijada.fijada = true

        let almacen = [fijada, Self.soloEnMensaje(), Self.sinLaPalabra()]

        XCTAssertEqual(
            HistorialConversaciones.buscar(almacen, termino: "").map(\.titulo),
            ["Zafiro y oro", "Recetas", "Notas del taller"]
        )
    }

    // MARK: - (4) Segmento

    func testElSegmentoNoMezclaActivosConArchivados() {
        var archivada = Self.soloEnMensaje()
        archivada.archivada = true

        let almacen = [Self.soloEnTitulo(), archivada, Self.sinLaPalabra()]

        XCTAssertEqual(
            HistorialConversaciones.buscar(
                almacen,
                termino: "zafiro",
                segmento: .activos
            ).map(\.titulo),
            ["Zafiro y oro"]
        )
        XCTAssertEqual(
            HistorialConversaciones.buscar(
                almacen,
                termino: "zafiro",
                segmento: .archivados
            ).map(\.titulo),
            ["Notas del taller"]
        )
        XCTAssertEqual(
            HistorialConversaciones.buscar(
                almacen,
                termino: "zafiro",
                segmento: nil
            ).count,
            2,
            "Sin segmento la consulta mira los dos"
        )
    }

    // MARK: - (5) Solo lectura

    func testBuscarNoMutaLaListaRecibida() {
        let original = Self.almacen()
        let copia = original

        _ = HistorialConversaciones.buscar(original, termino: "zafiro")
        _ = HistorialConversaciones.buscar(original, termino: "")
        _ = HistorialConversaciones.buscar(original, termino: "esmeralda")

        XCTAssertEqual(
            original,
            copia,
            "Filtrar no cambia titulos, mensajes, orden ni fechas"
        )
    }
}
