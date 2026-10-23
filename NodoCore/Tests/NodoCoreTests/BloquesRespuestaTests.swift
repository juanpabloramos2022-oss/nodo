import XCTest

@testable import NodoCore

final class BloquesRespuestaTests: XCTestCase {
    func testSinCercosDevuelveUnSoloBloqueDeTexto() {
        XCTAssertEqual(
            BloquesRespuesta.parsear("Hola mundo"),
            [.texto("Hola mundo")]
        )
    }

    func testTextoVacioDevuelveListaVacia() {
        XCTAssertEqual(BloquesRespuesta.parsear(""), [])
    }

    func testCodigoSinLenguaje() {
        let texto = """
        ```
        let x = 1
        ```
        """

        XCTAssertEqual(
            BloquesRespuesta.parsear(texto),
            [.codigo(lenguaje: nil, contenido: "let x = 1")]
        )
    }

    func testCodigoConLenguaje() {
        let texto = """
        ```swift
        let x = 1
        ```
        """

        XCTAssertEqual(
            BloquesRespuesta.parsear(texto),
            [.codigo(lenguaje: "swift", contenido: "let x = 1")]
        )
    }

    func testTextoAntesYDespuesDelCodigo() {
        let texto = """
        Antes
        ```swift
        let x = 1
        ```
        Despues
        """

        XCTAssertEqual(
            BloquesRespuesta.parsear(texto),
            [
                .texto("Antes"),
                .codigo(lenguaje: "swift", contenido: "let x = 1"),
                .texto("Despues")
            ]
        )
    }

    func testCercoSinCerrarTodoLoQueSigueEsCodigo() {
        let texto = """
        Antes
        ```swift
        let x = 1
        let y = 2
        """

        XCTAssertEqual(
            BloquesRespuesta.parsear(texto),
            [
                .texto("Antes"),
                .codigo(lenguaje: "swift", contenido: "let x = 1\nlet y = 2")
            ]
        )
    }

    func testLasLineasVaciasInternasDelCodigoSeConservan() {
        let texto = """
        ```
        uno

        dos
        ```
        """

        XCTAssertEqual(
            BloquesRespuesta.parsear(texto),
            [.codigo(lenguaje: nil, contenido: "uno\n\ndos")]
        )
    }

    func testElTextoSeRecortaDeSaltosEnLosBordes() {
        let texto = """

        Antes

        ```
        codigo
        ```

        Despues

        """

        XCTAssertEqual(
            BloquesRespuesta.parsear(texto),
            [
                .texto("Antes"),
                .codigo(lenguaje: nil, contenido: "codigo"),
                .texto("Despues")
            ]
        )
    }
}
