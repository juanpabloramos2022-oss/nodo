import XCTest

@testable import NodoCore

/// Suite del tokenizador del resaltado (B4-COD, nivel 1).
///
/// POR QUE sin SwiftUI: el resaltado es presentacion, pero la tokenizacion es
/// pura. Estos tests fijan que (a) cada clase de token se reconoce, (b) un
/// lenguaje desconocido no se tokeniza y (c) recomponer los tokens devuelve,
/// caracter por caracter, el crudo de entrada: colorear nunca cambia el texto
/// que se copia o se selecciona.
final class TokenizadorCodigoTests: XCTestCase {

    private func clases(
        _ tokens: [TokenCodigo]?,
        _ clase: ClaseTokenCodigo
    ) -> [String] {
        (tokens ?? []).filter { $0.clase == clase }.map(\.texto)
    }

    func testSwiftReconocePalabraClaveCadenaNumeroYComentario() throws {
        let crudo = """
        func sumar(_ a: Int, _ b: Int) -> Int {
            let saludo = "hola \\"mundo\\""
            // suma de enteros
            return a + b + 42
        }
        """

        let tokens = try XCTUnwrap(
            TokenizadorCodigo.tokens(textoCrudo: crudo, lenguaje: "swift")
        )

        XCTAssertEqual(
            clases(tokens, .palabraClave),
            ["func", "let", "return"]
        )
        XCTAssertEqual(
            clases(tokens, .cadena),
            ["\"hola \\\"mundo\\\"\""]
        )
        XCTAssertEqual(clases(tokens, .numero), ["42"])
        XCTAssertEqual(clases(tokens, .comentario), ["// suma de enteros"])
        XCTAssertEqual(tokens.map(\.texto).joined(), crudo)
    }

    func testPythonReconocePalabraClaveCadenaNumeroYComentario() throws {
        let crudo = """
        def sumar(a: int, b: int) -> int:
            \"\"\"Devuelve la suma.\"\"\"
            # comentario de linea
            return a + b + 8
        """

        let tokens = try XCTUnwrap(
            TokenizadorCodigo.tokens(textoCrudo: crudo, lenguaje: "python")
        )

        XCTAssertEqual(clases(tokens, .palabraClave), ["def", "return"])
        XCTAssertEqual(clases(tokens, .cadena), ["\"\"\"Devuelve la suma.\"\"\""])
        XCTAssertEqual(clases(tokens, .numero), ["8"])
        XCTAssertEqual(clases(tokens, .comentario), ["# comentario de linea"])
        XCTAssertEqual(tokens.map(\.texto).joined(), crudo)
    }

    func testLaRecomposicionEsIdenticaAlCrudoConAcentosYTabs() throws {
        let crudo = "let ñandú = \"café\"\n\t// nota: 3\n\treturn 0"

        for lenguaje in ["swift", "Swift", "SWIFT"] {
            let tokens = try XCTUnwrap(
                TokenizadorCodigo.tokens(
                    textoCrudo: crudo,
                    lenguaje: lenguaje
                )
            )
            XCTAssertEqual(
                tokens.map(\.texto).joined(),
                crudo,
                "El resaltado no puede cambiar un solo caracter"
            )
        }
    }

    func testLenguajeDesconocidoNoSeTokeniza() {
        XCTAssertNil(
            TokenizadorCodigo.tokens(
                textoCrudo: "print(1)",
                lenguaje: "rust"
            )
        )
        XCTAssertNil(
            TokenizadorCodigo.tokens(textoCrudo: "print(1)", lenguaje: nil)
        )
        XCTAssertNil(
            TokenizadorCodigo.tokens(textoCrudo: "print(1)", lenguaje: "  ")
        )
        XCTAssertFalse(TokenizadorCodigo.reconoce("rust"))
        XCTAssertTrue(TokenizadorCodigo.reconoce("py"))
        XCTAssertTrue(TokenizadorCodigo.reconoce("Python"))
    }

    func testCrudoVacioDevuelveListaVacia() {
        XCTAssertEqual(
            TokenizadorCodigo.tokens(textoCrudo: "", lenguaje: "swift")?.count,
            0
        )
    }

    func testUnaCadenaNoSeConfundeConUnComentario() throws {
        let crudo = "let url = \"https://example.com/a#b\" // real"

        let tokens = try XCTUnwrap(
            TokenizadorCodigo.tokens(textoCrudo: crudo, lenguaje: "swift")
        )

        XCTAssertEqual(
            clases(tokens, .cadena),
            ["\"https://example.com/a#b\""]
        )
        XCTAssertEqual(clases(tokens, .comentario), ["// real"])
        XCTAssertEqual(tokens.map(\.texto).joined(), crudo)
    }
}
