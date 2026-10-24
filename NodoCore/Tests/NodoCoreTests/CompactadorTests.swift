import XCTest

@testable import NodoCore

final class CompactadorTests: XCTestCase {
    /// Ocho mensajes con marcas distintas: los dos primeros son el prefijo que
    /// se resume y los seis ultimos los que deben sobrevivir intactos.
    private func historiaDeOcho() -> [ChatMessage] {
        (0..<8).map { indice in
            ChatMessage(
                rol: indice.isMultiple(of: 2) ? .usuario : .asistente,
                texto: (indice < 2 ? "ANTIGUO \(indice)" : "CONSERVADO \(indice)")
                    + " " + String(repeating: "x", count: 40)
            )
        }
    }

    func testResumirRecibeSoloElPrefijoAntiguo() async throws {
        let mensajes = historiaDeOcho()
        var entradas: [String] = []

        let resultado = try await Compactador.compactar(
            mensajes: mensajes
        ) { entrada in
            entradas.append(entrada)
            return "resumen corto"
        }

        // Una sola llamada: la compactacion ya no encadena pasadas.
        XCTAssertEqual(entradas.count, 1)
        let entrada = try XCTUnwrap(entradas.first)
        XCTAssertTrue(entrada.contains("ANTIGUO 0"))
        XCTAssertTrue(entrada.contains("ANTIGUO 1"))
        for indice in 2..<8 {
            XCTAssertFalse(
                entrada.contains("CONSERVADO \(indice)"),
                "El resumidor no puede recibir el mensaje conservado \(indice)"
            )
        }

        XCTAssertTrue(resultado.aplicada)
        XCTAssertEqual(resultado.resumen, "resumen corto")
        XCTAssertEqual(resultado.mensajes, Array(mensajes.suffix(6)))
        XCTAssertEqual(
            resultado.mensajes.map(\.id),
            Array(mensajes.suffix(6).map(\.id))
        )
    }

    func testNoAplicaLoQueNoReduce() async throws {
        let mensajes = historiaDeOcho()
        let contextoOriginal = Compactador.estimarContexto(mensajes: mensajes)
        var llamadas = 0

        let resultado = try await Compactador.compactar(
            mensajes: mensajes
        ) { _ in
            llamadas += 1
            // Un resumen mas largo que todo lo resumido: no comprime nada.
            return String(repeating: "z", count: 4_000)
        }

        XCTAssertEqual(llamadas, 1)
        XCTAssertFalse(resultado.aplicada)
        XCTAssertNil(resultado.resumen)
        XCTAssertNotNil(resultado.resumenGenerado)
        XCTAssertEqual(
            resultado.mensajes,
            mensajes,
            "Si no se aplica, se conservan todos los mensajes"
        )
        XCTAssertEqual(resultado.contextoOriginal, contextoOriginal)
        XCTAssertGreaterThanOrEqual(
            resultado.contextoEstimado,
            contextoOriginal,
            "El resumen propuesto no reduce el contexto"
        )
    }

    func testConSeisMensajesNoLlamaAlResumidor() async throws {
        let mensajes = Array(historiaDeOcho().suffix(6))
        var llamadas = 0

        let resultado = try await Compactador.compactar(
            mensajes: mensajes
        ) { _ in
            llamadas += 1
            return "no deberia pedirse"
        }

        XCTAssertEqual(llamadas, 0)
        XCTAssertFalse(resultado.aplicada)
        XCTAssertNil(resultado.resumen)
        XCTAssertEqual(resultado.mensajes, mensajes)
    }
}
