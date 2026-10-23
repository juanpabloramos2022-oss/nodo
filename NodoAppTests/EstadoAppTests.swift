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

    // MARK: - Sello de costo (COST.1)

    /// Tras un turno el mensaje queda sellado y editar los precios del
    /// proveedor despues no puede mover el acumulado del chat.
    func testElSelloDelTurnoNoSeRevaluaAlEditarLosPrecios() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Respuesta sellada.",
            uso: UsoTokens(entrada: 1_000_000, salida: 500_000)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let proveedorDelTurno = arnes.proveedor
        let mensaje = try XCTUnwrap(arnes.estado.conversacion.mensajes.last)
        let sello = try XCTUnwrap(mensaje.costoSelladoUSD)
        XCTAssertFalse(mensaje.costoEsEstimacion)

        let esperado = try XCTUnwrap(
            CostoEstimado.costo(
                uso: UsoTokens(entrada: 1_000_000, salida: 500_000),
                precioEntrada: proveedorDelTurno.precioEntradaPorMillon,
                precioSalida: proveedorDelTurno.precioSalidaPorMillon
            )
        )
        XCTAssertEqual(sello, esperado, accuracy: 0.0000001)
        let antes = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)

        // Se editan los precios DESPUES del turno: el sello ya esta escrito y
        // no puede revaluarse.
        let indice = try XCTUnwrap(
            arnes.estado.config.proveedores.firstIndex {
                $0.id == proveedorDelTurno.id
            }
        )
        arnes.estado.config.proveedores[indice].precioEntradaPorMillon = 1_000
        arnes.estado.config.proveedores[indice].precioSalidaPorMillon = 1_000

        let despues = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertEqual(
            despues,
            antes,
            accuracy: 0.0000001,
            "Editar precios no puede reescribir la factura ya sellada"
        )
        let delMensaje = try XCTUnwrap(arnes.estado.costo(de: mensaje))
        XCTAssertEqual(delMensaje, antes, accuracy: 0.0000001)
    }

    /// La regeneracion pasa por el mismo camino que el envio y tambien sella.
    func testRegenerarTambienSella() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let activo = arnes.proveedor
        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: activo))
        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Respuesta anterior",
                    tokensEntrada: 100,
                    tokensSalida: 20,
                    proveedorID: activo.id
                )
            ],
            proveedorID: activo.id
        )
        arnes.transporte.guionar(
            texto: "Respuesta regenerada.",
            uso: UsoTokens(entrada: 2_000, salida: 1_000)
        )

        arnes.estado.regenerar()
        try await arnes.esperarTurno()

        let nueva = try XCTUnwrap(arnes.estado.conversacion.mensajes.last)
        XCTAssertEqual(nueva.texto, "Respuesta regenerada.")
        let sello = try XCTUnwrap(nueva.costoSelladoUSD)
        XCTAssertFalse(nueva.costoEsEstimacion)

        let esperado = try XCTUnwrap(
            CostoEstimado.costo(
                uso: UsoTokens(entrada: 2_000, salida: 1_000),
                precioEntrada: activo.precioEntradaPorMillon,
                precioSalida: activo.precioSalidaPorMillon
            )
        )
        XCTAssertEqual(sello, esperado, accuracy: 0.0000001)
        let acumulado = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertEqual(acumulado, esperado, accuracy: 0.0000001)
    }

    // MARK: - Libro de gasto (COST.2)

    func testRegistrarUnTurnoAlimentaElLibroDeGasto() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Respuesta que alimenta el libro.",
            uso: UsoTokens(entrada: 120, salida: 30)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let libro = arnes.estado.config.usoApp
        let hoy = Date()
        let dia = libro.dia(hoy)
        let mes = libro.mes(hoy)

        XCTAssertEqual(dia.uso, UsoTokens(entrada: 120, salida: 30))
        XCTAssertEqual(mes.uso, UsoTokens(entrada: 120, salida: 30))
        XCTAssertGreaterThan(dia.usd, 0)
        XCTAssertEqual(dia.usd, mes.usd, accuracy: 0.0000001)
        XCTAssertEqual(libro.totalDias.uso, UsoTokens(entrada: 120, salida: 30))
    }

    // MARK: - Compactacion y sello (HP4)

    /// Historia larga ya sellada: al compactar, los sellos de los mensajes que
    /// salen se mudan al balde y el acumulado no pierde nada.
    func testCompactarConservaElAcumuladoDelChat() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let activo = arnes.proveedor
        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: activo))
        arnes.estado.conversacion = historiaSellada(con: activo)

        let costoAntes = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        let usoAntes = try XCTUnwrap(arnes.estado.usoAcumuladoDelChat)

        // Resumen sin consumo guionizado: la unica diferencia medida es la
        // mudanza de los sellos al balde.
        arnes.transporte.guionar(texto: "Resumen de la conversacion.", uso: nil)

        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 6)
        XCTAssertEqual(
            arnes.estado.usoAcumuladoDelChat,
            usoAntes,
            "El consumo no puede bajar al compactar"
        )
        let costoDespues = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertEqual(
            costoDespues,
            costoAntes,
            accuracy: 0.0000001,
            "El acumulado es sellos vivos + balde y no pierde un centavo"
        )
    }

    /// HP4: la llamada de resumen tambien se sella y su costo entra en el
    /// balde, asi que el acumulado sube exactamente lo que costo resumir.
    func testCompactarSumaElSelloDelResumenAlBalde() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let activo = arnes.proveedor
        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: activo))
        arnes.estado.conversacion = historiaSellada(con: activo)

        let costoAntes = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        let usoDelResumen = UsoTokens(entrada: 2_000, salida: 1_000)
        arnes.transporte.guionar(texto: "Resumen con consumo.", uso: usoDelResumen)

        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        let selloDelResumen = try XCTUnwrap(
            CostoEstimado.costo(
                uso: usoDelResumen,
                precioEntrada: activo.precioEntradaPorMillon,
                precioSalida: activo.precioSalidaPorMillon
            )
        )
        let costoDespues = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertEqual(
            costoDespues,
            costoAntes + selloDelResumen,
            accuracy: 0.0000001
        )
    }

    /// Ocho mensajes con cuatro respuestas ya selladas a los precios de su
    /// proveedor. Es la historia larga que /compact parte en dos.
    private func historiaSellada(con proveedor: ProviderConfig) -> Conversation {
        var mensajes: [ChatMessage] = []
        for vuelta in 0..<4 {
            mensajes.append(
                ChatMessage(rol: .usuario, texto: "Pregunta \(vuelta)")
            )
            var respuesta = ChatMessage(
                rol: .asistente,
                texto: "Respuesta \(vuelta)",
                tokensEntrada: 1_000,
                tokensSalida: 500,
                proveedorID: proveedor.id
            )
            SellosDeCosto.sellar(&respuesta, proveedor: proveedor)
            mensajes.append(respuesta)
        }
        return Conversation(mensajes: mensajes, proveedorID: proveedor.id)
    }
}
