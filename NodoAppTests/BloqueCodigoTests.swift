import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Suite de la partida B4-COD (bloques de codigo) en la capa de aplicacion.
///
/// POR QUE sobre `EstadoApp`: el paso bloqueante de la partida es que la
/// segmentacion real del ViewModel entregue bloques con su lenguaje y su crudo
/// exacto. Probar el parser aislado no demuestra que la proyeccion del hilo
/// los emita, ni que el boton [Copiar] entregue SOLO el crudo. El portapapeles
/// se inyecta como doble: nunca se toca el `UIPasteboard` del simulador.
/// Doble del portapapeles: guarda exactamente lo que el boton entrega.
final class PortapapelesDoble: Portapapeles {
    private(set) var textos: [String] = []

    func escribir(_ texto: String) {
        textos.append(texto)
    }
}

@MainActor
final class BloqueCodigoTests: XCTestCase {

    private static let codigoSwift = """
    func sumar(_ a: Int, _ b: Int) -> Int {
    \tlet total = a + b  // ñandú
    \treturn total
    }
    """

    private func respuestaConBloqueSwift() -> String {
        "Así queda:\n\n```swift\n\(Self.codigoSwift)\n```\n\nListo."
    }

    /// Envia una respuesta guionizada y devuelve la proyeccion del hilo.
    private func proyectar(
        _ respuesta: String,
        prompt: String = "Escribime una función en Swift que sume dos números enteros."
    ) async throws -> [ElementoHiloVisible] {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: respuesta,
            uso: UsoTokens(entrada: 40, salida: 20)
        )
        arnes.estado.enviar(prompt)
        try await arnes.esperarTurno()
        return arnes.estado.elementosVisiblesDelHilo()
    }

    // MARK: - COD.1: segmentacion y crudo exacto

    func testElBloqueSwiftLlevaSuLenguajeYElCrudoExacto() async throws {
        let elementos = try await proyectar(respuestaConBloqueSwift())

        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(
                    texto: "Escribime una función en Swift que sume dos números enteros."
                ),
                .burbujaAsistente(
                    segmentos: [
                        .texto("Así queda:"),
                        .codigo(
                            lenguaje: "swift",
                            textoCrudo: Self.codigoSwift
                        ),
                        .texto("Listo.")
                    ]
                )
            ]
        )

        guard case .burbujaAsistente(let segmentos) = elementos[1],
              case .codigo(let lenguaje, let crudo) = segmentos[1] else {
            return XCTFail("La respuesta no proyecto su bloque de codigo")
        }
        XCTAssertEqual(lenguaje, "swift")
        XCTAssertEqual(crudo, Self.codigoSwift)
        XCTAssertFalse(crudo.contains("```"))
        XCTAssertFalse(crudo.contains("swift"))
    }

    func testDosBloquesSonDosElementosIndependientes() async throws {
        let respuesta = """
        ```swift
        let a = 1
        ```

        Entre bloques.

        ```python
        print(2)
        ```
        """
        let elementos = try await proyectar(respuesta)

        guard case .burbujaAsistente(let segmentos) = elementos[1] else {
            return XCTFail("Falta la burbuja del asistente")
        }
        XCTAssertEqual(
            segmentos,
            [
                .codigo(lenguaje: "swift", textoCrudo: "let a = 1"),
                .texto("Entre bloques."),
                .codigo(lenguaje: "python", textoCrudo: "print(2)")
            ]
        )
    }

    func testElBloqueSinLenguajeUsaLaCabeceraCodigo() async throws {
        let elementos = try await proyectar("```\nlet x = 1\n```")

        guard case .burbujaAsistente(let segmentos) = elementos[1],
              case .codigo(let lenguaje, let crudo) = segmentos[0] else {
            return XCTFail("Falta el bloque sin lenguaje")
        }
        XCTAssertNil(lenguaje)
        XCTAssertEqual(crudo, "let x = 1")
        XCTAssertEqual(BloqueCodigo.tituloCabecera(lenguaje), "Código")
    }

    func testElCodigoEnLineaNoGeneraBloque() async throws {
        let respuesta = "Usá `sumar(1, 2)` y listo."
        let elementos = try await proyectar(respuesta)

        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(
                    texto: "Escribime una función en Swift que sume dos números enteros."
                ),
                .burbujaAsistente(segmentos: [.texto(respuesta)])
            ],
            "El codigo en linea sigue siendo texto: nunca produce un bloque"
        )
    }

    // MARK: - COD.2: copiado exacto y confirmacion

    func testElBotonCopiaSoloElCrudoYConfirmaCopiado() async throws {
        let doble = PortapapelesDoble()
        let copiador = CopiadorCodigo(
            textoCrudo: Self.codigoSwift,
            portapapeles: doble,
            duracionConfirmacion: 0.05
        )

        XCTAssertFalse(copiador.copiado)
        copiador.copiar()

        XCTAssertEqual(doble.textos, [Self.codigoSwift])
        XCTAssertTrue(copiador.copiado)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(
            copiador.copiado,
            "La confirmacion «Copiado» tiene que volver sola a «Copiar»"
        )
    }

    func testUnToqueNuevoMantieneLaConfirmacion() async throws {
        let doble = PortapapelesDoble()
        let copiador = CopiadorCodigo(
            textoCrudo: "let x = 1",
            portapapeles: doble,
            duracionConfirmacion: 0.4
        )

        copiador.copiar()
        try await Task.sleep(nanoseconds: 250_000_000)
        copiador.copiar()

        // La confirmacion vieja ya vencio, pero la nueva sigue viva.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(copiador.copiado)
        XCTAssertEqual(doble.textos, ["let x = 1", "let x = 1"])

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(copiador.copiado)
    }

    // MARK: - Cabecera y resaltado

    func testLaCabeceraNormalizaSoloLaVista() {
        XCTAssertEqual(BloqueCodigo.tituloCabecera("swift"), "Swift")
        XCTAssertEqual(BloqueCodigo.tituloCabecera("Python"), "Python")
        XCTAssertEqual(BloqueCodigo.tituloCabecera("py"), "Python")
        XCTAssertEqual(BloqueCodigo.tituloCabecera("js"), "JavaScript")
        XCTAssertEqual(BloqueCodigo.tituloCabecera("rust"), "Rust")
        XCTAssertEqual(BloqueCodigo.tituloCabecera(nil), "Código")
        XCTAssertEqual(BloqueCodigo.tituloCabecera("  "), "Código")
    }

    func testElResaltadoNoCambiaUnSoloCaracter() {
        for lenguaje in ["swift", "python", "rust", nil] {
            let atribuido = ResaltadoCodigo.atribuido(
                Self.codigoSwift,
                lenguaje: lenguaje
            )
            XCTAssertEqual(
                String(atribuido.characters),
                Self.codigoSwift,
                "Colorear (\(lenguaje ?? "nil")) no puede alterar el texto"
            )
        }
    }
}
