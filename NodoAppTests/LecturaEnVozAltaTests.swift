import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la lectura en voz alta de una respuesta terminada (IDEA1).
///
/// POR QUE sin audio: el constructor de locuciones es puro y `EstadoApp` habla
/// con el protocolo `LectorEnVozAlta`, nunca con `AVSpeechSynthesizer`. El
/// doble `LectorGuionizado` registra locuciones y llamadas, de modo que estos
/// tests prueban los estados, los cortes y la invariante negativa (0 caracteres
/// de codigo y 0 cercas en lo que se dice) sin simulador ni hardware.
@MainActor
final class LecturaEnVozAltaTests: XCTestCase {

    // MARK: - Guion literal

    private static let prosaAntes =
        "La función recibe dos números enteros, los suma y devuelve el resultado."
    private static let prosaDespues =
        "El bloque anterior es la implementación completa; el texto que sigue "
        + "es prosa normal."
    private static let codigoSwift =
        "func sumar(_ a: Int, _ b: Int) -> Int { a + b }"

    private static let respuestaMixta = #"""
    La función recibe dos números enteros, los suma y devuelve el resultado.

    ```swift
    func sumar(_ a: Int, _ b: Int) -> Int { a + b }
    ```

    El bloque anterior es la implementación completa; el texto que sigue es prosa normal.
    """#

    private static let soloCodigo = #"""
    ```swift
    func sumar(_ a: Int, _ b: Int) -> Int { a + b }
    ```
    """#

    // MARK: - (1) Solo prosa, con el anuncio aparte

    /// [.texto, .codigo, .texto] produce exactamente
    /// [.texto, .anuncioCodigoOmitido, .texto]; el texto hablado es la
    /// concatenacion EXACTA de los dos `.texto`, sin codigo, sin cercas y sin
    /// el anuncio dentro.
    func testTextoParaLeerSoloProsaConElAnuncioAparte() {
        let segmentos = SegmentoRespuesta.segmentos(de: Self.respuestaMixta)
        XCTAssertEqual(segmentos.count, 3, "Prosa, codigo y prosa")

        XCTAssertEqual(
            LecturaEnVozAlta.textoParaLeer(segmentos: segmentos),
            [
                .texto(Self.prosaAntes),
                .anuncioCodigoOmitido,
                .texto(Self.prosaDespues)
            ]
        )

        let hablado = LecturaEnVozAlta.textoHablado(segmentos: segmentos)
        XCTAssertEqual(hablado, Self.prosaAntes + Self.prosaDespues)
        XCTAssertFalse(hablado.contains("func sumar"))
        XCTAssertFalse(hablado.contains("```"))
        XCTAssertFalse(hablado.contains(LecturaEnVozAlta.anuncioCodigoOmitido))
    }

    // MARK: - (2) Un solo bloque de codigo: solo el anuncio

    /// Con un unico bloque no hay nada de prosa que decir: queda solo el
    /// anuncio y CERO caracteres del contenido.
    func testUnSoloBloqueDeCodigoProduceSoloElAnuncio() {
        let segmentos = SegmentoRespuesta.segmentos(de: Self.soloCodigo)
        XCTAssertEqual(
            segmentos,
            [.codigo(lenguaje: "swift", textoCrudo: Self.codigoSwift)]
        )

        XCTAssertEqual(
            LecturaEnVozAlta.textoParaLeer(segmentos: segmentos),
            [.anuncioCodigoOmitido]
        )
        XCTAssertEqual(
            LecturaEnVozAlta.textoHablado(segmentos: segmentos),
            "",
            "El codigo no aporta ni un caracter al texto hablado"
        )
    }

    // MARK: - (3) Escuchar → Pausar → Reanudar → Detener y fin natural

    /// El pie recorre los estados y el fin natural (completion del lector)
    /// devuelve el control a [Escuchar] limpiando la burbuja en curso.
    func testEstadosEscucharPausarReanudarDetenerYFinNatural() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let mensaje = try await Self.mensajeAsistenteUnico(en: arnes)

        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.mensajeLeyendo, mensaje.id)
        XCTAssertEqual(arnes.estado.estadoLectura, .leyendo)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)
        XCTAssertEqual(arnes.lector.vecesLeido, 1)
        XCTAssertEqual(
            arnes.lector.locuciones,
            [
                .texto(Self.prosaAntes),
                .anuncioCodigoOmitido,
                .texto(Self.prosaDespues)
            ]
        )

        // Pausar: el rotulo visible pasa a [Reanudar].
        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .pausado)
        XCTAssertEqual(arnes.estado.estadoLectura.rotulo, "Reanudar")
        XCTAssertEqual(arnes.lector.vecesPausado, 1)

        // Reanudar: vuelve a [Pausar] sin releer desde el principio.
        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)
        XCTAssertEqual(arnes.estado.estadoLectura.rotulo, "Pausar")
        XCTAssertEqual(arnes.lector.vecesReanudado, 1)
        XCTAssertEqual(arnes.lector.vecesLeido, 1, "Reanudar no reinicia")

        // Detener: corta y deja todos los pies en [Escuchar].
        let detenidosAntes = arnes.lector.vecesDetenido
        arnes.estado.detenerLectura()
        XCTAssertGreaterThan(arnes.lector.vecesDetenido, detenidosAntes)
        XCTAssertNil(arnes.estado.mensajeLeyendo)
        XCTAssertEqual(arnes.estado.estadoLectura, .inactivo)
        XCTAssertEqual(arnes.estado.estadoLectura.rotulo, "Escuchar")

        // Fin natural: la completion del lector limpia la burbuja en curso.
        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)
        arnes.lector.terminar()
        XCTAssertNil(arnes.estado.mensajeLeyendo)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .inactivo)
        XCTAssertEqual(arnes.estado.estadoLectura, .inactivo)
    }

    // MARK: - (4) Cambio de hilo

    /// Nueva conversacion y apertura de otra cortan la lectura: ninguna
    /// lectura sobrevive a un cambio de hilo.
    func testCambioDeHiloDetieneLaLectura() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let mensaje = try await Self.mensajeAsistenteUnico(en: arnes)

        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)

        let detenidosAntes = arnes.lector.vecesDetenido
        arnes.estado.nuevaConversacion()
        XCTAssertGreaterThan(arnes.lector.vecesDetenido, detenidosAntes)
        XCTAssertEqual(arnes.estado.estadoLectura, .inactivo)
        XCTAssertNil(arnes.estado.mensajeLeyendo)

        // Volver a leer y abrir OTRA conversacion: el corte es el mismo.
        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)

        let detenidosAntesDeAbrir = arnes.lector.vecesDetenido
        arnes.estado.abrir(Conversation(titulo: "Otra conversacion"))
        XCTAssertGreaterThan(
            arnes.lector.vecesDetenido,
            detenidosAntesDeAbrir
        )
        XCTAssertEqual(arnes.estado.estadoLectura, .inactivo)
        XCTAssertNil(arnes.estado.mensajeLeyendo)
    }

    // MARK: - (5) El dictado corta la lectura

    /// Abrir el microfono con la sintesis sonando dejaria dos sesiones de audio
    /// activas: alternarDictado corta la lectura ANTES de pedir permisos.
    func testAbrirElDictadoDetieneLaLectura() async throws {
        let dictado = DictadoGuionizado()
        let arnes = try ArnesApp(dictado: dictado)
        defer { arnes.limpiar() }
        let mensaje = try await Self.mensajeAsistenteUnico(en: arnes)

        arnes.estado.alternarLectura(de: mensaje)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: mensaje.id), .leyendo)

        let detenidosAntes = arnes.lector.vecesDetenido
        await arnes.estado.alternarDictado()

        XCTAssertGreaterThan(arnes.lector.vecesDetenido, detenidosAntes)
        XCTAssertEqual(arnes.lector.estado, .inactivo)
        XCTAssertNil(arnes.estado.mensajeLeyendo)
        XCTAssertEqual(arnes.estado.estadoLectura, .inactivo)
        XCTAssertTrue(arnes.estado.dictando, "El dictado queda funcionando")
        XCTAssertEqual(dictado.vecesArrancado, 1)
    }

    // MARK: - (6) Segunda burbuja

    /// Escuchar otra burbuja corta la primera y el lector recibe exactamente
    /// las locuciones de la segunda.
    func testSegundaBurbujaDetieneLaPrimera() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: Self.respuestaMixta,
            uso: UsoTokens(entrada: 40, salida: 20)
        )
        arnes.transporte.guionar(
            texto: "La segunda respuesta solo tiene prosa.",
            uso: UsoTokens(entrada: 50, salida: 8)
        )

        arnes.estado.enviar("Explícame qué hace esta función y muéstrame su código.")
        try await arnes.esperarTurno()
        arnes.estado.enviar("Ahora dime otra cosa.")
        try await arnes.esperarTurno()

        let asistentes = arnes.estado.conversacion.mensajes.filter {
            $0.rol == .asistente
        }
        XCTAssertEqual(asistentes.count, 2)
        let primera = asistentes[0]
        let segunda = asistentes[1]

        arnes.estado.alternarLectura(de: primera)
        XCTAssertEqual(arnes.estado.estadoDeLectura(de: primera.id), .leyendo)
        XCTAssertEqual(
            arnes.lector.locuciones.first,
            LocucionLectura.texto(Self.prosaAntes)
        )

        let detenidosAntes = arnes.lector.vecesDetenido
        arnes.estado.alternarLectura(de: segunda)

        XCTAssertGreaterThan(arnes.lector.vecesDetenido, detenidosAntes)
        XCTAssertEqual(
            arnes.estado.estadoDeLectura(de: primera.id),
            .inactivo,
            "La primera burbuja vuelve a [Escuchar]"
        )
        XCTAssertEqual(
            arnes.estado.estadoDeLectura(de: segunda.id),
            .leyendo
        )
        XCTAssertEqual(arnes.estado.mensajeLeyendo, segunda.id)
        XCTAssertEqual(
            arnes.lector.locuciones,
            [.texto("La segunda respuesta solo tiene prosa.")],
            "El lector recibe las locuciones de la SEGUNDA burbuja"
        )
    }

    // MARK: - Utilidades

    /// Envia un turno guionizado y devuelve su unica respuesta del asistente.
    private static func mensajeAsistenteUnico(
        en arnes: ArnesApp
    ) async throws -> ChatMessage {
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: respuestaMixta,
            uso: UsoTokens(entrada: 40, salida: 20)
        )
        arnes.estado.enviar(
            "Explícame qué hace esta función y muéstrame su código."
        )
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)

        let asistentes = arnes.estado.conversacion.mensajes.filter {
            $0.rol == .asistente
        }
        return try XCTUnwrap(asistentes.last)
    }
}
