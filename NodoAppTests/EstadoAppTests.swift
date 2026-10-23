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
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.first?.rol,
            ChatMessage.Rol.usuario
        )
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.last?.rol,
            ChatMessage.Rol.asistente
        )
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

    // MARK: - Demolicion del modo Tarea

    /// Un chat normal va SIN herramientas, aunque una conversacion guardada
    /// conserve la vieja bandera `modoTarea` en su modelo Codable.
    func testPayloadDeChatNormalNoOfreceHerramientas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.conversacion = Conversation(modoTarea: true)
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Respuesta sin herramientas.",
            uso: UsoTokens(entrada: 40, salida: 8)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        )
        XCTAssertNil(
            json["tools"],
            "Un chat normal no debe ofrecer herramientas por la bandera modoTarea"
        )
    }

    // MARK: - Regenerar con otro combo

    /// El combo elegido solo construye el motor de esa regeneracion: el
    /// proveedor activo global debe quedar intacto al terminar.
    func testRegenerarConOtroComboNoCambiaProveedorActivo() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let activoOriginal = arnes.proveedor
        let otro = try XCTUnwrap(
            arnes.estado.config.proveedores.first { $0.id != activoOriginal.id }
        )
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-activa", para: activoOriginal)
        )
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-otro", para: otro)
        )

        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Respuesta anterior",
                    tokensEntrada: 100,
                    tokensSalida: 20,
                    proveedorID: activoOriginal.id
                )
            ],
            proveedorID: activoOriginal.id
        )
        arnes.transporte.guionar(
            texto: "Respuesta regenerada con otro combo.",
            uso: UsoTokens(entrada: 30, salida: 10)
        )

        arnes.estado.regenerarCon(proveedorID: otro.id)
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.proveedorActivo,
            activoOriginal.id,
            "Regenerar con otro combo no puede cambiar el proveedor activo"
        )
        XCTAssertEqual(
            arnes.estado.conversacion.mensajes.last?.texto,
            "Respuesta regenerada con otro combo."
        )

        // Y el motor de esa regeneracion si fue el combo elegido.
        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, otro.modelo)
    }

    // MARK: - Costo historico

    /// Cambiar el proveedor activo no puede revaluar los mensajes ya pagados:
    /// cada uno conserva el proveedor que lo genero.
    func testCostoAcumuladoNoCambiaAlCambiarProveedorActivo() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let activoOriginal = arnes.proveedor
        let otro = try XCTUnwrap(
            arnes.estado.config.proveedores.first {
                $0.id != activoOriginal.id
                    && $0.precioEntradaPorMillon != activoOriginal.precioEntradaPorMillon
            }
        )
        let uso = UsoTokens(entrada: 1_000, salida: 500)
        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Respuesta ya pagada",
                    tokensEntrada: uso.entrada,
                    tokensSalida: uso.salida,
                    proveedorID: activoOriginal.id
                )
            ],
            proveedorID: activoOriginal.id
        )

        let antes = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        let esperado = try XCTUnwrap(
            CostoEstimado.costo(
                uso: uso,
                precioEntrada: activoOriginal.precioEntradaPorMillon,
                precioSalida: activoOriginal.precioSalidaPorMillon
            )
        )
        XCTAssertEqual(antes, esperado, accuracy: 0.0000001)

        arnes.estado.config.proveedorActivo = otro.id

        let despues = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertEqual(
            antes,
            despues,
            accuracy: 0.0000001,
            "El costo historico no puede recalcularse con el proveedor activo"
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
        // Aunque hubiera clave y un guion disponible, una conversacion corta no
        // debe llegar a pedir el resumen: el guard de longitud va antes.
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Resumen que no se deberia pedir.",
            uso: UsoTokens(entrada: 10, salida: 5)
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
