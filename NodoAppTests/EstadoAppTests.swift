import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas semilla de la capa app.
///
/// Corren sobre un `EstadoApp` real con dobles solo en las costuras de sistema
/// (llavero, preferencias, carpeta y red). Asi se prueba la ruta de produccion
/// de punta a punta, no un estado de capturas.
@MainActor
final class EstadoAppTests: XCTestCase {

    // MARK: - Turno normal

    func testTurnoNormalCompletaRespuestaYRegistraUso() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Hola desde el transporte guionizado.",
            uso: UsoTokens(entrada: 120, salida: 30)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 2)
        XCTAssertEqual(arnes.estado.conversacion.mensajes.first?.rol, .usuario)
        XCTAssertEqual(arnes.estado.conversacion.mensajes.last?.rol, .asistente)
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.last?.texto,
            "Hola desde el transporte guionizado."
        )
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.last?.uso,
            UsoTokens(entrada: 120, salida: 30)
        )
        XCTAssertEqual(
            arnes.estado.usoAcumuladoDelChat,
            UsoTokens(entrada: 120, salida: 30)
        )
        XCTAssertGreaterThan(arnes.estado.config.gasto.desdeReinicio, 0)
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)

        // La peticion grabada es la del turno: lleva el mensaje del usuario y
        // el modelo del proveedor activo.
        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, arnes.proveedor.modelo)
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertTrue(
            mensajes.contains {
                $0["role"] as? String == "user"
                    && $0["content"] as? String == "Hola"
            }
        )
    }

    // MARK: - Llavero

    func testGuardarClaveDevuelveTrueYQuedaEnElLlaveroFalso() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let clave = "  sk-prueba-123  "
        XCTAssertNil(arnes.llavero.leer(arnes.proveedor.claveKeychain))

        XCTAssertTrue(arnes.estado.guardarClave(clave, para: arnes.proveedor))

        XCTAssertEqual(
            arnes.llavero.leer(arnes.proveedor.claveKeychain),
            "sk-prueba-123"
        )
        XCTAssertEqual(arnes.estado.clave(para: arnes.proveedor), "sk-prueba-123")
        // La clave se propaga a los companeros del mismo host que aun no
        // tenian una propia; el llavero falso lo deja comprobar sin Security.
        XCTAssertGreaterThan(arnes.llavero.cantidad, 1)
    }

    // MARK: - Respaldo

    func testRespaldoIdaYVueltaConservaLaMemoria() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let memoria = "Memoria de prueba que no se puede perder."
        arnes.estado.config.systemPrompt = memoria
        arnes.estado.ventanasPorModelo = ["modelo/de-prueba": 128_000]

        // La exportacion real de la app: mismo constructor y mismo JSON que usa
        // Conexiones, para que la ida y vuelta pruebe el formato de verdad.
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: arnes.estado.config,
            ventanas: arnes.estado.ventanasPorModelo
        )
        let leido = try RespaldoConfiguracion.desde(json: try respaldo.json())

        // Se ensucia el estado antes de importar: si la Memoria no viajara en
        // el respaldo, la prueba lo detectaria aqui.
        arnes.estado.config.systemPrompt = "Memoria borrada antes de importar."
        arnes.estado.ventanasPorModelo = [:]

        arnes.estado.importarRespaldo(leido)

        XCTAssertEqual(arnes.estado.config.systemPrompt, memoria)
        XCTAssertEqual(
            arnes.estado.ventanasPorModelo["modelo/de-prueba"],
            128_000
        )
        XCTAssertEqual(leido.memoria, memoria)
    }

    // MARK: - Compactacion

    func testCompactarConversacionCortaNoPideResumen() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Hola, en que puedo ayudarte?"
                )
            ]
        )

        arnes.estado.compactar()
        // Se deja pasar un instante por si una version futura lanzara la tarea
        // de resumen: la prueba debe seguir exigiendo cero peticiones.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 0)
        XCTAssertFalse(arnes.estado.compactando)
        XCTAssertTrue(
            (arnes.estado.avisoComando ?? "").contains("corta"),
            "Se esperaba el aviso de conversacion corta, y llego: "
                + (arnes.estado.avisoComando ?? "nil")
        )
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 2)
    }
}
