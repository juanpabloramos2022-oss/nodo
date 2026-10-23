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

    /// COMP.1: el resumidor recibe solo los mensajes antiguos. Los seis que se
    /// conservan no pueden viajar en la peticion de resumen.
    func testCompactarResumeSoloElPrefijoAntiguo() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        let mensajes = (0..<8).map { indice in
            ChatMessage(
                rol: indice.isMultiple(of: 2) ? .usuario : .asistente,
                texto: (indice < 2 ? "ANTIGUO \(indice)" : "CONSERVADO \(indice)")
                    + " " + String(repeating: "x", count: 40)
            )
        }
        arnes.estado.conversacion = Conversation(mensajes: mensajes)
        arnes.transporte.guionar(texto: "Resumen del prefijo.", uso: nil)

        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)
        let cuerpo = try cuerpoDeLaUltimaPeticion(arnes)
        XCTAssertTrue(cuerpo.contains("ANTIGUO 0"), cuerpo)
        XCTAssertTrue(cuerpo.contains("ANTIGUO 1"), cuerpo)
        for indice in 2..<8 {
            XCTAssertFalse(
                cuerpo.contains("CONSERVADO \(indice)"),
                "La peticion de resumen no puede llevar el mensaje conservado \(indice)"
            )
        }
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 6)
    }

    /// Con exactamente seis mensajes no hay prefijo que resumir: /compact no
    /// debe hacer ninguna peticion y tiene que dejar el aviso de conversacion
    /// corta.
    func testCompactarConSeisMensajesNoPideResumen() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.conversacion = Conversation(
            mensajes: (0..<6).map { indice in
                ChatMessage(
                    rol: indice.isMultiple(of: 2) ? .usuario : .asistente,
                    texto: "Mensaje \(indice)"
                )
            }
        )
        arnes.transporte.guionar(
            texto: "Resumen que no se deberia pedir.",
            uso: UsoTokens(entrada: 10, salida: 5)
        )

        arnes.estado.compactar()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 0)
        XCTAssertFalse(arnes.estado.compactando)
        XCTAssertTrue(
            (arnes.estado.avisoComando ?? "").contains("corta"),
            "Se esperaba el aviso de conversacion corta, y llego: "
                + (arnes.estado.avisoComando ?? "nil")
        )
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 6)
    }

    /// Guarda de no-reduccion en la app: un resumen que no comprime deja el
    /// hilo intacto, no guarda resumen y avisa.
    func testCompactarConResumenQueNoReduceConservaLosMensajes() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.conversacion = historiaLarga(sinMemoria: true)
        arnes.transporte.guionar(
            texto: String(repeating: "z", count: 20_000),
            uso: nil
        )

        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 8)
        XCTAssertNil(arnes.estado.conversacion.resumenCompactado)
        XCTAssertTrue(
            (arnes.estado.avisoComando ?? "").contains("no reduc"),
            "Se esperaba el aviso de resumen que no reduce, y llego: "
                + (arnes.estado.avisoComando ?? "nil")
        )
    }

    // MARK: - Compactacion (COMP.1-COMP.3)

    /// El resumen de /compact tiene que llegar al turno siguiente aunque el
    /// chat no tenga Memoria. Sin esto, compactar poda el hilo y el modelo
    /// pierde justo el contexto que el resumen conservaba; por eso se mira el
    /// payload real del transporte y no solo el estado interno.
    func testCompactarSinMemoriaElResumenLlegaAlSiguienteTurno() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        // Sin Memoria el prompt del sistema no viaja: el unico contexto que
        // puede sobrevivir a la poda es el resumen guardado por /compact.
        arnes.estado.conversacion = historiaLarga(sinMemoria: true)

        arnes.transporte.guionar(texto: "EL DATO CLAVE ES 42", uso: nil)
        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        // Un turno nuevo despues de compactar: es el momento en el que el
        // resumen tiene que aparecer en el cuerpo de la peticion.
        arnes.transporte.guionar(
            texto: "Respuesta al turno nuevo.",
            uso: UsoTokens(entrada: 40, salida: 8)
        )
        arnes.estado.enviar("Nueva pregunta")
        try await arnes.esperarTurno()

        let cuerpo = try cuerpoDeLaUltimaPeticion(arnes)
        XCTAssertTrue(
            cuerpo.contains("EL DATO CLAVE ES 42"),
            "El resumen guardado no viajo al turno siguiente: \(cuerpo)"
        )
        XCTAssertTrue(
            cuerpo.contains("[Resumen de la conversacion anterior]"),
            "Falta la cabecera con la que el modelo reconoce el resumen: \(cuerpo)"
        )
    }

    /// Compactar no puede ser solo cosmetico: el contexto estimado que se
    /// mandaria al modelo tiene que bajar. Se mide con la misma heuristica de
    /// `Compactador` que usa la app y se incluye el resumen, porque tambien
    /// ocupa ventana en el payload del turno siguiente.
    func testCompactarReduceElContextoEstimado() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.conversacion = historiaLarga(sinMemoria: true)

        let antes = Compactador.estimarContexto(
            mensajes: arnes.estado.conversacion.mensajes
        )

        arnes.transporte.guionar(texto: "EL DATO CLAVE ES 42", uso: nil)
        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        let despues = Compactador.estimarContexto(
            mensajes: arnes.estado.conversacion.mensajes,
            resumen: arnes.estado.conversacion.resumenCompactado
        )
        XCTAssertLessThan(
            despues,
            antes,
            "Compactar tiene que reducir el contexto estimado, no dejarlo igual"
        )
    }

    /// Compactar dos veces la misma conversacion no puede apilar dos copias
    /// del resumen: el mismo bloque duplicado gastaria ventana y confundiria
    /// al modelo. La segunda vez ya solo quedan 6 mensajes, asi que /compact
    /// avisa de conversacion corta, no llama a la API y el resumen vigente
    /// sigue viajando exactamente una vez en el turno siguiente.
    func testCompactarDosVecesNoDuplicaElResumen() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.conversacion = historiaLarga(sinMemoria: true)

        arnes.transporte.guionar(texto: "EL DATO CLAVE ES 42", uso: nil)
        arnes.estado.compactar()
        try await arnes.esperarCompactacion()
        let peticionesTrasLaPrimera = arnes.transporte.cantidadDePeticiones
        XCTAssertEqual(peticionesTrasLaPrimera, 1)

        // La segunda compactacion ya tiene 6 mensajes: no debe llamar a la API.
        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        XCTAssertEqual(
            arnes.transporte.cantidadDePeticiones,
            peticionesTrasLaPrimera,
            "Con 6 mensajes /compact no puede pedir otro resumen"
        )
        XCTAssertTrue(
            (arnes.estado.avisoComando ?? "").contains("corta"),
            "Se esperaba el aviso de conversacion corta, y llego: "
                + (arnes.estado.avisoComando ?? "nil")
        )
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 6)

        arnes.transporte.guionar(
            texto: "Respuesta despues de compactar dos veces.",
            uso: UsoTokens(entrada: 40, salida: 8)
        )
        arnes.estado.enviar("Nueva pregunta")
        try await arnes.esperarTurno()

        let cuerpo = try cuerpoDeLaUltimaPeticion(arnes)
        XCTAssertTrue(
            cuerpo.contains("EL DATO CLAVE ES 42"),
            "El resumen vigente no viajo al turno siguiente: \(cuerpo)"
        )
        let cabecera = "[Resumen de la conversacion anterior]"
        let veces = cuerpo.components(separatedBy: cabecera).count - 1
        XCTAssertEqual(
            veces,
            1,
            "El resumen viajo \(veces) veces en el mismo payload: \(cuerpo)"
        )
    }

    /// COMP.3: ramificar un chat ya compactado hereda el resumen y el balde
    /// sellado. La rama lo manda en su siguiente payload y su costo acumulado
    /// no pierde lo que la original ya habia resumido.
    func testRamificarChatCompactadoHeredaResumenYBalde() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let activo = arnes.proveedor
        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: activo))
        var original = historiaSellada(con: activo)
        // Sin Memoria el unico camino del resumen es el respaldo persistido por
        // conversacion: si la rama no hereda el mapa, el payload lo delatara.
        original.sinMemoria = true
        arnes.estado.conversacion = original

        let usoDelResumen = UsoTokens(entrada: 2_000, salida: 1_000)
        arnes.transporte.guionar(
            texto: "RESUMEN",
            uso: usoDelResumen
        )
        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        let compactada = arnes.estado.conversacion
        XCTAssertEqual(compactada.mensajes.count, 6)
        XCTAssertEqual(compactada.resumenCompactado, "RESUMEN")
        let costoCompactado = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        let ultimo = try XCTUnwrap(compactada.mensajes.last)

        arnes.estado.ramificar(desde: ultimo)

        let rama = arnes.estado.conversacion
        XCTAssertNotEqual(rama.id, compactada.id)
        XCTAssertEqual(rama.resumenCompactado, compactada.resumenCompactado)
        XCTAssertEqual(rama.usoTrasCompactar, compactada.usoTrasCompactar)
        XCTAssertEqual(rama.mensajes.count, compactada.mensajes.count)

        // El balde de lo resumido (mensajes que salieron + llamada de resumen)
        // tiene que viajar a la rama: su acumulado es el mismo que el original.
        let costoRama = try XCTUnwrap(arnes.estado.costoAcumuladoDelChat)
        XCTAssertEqual(costoRama, costoCompactado, accuracy: 0.0000001)

        arnes.transporte.guionar(
            texto: "Respuesta en la rama.",
            uso: UsoTokens(entrada: 40, salida: 8)
        )
        arnes.estado.enviar("Nueva pregunta")
        try await arnes.esperarTurno()

        let cuerpo = try cuerpoDeLaUltimaPeticion(arnes)
        XCTAssertTrue(
            cuerpo.contains("RESUMEN"),
            "La rama no mando el resumen heredado: \(cuerpo)"
        )
        XCTAssertEqual(
            cuerpo.components(
                separatedBy: "[Resumen de la conversacion anterior]"
            ).count - 1,
            1
        )
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

    // MARK: - Carga de legados (COST.3)

    /// Al arrancar, un mensaje guardado sin sello se sella con los precios del
    /// proveedor que lo genero (no con el activo) y el libro migra ese gasto al
    /// mes en curso sin inventar dias hacia atras.
    func testAlCargarSellaLosLegadosConSuProveedorYMigraElLibro() throws {
        let sufijo = UUID().uuidString
        let nombreSuite = "com.nodo.ios.apptests.\(sufijo)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: nombreSuite))
        defaults.removePersistentDomain(forName: nombreSuite)
        defer { defaults.removePersistentDomain(forName: nombreSuite) }

        let directorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodoAppTests-\(sufijo)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directorio,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directorio) }

        let barato = ProviderConfig(
            nombre: "Barato",
            baseURL: "https://api.ejemplo.test/v1",
            modelo: "modelo-barato",
            precioEntradaPorMillon: 0.10,
            precioSalidaPorMillon: 0.20
        )
        let caro = ProviderConfig(
            nombre: "Caro",
            baseURL: "https://api.ejemplo.test/v1",
            modelo: "modelo-caro",
            precioEntradaPorMillon: 10,
            precioSalidaPorMillon: 20
        )
        // El caro es el activo, pero el legado lo genero el barato.
        let config = AppConfig(
            proveedores: [caro, barato],
            proveedorActivo: caro.id,
            systemPrompt: "Memoria de prueba"
        )
        defaults.set(try config.json(), forKey: "nodo.config.v1")

        let conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Respuesta vieja",
                    tokensEntrada: 1_000_000,
                    tokensSalida: 500_000,
                    proveedorID: barato.id
                )
            ],
            proveedorID: barato.id
        )
        try ConversationStore(directorio: directorio).guardar(conversacion)

        let estado = EstadoApp(
            llavero: LlaveroFalso(),
            transporte: TransporteGuionizado(),
            defaults: defaults,
            directorioStore: directorio
        )

        let cargada = try XCTUnwrap(estado.conversaciones.first)
        let mensaje = try XCTUnwrap(cargada.mensajes.last)
        let sello = try XCTUnwrap(mensaje.costoSelladoUSD)
        // 1M x 0.10 + 0.5M x 0.20 = 0.20, no los 20 del proveedor caro.
        XCTAssertEqual(sello, 0.20, accuracy: 0.0000001)
        XCTAssertTrue(mensaje.costoEsEstimacion)

        // El libro arranca con ese gasto en el mes en curso; los dias empiezan
        // hoy y no se rellena ninguno hacia atras.
        let libro = estado.config.usoApp
        let hoy = Date()
        XCTAssertTrue(libro.migrado)
        XCTAssertEqual(
            libro.mes(hoy).uso,
            UsoTokens(entrada: 1_000_000, salida: 500_000)
        )
        XCTAssertEqual(libro.mes(hoy).usd, 0.20, accuracy: 0.0000001)
        XCTAssertEqual(libro.totalDias.uso, UsoTokens())
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

    /// Cuerpo UTF-8 de la ultima peticion grabada por el transporte.
    ///
    /// Se lee como texto y no como JSON porque lo que importa es que el
    /// resumen viaje tal cual en el payload, sin atarse a la forma exacta del
    /// mensaje de sistema que lo transporta.
    private func cuerpoDeLaUltimaPeticion(_ arnes: ArnesApp) throws -> String {
        let datos = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.last?.cuerpo
        )
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }

    /// Historia larga con el mismo patron de cuatro vueltas que usan los tests
    /// de /compact, pero con textos de verdad: el contexto estimado solo baja
    /// de forma medible si lo que sale pesa mas que el resumen que entra.
    private func historiaLarga(sinMemoria: Bool) -> Conversation {
        let relleno = String(
            repeating: "Este mensaje forma parte de una conversacion larga que se va a resumir. ",
            count: 6
        )
        var mensajes: [ChatMessage] = []
        for vuelta in 0..<4 {
            mensajes.append(
                ChatMessage(rol: .usuario, texto: "Pregunta \(vuelta). \(relleno)")
            )
            mensajes.append(
                ChatMessage(rol: .asistente, texto: "Respuesta \(vuelta). \(relleno)")
            )
        }
        return Conversation(mensajes: mensajes, sinMemoria: sinMemoria)
    }

    /// Ocho mensajes con cuatro respuestas ya selladas a los precios de su
    /// proveedor. Es la historia larga que /compact parte en dos.
    ///
    /// Por que el relleno: /compact solo aplica el resumen si este reduce de
    /// verdad el contexto estimado (guarda de no-reduccion del plan firmado).
    /// Con textos de juguete ("Pregunta 0", "Respuesta 0") el resumen que
    /// devuelve el transporte nunca pesa menos que la historia original, la
    /// guarda descarta la compactacion y los tests de HP4 fallan por el
    /// fixture y no por el comportamiento. Cada texto lleva ~450 caracteres
    /// de relleno, igual que `historiaLarga`, para que resumir ahorre contexto
    /// medible. Los roles, el orden, los tokens y los sellos no cambian.
    private func historiaSellada(con proveedor: ProviderConfig) -> Conversation {
        let relleno = String(
            repeating: "Este mensaje forma parte de una conversacion larga que se va a resumir. ",
            count: 6
        )
        var mensajes: [ChatMessage] = []
        for vuelta in 0..<4 {
            mensajes.append(
                ChatMessage(rol: .usuario, texto: "Pregunta \(vuelta). \(relleno)")
            )
            var respuesta = ChatMessage(
                rol: .asistente,
                texto: "Respuesta \(vuelta). \(relleno)",
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
