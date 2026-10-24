import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas del Chat Temporal (B2.2) en la capa app.
///
/// El modo temporal es un MODO propio, no el toggle «sin memoria» renombrado.
/// Estas pruebas lo demuestran por comportamiento: el payload de la peticion
/// HTTP no ofrece ninguna herramienta de Memoria ni inyecta entradas, y tras
/// crear, enviar y cerrar el hilo no queda nada en la lista de conversaciones,
/// ni en Mi Contexto, ni en el disco, ni en el respaldo. El contraste positivo
/// (el mismo guion en un chat normal si ofrece las tres herramientas) va en
/// cada caso para que el cero no pueda venir de un arnes roto.
@MainActor
final class ChatTemporalTests: XCTestCase {
    private let idUno = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let idDos = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    private let promptDurable =
        "Mi palabra clave de prueba es LUNA-7 y prefiero respuestas cortas, úsalo en esta conversación"

    private func semilla() -> [EntradaMemoria] {
        [
            EntradaMemoria(
                id: idUno,
                texto: "Prefiere respuestas breves",
                fecha: Date(timeIntervalSince1970: 100),
                categoria: .preference
            ),
            EntradaMemoria(
                id: idDos,
                texto: "Vive en una ciudad de prueba",
                fecha: Date(timeIntervalSince1970: 200),
                categoria: .durableFact
            )
        ]
    }

    // MARK: - Nivel 1: payload del hilo temporal

