import XCTest

@testable import NodoCore

final class CompactadorTests: XCTestCase {
    /// Historia de 14 mensajes con texto suficiente para que el presupuesto
    /// importe. Los ultimos 6 son los que deben sobrevivir.
    private func historia(cantidad: Int = 14) -> [ChatMessage] {
        (0..<cantidad).map { indice in
            ChatMessage(
                rol: indice.isMultiple(of: 2) ? .usuario : .asistente,
                texto: "mensaje \(indice) " + String(repeating: "x", count: 40)
            )
        }
    }

    func testDosPasadasCuandoLaPrimeraNoBasta() async throws {
        let mensajes = historia()
        let ultimos = Array(mensajes.suffix(6))
        var llamadas: [String] = []

        let resultado = try await Compactador.resumirEnCadena(
            mensajes: mensajes,
            presupuesto: 100
        ) { entrada in
            llamadas.append(entrada)
            if llamadas.count == 1 {
                // La primera pasada deja el contexto muy por encima: obliga a
                // encadenar una segunda.
                return String(repeating: "a", count: 2_000)
            }
            return "resumen corto"
        }

        XCTAssertEqual(llamadas.count, 2)
        XCTAssertEqual(resultado.pasadas, 2)
        XCTAssertEqual(resultado.resumen, "resumen corto")
        XCTAssertEqual(resultado.mensajes, ultimos)
        XCTAssertFalse(resultado.conservoUltimos)
        XCTAssertFalse(resultado.excedePresupuesto)
        XCTAssertTrue(llamadas[0].contains("mensaje 0"))
        XCTAssertTrue(
            llamadas[1].contains(String(repeating: "a", count: 2_000)),
            "La segunda pasada resume sobre el resultado de la primera"
        )
    }

    func testTopeDeTresPasadas() async throws {
        var llamadas = 0

        let resultado = try await Compactador.resumirEnCadena(
            mensajes: historia(),
            presupuesto: 100
        ) { _ in
            llamadas += 1
            // Nunca cabe: no importa cuantas veces se resuma.
            return String(repeating: "z", count: 4_000)
        }

        XCTAssertEqual(llamadas, Compactador.maxPasadas)
        XCTAssertEqual(llamadas, 3)
        XCTAssertEqual(resultado.pasadas, 3)
        XCTAssertTrue(resultado.conservoUltimos)
        XCTAssertNil(resultado.resumen)
        XCTAssertNotNil(resultado.ultimoResumen)
    }

    func testConservaLosUltimosSeisYLoDeclara() async throws {
        let mensajes = historia()
        let ultimos = Array(mensajes.suffix(6))

        let resultado = try await Compactador.resumirEnCadena(
            mensajes: mensajes,
            presupuesto: 100
        ) { _ in String(repeating: "z", count: 4_000) }

        XCTAssertEqual(resultado.mensajes.count, 6)
        XCTAssertEqual(resultado.mensajes.map(\.id), ultimos.map(\.id))
        XCTAssertTrue(resultado.conservoUltimos)
        XCTAssertEqual(
            resultado.contextoEstimado,
            Compactador.estimarContexto(mensajes: resultado.mensajes)
        )
    }

    func testSinPresupuestoHaceUnaSolaPasada() async throws {
        var llamadas = 0

        let resultado = try await Compactador.resumirEnCadena(
            mensajes: historia(),
            presupuesto: nil
        ) { _ in
            llamadas += 1
            return "resumen"
        }

        XCTAssertEqual(llamadas, 1)
        XCTAssertEqual(resultado.pasadas, 1)
        XCTAssertEqual(resultado.resumen, "resumen")
        XCTAssertFalse(resultado.conservoUltimos)
    }
}
