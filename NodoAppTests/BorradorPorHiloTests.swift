import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Borrador persistente por hilo y preservacion ante fallo de red (IDEA6).
///
/// Nivel 1 del contrato: el borrador vive asociado al `conversacion.id`, dos
/// hilos no lo comparten, un envio fallido deja el `ErrorBubble` y el texto
/// integro, un envio exitoso borra el borrador y un Chat Temporal no deja
/// ninguno al cerrarse. Todo con el `EstadoApp` real y un transporte
/// guionizado: sin UI, sin red y sin llamadas a InferHub.
@MainActor
final class BorradorPorHiloTests: XCTestCase {

    // MARK: - Persistencia por hilo

    func testElBorradorSeGuardaPorHiloYVuelveAlReabrir() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacion()
        let hiloA = arnes.estado.conversacion
        let texto = "Esto lo escribí y salí sin enviar"

        arnes.estado.borrador = texto
        XCTAssertEqual(
            arnes.estado.borradorGuardado(para: hiloA.id),
            texto,
            "El texto se guarda automáticamente bajo el hilo abierto"
        )

        arnes.estado.nuevaConversacion()
        XCTAssertEqual(arnes.estado.borrador, "", "El hilo nuevo arranca vacío")

        arnes.estado.abrir(hiloA)
        XCTAssertEqual(
            arnes.estado.borrador,
            texto,
            "Al reabrir el hilo, el composer muestra el texto íntegro"
        )
    }

    func testDosHilosNoCompartenBorrador() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacion()
        let hiloA = arnes.estado.conversacion
        arnes.estado.borrador = "borrador de A"

        arnes.estado.nuevaConversacion()
        let hiloB = arnes.estado.conversacion
        arnes.estado.borrador = "borrador de B"

        XCTAssertEqual(arnes.estado.borradorGuardado(para: hiloA.id), "borrador de A")
        XCTAssertEqual(arnes.estado.borradorGuardado(para: hiloB.id), "borrador de B")

        arnes.estado.abrir(hiloA)
        XCTAssertEqual(arnes.estado.borrador, "borrador de A")

        arnes.estado.abrir(hiloB)
        XCTAssertEqual(arnes.estado.borrador, "borrador de B")
    }

    /// El borrador no vive solo en memoria: al reiniciar la app (otro
    /// `EstadoApp` sobre los mismos ajustes locales) sigue ahí.
    func testElBorradorSobreviveAlReinicioDeLaApp() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacion()
        let hilo = arnes.estado.conversacion
        let texto = "texto que sobrevive a cerrar la app"
        arnes.estado.borrador = texto

        let reiniciada = EstadoApp(
            llavero: arnes.llavero,
            transporte: arnes.transporte,
            defaults: arnes.defaults,
            directorioStore: arnes.directorioStore,
            directorioTareas: arnes.directorioTareas,
            dictado: DictadoGuionizado(),
            lector: LectorGuionizado()
        )

        reiniciada.abrir(hilo)
        XCTAssertEqual(reiniciada.borrador, texto)
    }

    // MARK: - Fallo de red

    func testUnEnvioSinRedMuestraElErrorBubbleYConservaElTexto() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let idHilo = arnes.estado.conversacion.id
        let texto = "Este mensaje no se puede perder"
        arnes.estado.borrador = texto

        arnes.transporte.fallarProximoStream()
        arnes.estado.enviarTextoActual()
        try await arnes.esperarTurno()

        let detalle = try XCTUnwrap(arnes.estado.errorDeTurno)
        XCTAssertEqual(detalle, "Sin conexión a internet.")
        XCTAssertEqual(
            arnes.estado.borrador,
            texto,
            "El composer conserva el texto íntegro tras el fallo"
        )
        XCTAssertEqual(
            arnes.estado.borradorGuardado(para: idHilo),
            texto,
            "El borrador sigue guardado en local"
        )

        // El hilo muestra el ErrorBubble existente (P0.2), no una burbuja
        // «pendiente»: el mensaje del usuario y el error, nada más.
        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let errores = elementos.filter { elemento in
            if case .errorTurno = elemento { return true }
            return false
        }
        XCTAssertEqual(errores.count, 1)
        let usuarios = elementos.filter { elemento in
            if case .burbujaUsuario = elemento { return true }
            return false
        }
        XCTAssertEqual(usuarios.count, 1)
        let pendientes = elementos.filter { elemento in
            if case .burbujaEnCurso = elemento { return true }
            return false
        }
        XCTAssertTrue(pendientes.isEmpty, "No hay burbuja pendiente en el hilo")
    }

    func testTrasElFalloElReenvioEnviaUnaSolaVezYVaciaLaCaja() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let idHilo = arnes.estado.conversacion.id
        let texto = "Mensaje que primero falla y luego sale"
        arnes.estado.borrador = texto

        arnes.transporte.fallarProximoStream()
        arnes.estado.enviarTextoActual()
        try await arnes.esperarTurno()
        XCTAssertNotNil(arnes.estado.errorDeTurno)

        // Vuelve la red: el mismo toque de Enviar, con el texto restaurado.
        arnes.transporte.guionar(
            texto: "Ahora sí llegó.",
            uso: UsoTokens(entrada: 12, salida: 6)
        )
        arnes.estado.enviarTextoActual()
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        let usuarios = arnes.estado.conversacion.mensajes.filter {
            $0.rol == .usuario
        }
        XCTAssertEqual(
            usuarios.count,
            1,
            "El reenvío no puede duplicar el mensaje del usuario"
        )
        XCTAssertEqual(usuarios.first?.texto, texto)
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.last?.texto,
            "Ahora sí llegó."
        )
        XCTAssertEqual(
            arnes.estado.borrador,
            "",
            "Tras el éxito la caja queda vacía"
        )
        XCTAssertNil(
            arnes.estado.borradorGuardado(para: idHilo),
            "Tras el éxito el borrador de ese hilo se borra en local"
        )
    }

    func testElEnvioExitosoBorraElBorradorYAlReabrirLaCajaEstaVacia() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let texto = "Mensaje que sí se envía"
        arnes.estado.borrador = texto
        arnes.transporte.guionar(
            texto: "Recibido.",
            uso: UsoTokens(entrada: 10, salida: 4)
        )

        arnes.estado.enviarTextoActual()
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.borrador, "")

        let persistida = try XCTUnwrap(arnes.estado.conversaciones.first)
        XCTAssertNil(
            arnes.estado.borradorGuardado(para: persistida.id),
            "El texto ya enviado no puede resucitar como borrador"
        )
        arnes.estado.abrir(persistida)
        XCTAssertEqual(arnes.estado.borrador, "")
    }

    // MARK: - Chat Temporal (B2.2)

    func testElBorradorDeUnChatTemporalNoSeGuardaYSeBorraAlCerrar() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacionTemporal()
        let idTemporal = arnes.estado.conversacion.id

        arnes.estado.borrador = "secreto del hilo temporal"
        XCTAssertNil(
            arnes.estado.borradorGuardado(para: idTemporal),
            "Un Chat Temporal no guarda ni el borrador"
        )

        arnes.estado.cerrarHiloTemporal()

        XCTAssertEqual(arnes.estado.borrador, "")
        XCTAssertNil(arnes.estado.borradorGuardado(para: idTemporal))
        XCTAssertNotEqual(arnes.estado.conversacion.id, idTemporal)
    }

    func testAlPasarUnHiloNormalATemporalSuBorradorSeBorra() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacion()
        let idHilo = arnes.estado.conversacion.id
        arnes.estado.borrador = "texto escrito como chat normal"

        XCTAssertEqual(arnes.estado.borradorGuardado(para: idHilo), "texto escrito como chat normal")
        XCTAssertTrue(arnes.estado.alternarChatTemporal())
        XCTAssertNil(
            arnes.estado.borradorGuardado(para: idHilo),
            "Al volverse temporal, el borrador guardado se descarta"
        )

        arnes.estado.cerrarHiloTemporal()
        XCTAssertNil(arnes.estado.borradorGuardado(para: idHilo))
    }

    // MARK: - Composer unificado de Tarea (B3-A)

    /// El composer de Tarea es el mismo componente, pero su texto no es un
    /// borrador de chat: escribir ahí no puede tocar el hilo de Chat abierto.
    func testElComposerDeTareaNoEscribeElBorradorDelChat() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.nuevaConversacion()
        let idChat = arnes.estado.conversacion.id

        arnes.estado.tareaEnPantalla = UUID()
        arnes.estado.borrador = "encargo escrito en el hilo de Tarea"

        XCTAssertNil(arnes.estado.borradorGuardado(para: idChat))
    }
}
