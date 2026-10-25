import XCTest

@testable import NodoCore

/// Borradores del composer por hilo (IDEA6).
///
/// La prueba es pura: no presenta UI ni toca disco. Cada caso usa ids propios
/// para que un borrador de un hilo no pueda aparecer en otro.
final class BorradoresDeHiloTests: XCTestCase {
    func testCadaHiloTieneSuPropioBorrador() {
        var almacen = BorradoresDeHilo()
        let hiloA = UUID()
        let hiloB = UUID()

        almacen.guardar("texto del hilo A", para: hiloA)
        almacen.guardar("texto del hilo B", para: hiloB)

        XCTAssertEqual(almacen.texto(para: hiloA), "texto del hilo A")
        XCTAssertEqual(almacen.texto(para: hiloB), "texto del hilo B")
        XCTAssertEqual(almacen.cantidad, 2)
    }

    func testUnHiloSinBorradorDevuelveNil() {
        let almacen = BorradoresDeHilo()
        XCTAssertNil(almacen.texto(para: UUID()))
        XCTAssertEqual(almacen.cantidad, 0)
    }

    func testElTextoSeGuardaExactoTalCual() {
        var almacen = BorradoresDeHilo()
        let hilo = UUID()
        let texto = "  línea 1\nlínea 2 con \"comillas\" y \\barra  "

        almacen.guardar(texto, para: hilo)

        XCTAssertEqual(almacen.texto(para: hilo), texto)
    }

    func testGuardarVacioBorraLaEntrada() {
        var almacen = BorradoresDeHilo()
        let hilo = UUID()

        almacen.guardar("algo", para: hilo)
        almacen.guardar("", para: hilo)

        XCTAssertNil(almacen.texto(para: hilo))
        XCTAssertEqual(almacen.cantidad, 0)
    }

    func testBorrarEsIdempotenteYNoTocaOtrosHilos() {
        var almacen = BorradoresDeHilo()
        let hiloA = UUID()
        let hiloB = UUID()
        almacen.guardar("A", para: hiloA)
        almacen.guardar("B", para: hiloB)

        almacen.borrar(para: hiloA)
        almacen.borrar(para: hiloA)

        XCTAssertNil(almacen.texto(para: hiloA))
        XCTAssertEqual(almacen.texto(para: hiloB), "B")
        XCTAssertEqual(almacen.cantidad, 1)
    }

    func testElJsonConservaLosBorradoresYSuHilo() throws {
        var almacen = BorradoresDeHilo()
        let hiloA = UUID()
        let hiloB = UUID()
        almacen.guardar("uno", para: hiloA)
        almacen.guardar("dos", para: hiloB)

        let recuperado = try BorradoresDeHilo.desde(json: almacen.json())

        XCTAssertEqual(recuperado, almacen)
        XCTAssertEqual(recuperado.texto(para: hiloA), "uno")
        XCTAssertEqual(recuperado.texto(para: hiloB), "dos")
    }

    func testUnJsonCorruptoNoRompeElAlmacen() {
        let datos = Data("no es json".utf8)

        XCTAssertThrowsError(try BorradoresDeHilo.desde(json: datos))
    }
}
