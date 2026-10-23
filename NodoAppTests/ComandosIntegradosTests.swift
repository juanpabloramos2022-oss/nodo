import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// H6.1: los comandos integrados ejecutan su accion REAL en `EstadoApp` y las
/// skills del dueno se crean en la app y se invocan con "/".
///
/// No se prueba el parser (ya tiene su suite): se prueba el efecto observable de
/// cada comando sobre el estado y sobre el payload que sale a la red.
@MainActor
final class ComandosIntegradosTests: XCTestCase {

    // MARK: - /costo

    func testCostoMuestraElCostoSelladoDelChatSinLlamarAlModelo() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Respuesta con uso.",
            uso: UsoTokens(entrada: 1_000, salida: 200)
        )
        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let costo = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertGreaterThan(costo, 0)
        let peticionesAntes = arnes.transporte.cantidadDePeticiones
        let mensajesAntes = arnes.estado.conversacion.mensajes.count

        arnes.estado.borrador = "/costo"
        arnes.estado.enviarTextoActual()

        // Es una accion local: ni sale al modelo ni se convierte en mensaje.
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, peticionesAntes)
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, mensajesAntes)
        let textos = arnes.estado.eventosVisuales.map(\.texto)
        XCTAssertTrue(
            textos.contains { $0.contains("En este chat van") && $0.contains("$") },
            "El costo sellado no quedo visible en el hilo: \(textos)"
        )
    }

    // MARK: - /modelos

    func testModelosAbreLaHojaDeModelosDisponibles() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.borrador = "/modelos"
        arnes.estado.enviarTextoActual()

        XCTAssertTrue(arnes.estado.mostrarHojaModelos)
        // La hoja pinta la lista real: el preset trae los cuatro combos.
        XCTAssertEqual(arnes.estado.config.proveedores.count, 4)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 0)
    }

    // MARK: - /nuevo

    func testNuevoCreaUnaConversacionNuevaYLaDejaParaAbrir() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let idOriginal = arnes.estado.conversacion.id
        arnes.estado.conversacion.mensajes.append(
            ChatMessage(rol: .usuario, texto: "Mensaje viejo")
        )

        arnes.estado.borrador = "/nuevo"
        arnes.estado.enviarTextoActual()

        XCTAssertNotEqual(arnes.estado.conversacion.id, idOriginal)
        XCTAssertTrue(arnes.estado.conversacion.mensajes.isEmpty)
        XCTAssertEqual(arnes.estado.idParaAbrir, arnes.estado.conversacion.id)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 0)
    }

    // MARK: - /exportar

    func testExportarPreparaElHiloCompletoParaCompartir() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.conversacion.mensajes = [
            ChatMessage(rol: .usuario, texto: "Pregunta del dueno"),
            ChatMessage(rol: .asistente, texto: "Respuesta del asistente")
        ]

        arnes.estado.borrador = "/exportar"
        arnes.estado.enviarTextoActual()

        let exportado = try XCTUnwrap(arnes.estado.textoParaCompartirSolicitado)
        XCTAssertTrue(exportado.contains("Pregunta del dueno"))
        XCTAssertTrue(exportado.contains("Respuesta del asistente"))
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 0)
    }

    // MARK: - Skills del dueno

    /// Una skill creada en la app se resuelve por su slug y sus instrucciones
    /// viajan en el payload del turno, junto al mensaje limpio.
    func testUnaSkillCreadaSeInvocaConSuSlugYLlegaAlPayload() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let resultado = arnes.estado.guardarSkill(
            nombre: "Resumidor de actas",
            instrucciones: "Resume el acta en tres puntos."
        )
        guard case .success(let skill) = resultado else {
            XCTFail("La skill del dueno no se pudo crear: \(resultado)")
            return
        }
        XCTAssertEqual(skill.slug, "resumidor-de-actas")
        XCTAssertEqual(arnes.estado.config.skills.count, 1)
        // El selector flotante lee la misma fuente que el parser.
        XCTAssertTrue(
            arnes.estado.skillsParaSelector("").contains { $0.slug == skill.slug }
        )

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Listo.",
            uso: UsoTokens(entrada: 30, salida: 5)
        )

        arnes.estado.borrador = "/resumidor-de-actas revisa esto"
        arnes.estado.enviarTextoActual()
        try await arnes.esperarTurno()

        // El mensaje del usuario queda con la skill aplicada y el texto limpio.
        let mensaje = try XCTUnwrap(arnes.estado.conversacion.mensajes.first)
        XCTAssertEqual(mensaje.rol, .usuario)
        XCTAssertEqual(mensaje.texto, "revisa esto")
        XCTAssertEqual(mensaje.skillsAplicadas, ["Resumidor de actas"])

        // El payload real lleva las instrucciones y el mensaje.
        let cuerpo = try cuerpoDeLaUltimaPeticion(arnes)
        XCTAssertTrue(cuerpo.contains("Resume el acta en tres puntos."), cuerpo)
        XCTAssertTrue(cuerpo.contains("revisa esto"), cuerpo)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        )
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertTrue(
            mensajes.contains {
                $0["role"] as? String == "system"
                    && ($0["content"] as? String)?
                        .contains("Resume el acta en tres puntos.") == true
            },
            "Las instrucciones de la skill no viajaron en el payload"
        )
    }

    private func cuerpoDeLaUltimaPeticion(_ arnes: ArnesApp) throws -> String {
        let datos = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.last?.cuerpo
        )
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }
}