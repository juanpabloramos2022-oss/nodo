import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de estado del compartir una respuesta o un hilo (IDEA3).
///
/// POR QUE sin SwiftUI: el texto exportado se compone en `EstadoApp` iterando
/// la proyeccion limpia `elementosVisiblesDelHilo()` (P0.2). Estos tests
/// comprueban el contenido exacto (0 UUIDs, 0 lineas de rol herramienta, 0
/// resultados crudos, costo sellado correcto), que exportar es solo lectura y
/// que en un Chat Temporal la accion no existe. La vista solo dispara.
@MainActor
final class CompartirTests: XCTestCase {

    // MARK: - Guion literal

    private static let promptIDEA3 =
        "Escríbeme una función que sume dos enteros, con su explicación."
    private static let prosaIDEA3Antes =
        "La función recibe dos enteros y devuelve su suma."
    private static let prosaIDEA3Despues =
        "Ese es el bloque completo; el resto es prosa."
    private static let codigoIDEA3 =
        "func sumar(_ a: Int, _ b: Int) -> Int { a + b }"

    private static let respuestaIDEA3 = #"""
    La función recibe dos enteros y devuelve su suma.

    ```swift
    func sumar(_ a: Int, _ b: Int) -> Int { a + b }
    ```

    Ese es el bloque completo; el resto es prosa.
    """#

    private static let patronUUID =
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    // MARK: - Nivel 1: respuesta e hilo limpios desde la proyeccion

    /// El hilo de prueba trae mensajes normales, de herramienta (con UUID en su
    /// resultado crudo) y una linea de memoria. La exportacion de la respuesta
    /// y del hilo no puede copiar ni el UUID ni el resultado crudo, y el
    /// encabezado lleva el costo total sellado del hilo.
    func testRespuestaYHiloLimpiosDesdeLaProyeccion() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let respuesta = try await Self.turnoConHerramientaDeMemoria(en: arnes)

        // El hilo real SI trae un resultado crudo de herramienta con UUID: la
        // exportacion no puede copiarlo.
        let herramienta = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.first { $0.rol == .herramienta }
        )
        XCTAssertNotNil(
            herramienta.texto.range(
                of: Self.patronUUID,
                options: .regularExpression
            ),
            "El resultado crudo de herramienta trae un UUID; la exportacion "
                + "no puede copiarlo"
        )
        XCTAssertTrue(
            arnes.estado.eventosVisuales.contains { $0.cambioMemoria != nil },
            "El turno deja una linea de memoria en la proyeccion"
        )
        XCTAssertTrue(
            arnes.estado.elementosVisiblesDelHilo().contains { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }
        )

        // Respuesta: solo prosa y codigo crudo, sin cercas ni metadatos.
        let textoRespuesta = try XCTUnwrap(
            arnes.estado.textoDeRespuestaParaCompartir(respuesta)
        )
        XCTAssertEqual(
            textoRespuesta,
            Self.prosaIDEA3Antes + "\n" + Self.codigoIDEA3 + "\n"
                + Self.prosaIDEA3Despues
        )
        XCTAssertFalse(textoRespuesta.contains("```"))
        Self.exigirLimpio(textoRespuesta)
        XCTAssertFalse(
            textoRespuesta.contains(herramienta.texto),
            "El resultado crudo de herramienta no viaja en la respuesta"
        )

        // Hilo: encabezado (titulo, fecha, costo sellado) + turnos en orden.
        let hilo = arnes.estado.markdownDelHilo()
        XCTAssertTrue(
            hilo.hasPrefix("# \(arnes.estado.conversacion.titulo)\n"),
            hilo
        )
        XCTAssertTrue(
            hilo.contains(
                "Fecha: "
                    + EstadoApp.fechaParaCompartir(
                        arnes.estado.conversacion.actualizada
                    )
            ),
            hilo
        )
        let costo = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertTrue(
            hilo.contains(
                "Costo total: ≈$\(String(format: "%.4f", costo))"
            ),
            hilo
        )
        XCTAssertTrue(hilo.contains("## Usuario\n\(Self.promptIDEA3)"), hilo)
        XCTAssertTrue(hilo.contains("## Asistente\n\(textoRespuesta)"), hilo)
        let usuario = try XCTUnwrap(hilo.range(of: "## Usuario"))
        let asistente = try XCTUnwrap(hilo.range(of: "## Asistente"))
        XCTAssertLessThan(usuario.lowerBound, asistente.lowerBound)
        XCTAssertEqual(hilo.components(separatedBy: "## Usuario").count - 1, 1)
        XCTAssertEqual(
            hilo.components(separatedBy: "## Asistente").count - 1,
            1
        )
        Self.exigirLimpio(hilo)
        XCTAssertFalse(
            hilo.contains(herramienta.texto),
            "El resultado crudo de herramienta no viaja en el hilo"
        )
        XCTAssertFalse(
            hilo.contains("Guardado en memoria"),
            "Los avisos de memoria son cromo de la app, no turnos: no viajan "
                + "en el hilo exportado"
        )
    }

    /// Exportar no altera el hilo ni el almacen: es solo lectura.
    func testExportarNoAlteraElHiloNiElAlmacen() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let respuesta = try await Self.turnoConHerramientaDeMemoria(en: arnes)
        let proyeccionAntes = arnes.estado.elementosVisiblesDelHilo()
        let mensajesAntes = arnes.estado.conversacion.mensajes
        let eventosAntes = arnes.estado.eventosVisuales

        arnes.estado.compartirRespuesta(de: respuesta)
        arnes.estado.compartirHilo()

        XCTAssertEqual(arnes.estado.elementosVisiblesDelHilo(), proyeccionAntes)
        XCTAssertEqual(arnes.estado.conversacion.mensajes, mensajesAntes)
        XCTAssertEqual(arnes.estado.eventosVisuales, eventosAntes)
    }

    /// El mecanismo de la hoja del sistema es el MISMO de /exportar: la accion
    /// nueva deja el texto en `textoParaCompartirSolicitado`.
    func testCompartirDejaElTextoParaLaHojaDelSistema() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let respuesta = try await Self.turnoConHerramientaDeMemoria(en: arnes)
        let textoRespuesta = try XCTUnwrap(
            arnes.estado.textoDeRespuestaParaCompartir(respuesta)
        )

        arnes.estado.compartirRespuesta(de: respuesta)
        XCTAssertEqual(
            arnes.estado.textoParaCompartirSolicitado,
            textoRespuesta
        )

        arnes.estado.textoParaCompartirSolicitado = nil
        arnes.estado.compartirHilo()
        XCTAssertEqual(
            arnes.estado.textoParaCompartirSolicitado,
            arnes.estado.markdownDelHilo()
        )
    }

    // MARK: - Chat Temporal: la accion no existe

    /// En un hilo temporal la puerta unica que consulta la vista esta cerrada,
    /// las dos acciones de compartir y el comando /exportar son no-ops: no hay
    /// forma de exportar desde ahi.
    func testEnChatTemporalNoHayFormaDeCompartir() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacionTemporal()
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: Self.respuestaIDEA3,
            uso: UsoTokens(entrada: 40, salida: 20)
        )
        arnes.estado.enviar(Self.promptIDEA3)
        try await arnes.esperarTurno()

        XCTAssertTrue(arnes.estado.hiloTemporal)
        XCTAssertFalse(
            arnes.estado.puedeCompartir,
            "La unica puerta que consulta la vista esta cerrada"
        )

        let respuesta = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .asistente }
        )
        arnes.estado.compartirRespuesta(de: respuesta)
        XCTAssertNil(arnes.estado.textoParaCompartirSolicitado)
        arnes.estado.compartirHilo()
        XCTAssertNil(arnes.estado.textoParaCompartirSolicitado)

        // Camino real de la app: teclear /exportar y enviarlo (la caja enruta
        // .comando a ejecutar) tampoco puede abrir la hoja del sistema.
        arnes.estado.borrador = "/exportar"
        arnes.estado.enviarTextoActual()
        XCTAssertNil(arnes.estado.textoParaCompartirSolicitado)
    }

    // MARK: - Utilidades

    /// Un turno normal que primero guarda en Memoria (via herramienta) y luego
    /// responde con prosa y codigo. Devuelve la respuesta final.
    private static func turnoConHerramientaDeMemoria(
        en arnes: ArnesApp
    ) async throws -> ChatMessage {
        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-idea3",
                    nombre: Memoria.nombreGuardar,
                    argumentos: #"{"content":"Dato de prueba de IDEA3","category":"preference"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: respuestaIDEA3,
            uso: UsoTokens(entrada: 1446, salida: 209)
        )

        arnes.estado.enviar(promptIDEA3)
        try await arnes.esperarTurno()
        XCTAssertEqual(arnes.transporte.guionesPendientes, 0)
        XCTAssertNil(arnes.estado.errorDeTurno)

        return try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .asistente }
        )
    }

    /// Las tres invariantes negativas del texto exportado.
    private static func exigirLimpio(
        _ texto: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            texto.range(of: patronUUID, options: .regularExpression),
            "El texto exportado no puede llevar un UUID",
            file: file,
            line: line
        )
        XCTAssertFalse(
            texto.contains("HERRAMIENTA"),
            "El texto exportado no puede llevar el rotulo HERRAMIENTA",
            file: file,
            line: line
        )
        XCTAssertFalse(
            texto.contains("Herramienta"),
            "El texto exportado no puede llevar el rol herramienta",
            file: file,
            line: line
        )
    }
}