    func testElPayloadDeUnHiloTemporalNoOfreceHerramientasNiInyectaEntradas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Entendido: LUNA-7, respuestas cortas.",
            uso: UsoTokens(entrada: 50, salida: 9)
        )

        arnes.estado.nuevaConversacionTemporal()
        XCTAssertTrue(arnes.estado.hiloTemporal)
        XCTAssertFalse(
            arnes.estado.conversacion.sinMemoria,
            "El hilo temporal no reutiliza la bandera del toggle sin memoria"
        )

        arnes.estado.enviar(promptDurable)
        try await arnes.esperarTurno()

        let cuerpo = try cuerpoDeLaPeticion(arnes, indice: 0)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        )

        // `tools` no viaja: el cliente omite la clave cuando no se ofrece
        // ninguna herramienta. Si viajara, tendria que estar vacia.
        let herramientas = (json["tools"] as? [[String: Any]]) ?? []
        XCTAssertTrue(
            herramientas.isEmpty,
            "El hilo temporal ofrecio herramientas: \(herramientas)"
        )
        for nombre in [
            Memoria.nombreGuardar,
            Memoria.nombreActualizar,
            Memoria.nombreProponerSensible,
            Memoria.nombreBorrar
        ] {
            XCTAssertFalse(cuerpo.contains(nombre), "El payload cita \(nombre)")
        }

        // Ni bloque de sistema ni entradas guardadas.
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertFalse(
            mensajes.contains { $0["role"] as? String == "system" },
            "El hilo temporal inyecto un bloque de sistema"
        )
        for entrada in semilla() {
            XCTAssertFalse(cuerpo.contains(entrada.texto), cuerpo)
            XCTAssertFalse(cuerpo.contains(entrada.id.uuidString), cuerpo)
        }

        // Mi Contexto queda exactamente igual y el hilo no llego a la lista.
        XCTAssertEqual(arnes.estado.config.memoria, semilla())
        XCTAssertTrue(arnes.estado.conversaciones.isEmpty)
        XCTAssertEqual(archivosDeConversaciones(arnes), 0)

        // El turno si ocurrio con normalidad.
        XCTAssertEqual(arnes.estado.conversacion.mensajes.count, 2)
    }

    /// Contraste positivo: el MISMO guion en un chat normal ofrece las tres
    /// herramientas tipadas y lleva el bloque con sus entradas.
    func testElMismoGuionEnUnChatNormalSiOfreceLasTresHerramientas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Entendido.",
            uso: UsoTokens(entrada: 50, salida: 3)
        )

        arnes.estado.nuevaConversacion()
        XCTAssertFalse(arnes.estado.hiloTemporal)
        arnes.estado.enviar(promptDurable)
        try await arnes.esperarTurno()

        let cuerpo = try cuerpoDeLaPeticion(arnes, indice: 0)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        )
        let herramientas = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let nombres = herramientas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(
            nombres,
            [
                Memoria.nombreGuardar,
                Memoria.nombreActualizar,
                Memoria.nombreBorrar
            ]
        )
        XCTAssertTrue(cuerpo.contains(Memoria.cabeceraBloque), cuerpo)
        XCTAssertTrue(cuerpo.contains(idUno.uuidString), cuerpo)

        // El chat normal si se persiste: es la diferencia con el temporal.
        XCTAssertEqual(arnes.estado.conversaciones.count, 1)
        XCTAssertEqual(archivosDeConversaciones(arnes), 1)
    }

    // MARK: - Nivel 1: salida sin rastro

    func testTrasCrearEnviarYCerrarUnHiloTemporalNadaCambia() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let conversacionesAntes = arnes.estado.conversaciones
        let memoriaAntes = arnes.estado.config.memoria
        let archivosAntes = archivosDeConversaciones(arnes)

        arnes.transporte.guionar(
            texto: "Entendido: LUNA-7.",
            uso: UsoTokens(entrada: 40, salida: 5)
        )
        arnes.estado.nuevaConversacionTemporal()
        let idTemporal = arnes.estado.conversacion.id
        arnes.estado.enviar(promptDurable)
        try await arnes.esperarTurno()

        // A mitad del hilo tampoco hay rastro.
        XCTAssertEqual(arnes.estado.conversaciones, conversacionesAntes)
        XCTAssertEqual(archivosDeConversaciones(arnes), archivosAntes)

        arnes.estado.borrador = "borrador que no debe sobrevivir"
        arnes.estado.cerrarHiloTemporal()

        XCTAssertFalse(arnes.estado.hiloTemporal)
        XCTAssertEqual(arnes.estado.conversaciones, conversacionesAntes)
        XCTAssertEqual(arnes.estado.config.memoria, memoriaAntes)
        XCTAssertEqual(archivosDeConversaciones(arnes), archivosAntes)
        XCTAssertEqual(arnes.estado.borrador, "", "El borrador se borra al cerrar")
        XCTAssertNil(
            arnes.estado.conversaciones.first { $0.id == idTemporal },
            "El hilo temporal no puede quedar en la lista"
        )
    }

    func testElBorradorDeUnChatNormalConservaSuComportamiento() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        // Un chat normal: el borrador se limpia al abrir otro chat, como hoy.
        arnes.estado.nuevaConversacion()
        arnes.estado.borrador = "texto a medias"
        arnes.estado.nuevaConversacion()
        XCTAssertEqual(arnes.estado.borrador, "")

        // Y el chat normal no se vuelve temporal al abrirlo.
        XCTAssertFalse(arnes.estado.hiloTemporal)
    }

    func testAlternarChatTemporalEsUnToqueAntesDelPrimerMensaje() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.nuevaConversacion()

        XCTAssertTrue(arnes.estado.alternarChatTemporal())
        XCTAssertTrue(arnes.estado.hiloTemporal)
        XCTAssertTrue(arnes.estado.alternarChatTemporal())
        XCTAssertFalse(arnes.estado.hiloTemporal)

        // Con el primer mensaje enviado el modo queda fijado: el indicador
        // sigue en la cabecera y no hay alternancia.
        arnes.estado.alternarChatTemporal()
        arnes.transporte.guionar(
            texto: "Listo.",
            uso: UsoTokens(entrada: 20, salida: 2)
        )
        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        XCTAssertTrue(arnes.estado.hiloTemporal)
        XCTAssertFalse(arnes.estado.alternarChatTemporal())
        XCTAssertTrue(arnes.estado.hiloTemporal)
        XCTAssertEqual(archivosDeConversaciones(arnes), 0)
    }

    func testArchivarFijarRenombrarYRamificarUnHiloTemporalNoEscribenNada() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Listo.",
            uso: UsoTokens(entrada: 20, salida: 2)
        )
        arnes.estado.nuevaConversacionTemporal()
        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let temporal = arnes.estado.conversacion
        arnes.estado.archivar(temporal)
        arnes.estado.fijar(temporal)
        arnes.estado.renombrar(temporal, titulo: "Renombrado")
        if let mensaje = temporal.mensajes.first {
            arnes.estado.ramificar(desde: mensaje)
        }

        XCTAssertEqual(archivosDeConversaciones(arnes), 0)
        XCTAssertTrue(arnes.estado.conversaciones.isEmpty)
        XCTAssertTrue(arnes.estado.hiloTemporal, "Nada de eso cierra el hilo")
    }

    func testElRespaldoTotalNoLlevaNingunHiloTemporal() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Listo.",
            uso: UsoTokens(entrada: 20, salida: 2)
        )
        arnes.estado.nuevaConversacionTemporal()
        let idTemporal = arnes.estado.conversacion.id
        arnes.estado.enviar(promptDurable)
        try await arnes.esperarTurno()

        let respaldo = arnes.estado.hacerRespaldoTotal()
        XCTAssertTrue(respaldo.conversaciones.isEmpty)
        let datos = try XCTUnwrap(arnes.estado.exportarRespaldo())
        let texto = try XCTUnwrap(String(data: datos, encoding: .utf8))
        XCTAssertFalse(texto.contains(idTemporal.uuidString))
        XCTAssertFalse(texto.contains("LUNA-7"))
    }

    func testUnTurnoFallidoEnUnHiloTemporalTampocoEscribe() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.estado.nuevaConversacionTemporal()

        // Sin guion el transporte lanza: el turno falla y el error se publica.
        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        XCTAssertNotNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(archivosDeConversaciones(arnes), 0)
        XCTAssertTrue(arnes.estado.conversaciones.isEmpty)
    }

    /// Cerrar el hilo con el turno en el aire no puede guardar nada.
    ///
    /// Es la carrera del camino de salida: el turno cancelado intenta persistir
    /// cuando el hilo abierto ya es otro. Sin la guarda de id, el catch
    /// guardaria un chat normal vacio en la lista y el hilo temporal dejaria
    /// rastro por la puerta de atras.
    func testCerrarElHiloConElTurnoEnCursoNoDejaArchivo() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.retenerStream(en: 1)
        arnes.transporte.guionar(
            texto: "Respuesta tardia.",
            uso: UsoTokens(entrada: 10, salida: 3)
        )

        arnes.estado.nuevaConversacionTemporal()
        arnes.estado.enviar("Hola")

        // El turno esta retenido en la red: cerrar el hilo lo cancela y deja
        // abierto un chat normal vacio.
        arnes.estado.cerrarHiloTemporal()
        arnes.transporte.liberarStreamRetenido()
        // Se deja correr la tarea cancelada para que su catch llegue a
        // ejecutarse; la asercion es que aun asi no escribe nada.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(archivosDeConversaciones(arnes), 0)
        XCTAssertTrue(arnes.estado.conversaciones.isEmpty)
    }

    // MARK: - Ayudas

    private func archivosDeConversaciones(_ arnes: ArnesApp) -> Int {
        let nombres = (try? FileManager.default.contentsOfDirectory(
            atPath: arnes.directorioStore.path
        )) ?? []
        return nombres.filter { $0.hasSuffix(".json") }.count
    }

    private func cuerpoDeLaPeticion(_ arnes: ArnesApp, indice: Int) throws -> String {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }
}
