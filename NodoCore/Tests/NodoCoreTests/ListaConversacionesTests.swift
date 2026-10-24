import XCTest

@testable import NodoCore

/// Reglas puras de la lista enriquecida y de ramificar (§5, Fase 5).
///
/// Los datos son genericos de prueba: ids, modelos y precios inventados. No se
/// usan claves ni conversaciones reales.
final class ListaConversacionesTests: XCTestCase {
    private let proveedorA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let proveedorB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let proveedorGlobal = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    // MARK: - Orden

    func testOrdenPoneFijadasPrimeroYDespuesPorActividad() {
        let fijadaVieja = Conversation(
            titulo: "fijada vieja",
            mensajes: [mensaje("fijada vieja", fecha: fecha(100))],
            fijada: true
        )
        let fijadaNueva = Conversation(
            titulo: "fijada nueva",
            mensajes: [mensaje("fijada nueva", fecha: fecha(400))],
            fijada: true
        )
        let reciente = Conversation(
            titulo: "reciente",
            mensajes: [mensaje("reciente", fecha: fecha(300))]
        )
        let antigua = Conversation(
            titulo: "antigua",
            mensajes: [mensaje("antigua", fecha: fecha(50))]
        )

        let ordenadas = HistorialConversaciones.ordenar(
            [antigua, reciente, fijadaVieja, fijadaNueva]
        )

        XCTAssertEqual(
            ordenadas.map(\.titulo),
            ["fijada nueva", "fijada vieja", "reciente", "antigua"]
        )
    }

    func testOrdenUsaLaFechaDelUltimoMensajeNoLaDeActualizacion() {
        let conMensajeNuevo = Conversation(
            titulo: "mensaje nuevo",
            mensajes: [mensaje("nuevo", fecha: fecha(900))],
            actualizada: fecha(100)
        )
        let conMensajeViejo = Conversation(
            titulo: "mensaje viejo",
            mensajes: [mensaje("viejo", fecha: fecha(200))],
            actualizada: fecha(1_000)
        )

        let ordenadas = HistorialConversaciones.ordenar(
            [conMensajeViejo, conMensajeNuevo]
        )

        XCTAssertEqual(ordenadas.map(\.titulo), ["mensaje nuevo", "mensaje viejo"])
    }

    func testUnChatVacioUsaLaFechaDeCreacion() {
        let creadaAntes = Conversation(
            titulo: "antes",
            creada: fecha(100),
            actualizada: fecha(100)
        )
        let creadaDespues = Conversation(
            titulo: "despues",
            creada: fecha(200),
            actualizada: fecha(200)
        )

        XCTAssertEqual(
            HistorialConversaciones.ordenar([creadaAntes, creadaDespues])
                .map(\.titulo),
            ["despues", "antes"]
        )
    }

    // MARK: - Segmentos

    func testElSegmentoFiltraSinMezclarActivosYArchivados() {
        let activa = Conversation(titulo: "activa", actualizada: fecha(200))
        let archivada = Conversation(
            titulo: "archivada",
            actualizada: fecha(300),
            archivada: true
        )

        let activos = HistorialConversaciones.enSegmento(
            .activos,
            de: [archivada, activa]
        )
        let archivados = HistorialConversaciones.enSegmento(
            .archivados,
            de: [archivada, activa]
        )

        XCTAssertEqual(activos.map(\.id), [activa.id])
        XCTAssertFalse(activos.contains { $0.id == archivada.id })
        XCTAssertEqual(archivados.map(\.id), [archivada.id])
        XCTAssertFalse(archivados.contains { $0.id == activa.id })
    }

    // MARK: - Datos de fila

    func testElProveedorDelChatSobreviveAlJSON() throws {
        let original = Conversation(
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")],
            proveedorID: proveedorA
        )
        let codificador = JSONEncoder()
        codificador.dateEncodingStrategy = .iso8601
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601

        let datos = try codificador.encode(original)
        let cargada = try decodificador.decode(Conversation.self, from: datos)

        XCTAssertEqual(cargada.proveedorID, proveedorA)
    }

    func testElCostoDeLaPastillaEsElAcumuladoDelChatConSusPrecios() throws {
        let proveedor = proveedorConfig(
            id: proveedorA,
            modelo: "vendedor/modelo-a",
            precioEntrada: 2,
            precioSalida: 8
        )
        let conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "uno", tokensEntrada: 1_000, tokensSalida: 0),
                ChatMessage(rol: .asistente, texto: "dos", tokensEntrada: 2_000, tokensSalida: 500)
            ],
            proveedorID: proveedorA
        )

        let uso = try XCTUnwrap(CostoEstimado.usoAcumulado(de: conversacion.mensajes))
        XCTAssertEqual(uso, UsoTokens(entrada: 3_000, salida: 500))

        let fila = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: [proveedor]
        )

        // (3.000 x 2 + 500 x 8) / 1.000.000 = 0,01
        let costo = try XCTUnwrap(fila.costo)
        XCTAssertEqual(costo, 0.01, accuracy: 0.0000001)
        XCTAssertEqual(fila.modelo, "modelo-a")
    }

    func testSinPreciosEnElProveedorDelChatNoHayPastilla() {
        let proveedor = proveedorConfig(
            id: proveedorA,
            modelo: "vendedor/modelo-a",
            precioEntrada: nil,
            precioSalida: nil
        )
        let conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .asistente, texto: "respuesta", tokensEntrada: 1_000, tokensSalida: 500)
            ],
            proveedorID: proveedorA
        )

        let fila = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: [proveedor]
        )

        XCTAssertNil(fila.costo)
    }

    func testElCostoNoUsaLosPreciosDeOtroProveedor() {
        let proveedorDelChat = proveedorConfig(
            id: proveedorA,
            modelo: "vendedor/modelo-a",
            precioEntrada: nil,
            precioSalida: nil
        )
        // Este otro proveedor tiene precios, pero no es el del chat.
        let proveedorConPrecios = proveedorConfig(
            id: proveedorB,
            modelo: "vendedor/modelo-b",
            precioEntrada: 1,
            precioSalida: 2
        )
        let conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .asistente, texto: "respuesta", tokensEntrada: 1_000, tokensSalida: 500)
            ],
            proveedorID: proveedorA
        )

        let fila = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: [proveedorDelChat, proveedorConPrecios]
        )

        XCTAssertNil(fila.costo)
    }

    func testLaEtiquetaEsElModeloDelProveedorDeCadaConversacion() {
        let proveedorA = proveedorConfig(
            id: self.proveedorA,
            modelo: "vendedor/alfa",
            precioEntrada: 1,
            precioSalida: 2
        )
        let proveedorB = proveedorConfig(
            id: self.proveedorB,
            modelo: "vendedor/beta",
            precioEntrada: 1,
            precioSalida: 2
        )
        // Tercer proveedor: es el activo global de la app, pero no el de
        // ninguna de las dos conversaciones.
        let proveedorGlobal = proveedorConfig(
            id: self.proveedorGlobal,
            modelo: "vendedor/global",
            precioEntrada: 1,
            precioSalida: 2
        )

        let chatA = Conversation(
            mensajes: [ChatMessage(rol: .asistente, texto: "a")],
            proveedorID: self.proveedorA
        )
        let chatB = Conversation(
            mensajes: [ChatMessage(rol: .asistente, texto: "b")],
            proveedorID: self.proveedorB
        )
        let proveedores = [proveedorA, proveedorB, proveedorGlobal]

        XCTAssertEqual(
            HistorialConversaciones.datosFila(de: chatA, proveedores: proveedores).modelo,
            "alfa"
        )
        XCTAssertEqual(
            HistorialConversaciones.datosFila(de: chatB, proveedores: proveedores).modelo,
            "beta"
        )
    }

    func testSinProveedorResolubleLaEtiquetaQuedaVacia() {
        let conversacion = Conversation(
            mensajes: [ChatMessage(rol: .asistente, texto: "hola")]
        )

        let fila = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: [
                proveedorConfig(
                    id: proveedorA,
                    modelo: "vendedor/alfa",
                    precioEntrada: 1,
                    precioSalida: 2
                )
            ]
        )

        XCTAssertEqual(fila.modelo, "")
    }

    func testLaVistaPreviaEsElUltimoMensajeEnUnaLinea() {
        let conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "primero"),
                ChatMessage(rol: .asistente, texto: "linea uno\nlinea dos")
            ]
        )

        let fila = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: []
        )

        XCTAssertEqual(fila.vistaPrevia, "linea uno linea dos")
    }

    // MARK: - Ramificar

    func testRamificarClonaExactamenteHastaElPuntoElegido() throws {
        let original = conversacionLarga()

        let copia = try XCTUnwrap(
            HistorialConversaciones.ramificar(
                original,
                hastaElMensaje: original.mensajes[2].id
            )
        )

        XCTAssertNotEqual(copia.id, original.id)
        XCTAssertEqual(copia.titulo, "Conversacion")
        XCTAssertEqual(copia.mensajes.count, 3)
        XCTAssertEqual(
            copia.mensajes.map(\.texto),
            original.mensajes.prefix(3).map(\.texto)
        )
        XCTAssertFalse(copia.mensajes.contains { $0.id == original.mensajes[3].id })
    }

    func testLaCopiaEsIndependienteYConservaElContenidoClonado() throws {
        let original = conversacionLarga()
        var copia = try XCTUnwrap(original.ramificar(hastaElMensaje: original.mensajes[2].id))

        XCTAssertEqual(Set(copia.mensajes.map(\.id)).count, 3)
        XCTAssertTrue(copia.mensajes.allSatisfy { mensaje in
            !original.mensajes.prefix(3).contains { $0.id == mensaje.id }
        })
        XCTAssertEqual(copia.mensajes.map(\.rol), Array(original.mensajes.prefix(3).map(\.rol)))
        XCTAssertEqual(copia.mensajes.map(\.texto), Array(original.mensajes.prefix(3).map(\.texto)))
        XCTAssertEqual(copia.mensajes.map(\.uso), Array(original.mensajes.prefix(3).map(\.uso)))
        XCTAssertEqual(
            copia.mensajes.map(\.skillsAplicadas),
            Array(original.mensajes.prefix(3).map(\.skillsAplicadas))
        )

        // Value semantics: mutar la copia no toca la original.
        copia.mensajes[0].texto = "texto cambiado en la copia"
        copia.mensajes.append(ChatMessage(rol: .usuario, texto: "solo en la copia"))

        XCTAssertEqual(original.mensajes.count, 5)
        XCTAssertEqual(original.mensajes[0].texto, "mensaje 1")
        XCTAssertEqual(copia.mensajes.count, 4)
    }

    func testRamificarHeredaProveedorModosYResumenCompactado() throws {
        let original = conversacionLarga()

        let copia = try XCTUnwrap(
            HistorialConversaciones.ramificar(
                la: original,
                hastaElMensaje: original.mensajes[2].id
            )
        )

        XCTAssertEqual(copia.proveedorID, original.proveedorID)
        XCTAssertEqual(copia.sinMemoria, original.sinMemoria)
        XCTAssertEqual(copia.modoTarea, original.modoTarea)
        XCTAssertFalse(copia.fijada)
        XCTAssertFalse(copia.archivada)
        // COMP.3: la rama no puede olvidar lo que la original ya resumio.
        XCTAssertEqual(copia.resumenCompactado, original.resumenCompactado)
        XCTAssertEqual(copia.usoTrasCompactar, original.usoTrasCompactar)
    }

    func testElAcumuladoDeLaRamaEsLaSumaDeLosUsosClonados() throws {
        let original = conversacionLarga()
        let copia = try XCTUnwrap(
            HistorialConversaciones.ramificar(
                original,
                hastaElMensaje: original.mensajes[2].id
            )
        )
        let proveedor = proveedorConfig(
            id: proveedorA,
            modelo: "vendedor/alfa",
            precioEntrada: 3,
            precioSalida: 10
        )

        let usoClonado = try XCTUnwrap(
            CostoEstimado.usoAcumulado(de: copia.mensajes)
        )
        XCTAssertEqual(usoClonado, UsoTokens(entrada: 600, salida: 50))

        let fila = HistorialConversaciones.datosFila(
            de: copia,
            proveedores: [proveedor]
        )
        let costo = try XCTUnwrap(fila.costo)
        // (600 x 3 + 50 x 10) / 1.000.000 = 0,0023
        XCTAssertEqual(costo, 0.0023, accuracy: 0.0000001)
    }

    func testRamificarConUnMensajeInexistenteDevuelveNil() {
        let original = conversacionLarga()

        XCTAssertNil(
            HistorialConversaciones.ramificar(
                original,
                hastaElMensaje: UUID()
            )
        )
    }

    /// COST.1: la pastilla de la fila lee el SELLO del mensaje. Subir los
    /// precios del proveedor despues del turno no puede cambiar lo ya pagado.
    func testLaPastillaLeeElSelloYNoSeRevaluaConLosPreciosNuevos() throws {
        let proveedor = proveedorConfig(
            id: proveedorA,
            modelo: "vendedor/modelo-a",
            precioEntrada: 2,
            precioSalida: 8
        )
        let conversacion = Conversation(
            mensajes: [
                ChatMessage(
                    rol: .asistente,
                    texto: "respuesta sellada",
                    tokensEntrada: 1_000,
                    tokensSalida: 500,
                    proveedorID: proveedorA,
                    costoSelladoUSD: 0.004
                )
            ],
            proveedorID: proveedorA
        )

        let fila = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: [proveedor]
        )

        let costo = try XCTUnwrap(fila.costo)
        XCTAssertEqual(costo, 0.004, accuracy: 0.0000001)
    }

    // MARK: - Ayudas

    private func conversacionLarga() -> Conversation {
        Conversation(
            titulo: "Original",
            mensajes: [
                ChatMessage(
                    rol: .usuario,
                    texto: "mensaje 1",
                    fecha: fecha(100),
                    tokensEntrada: 100,
                    tokensSalida: 0,
                    skillsAplicadas: ["Resumen"]
                ),
                ChatMessage(
                    rol: .asistente,
                    texto: "mensaje 2",
                    fecha: fecha(200),
                    tokensEntrada: 200,
                    tokensSalida: 50
                ),
                ChatMessage(
                    rol: .usuario,
                    texto: "mensaje 3",
                    fecha: fecha(300),
                    tokensEntrada: 300,
                    tokensSalida: 0
                ),
                ChatMessage(
                    rol: .asistente,
                    texto: "mensaje 4",
                    fecha: fecha(400),
                    tokensEntrada: 400,
                    tokensSalida: 100
                ),
                ChatMessage(
                    rol: .usuario,
                    texto: "mensaje 5",
                    fecha: fecha(500),
                    tokensEntrada: 500,
                    tokensSalida: 0
                )
            ],
            fijada: true,
            archivada: true,
            sinMemoria: true,
            modoTarea: true,
            resumenCompactado: "Resumen viejo",
            usoTrasCompactar: UsoTokens(entrada: 999, salida: 111),
            proveedorID: proveedorA
        )
    }

    private func mensaje(_ texto: String, fecha: Date) -> ChatMessage {
        ChatMessage(rol: .usuario, texto: texto, fecha: fecha)
    }

    private func proveedorConfig(
        id: UUID,
        modelo: String,
        precioEntrada: Double?,
        precioSalida: Double?
    ) -> ProviderConfig {
        ProviderConfig(
            id: id,
            nombre: "Proveedor de prueba",
            baseURL: "https://api.ejemplo.test/v1",
            modelo: modelo,
            precioEntradaPorMillon: precioEntrada,
            precioSalidaPorMillon: precioSalida
        )
    }

    private func fecha(_ segundos: TimeInterval) -> Date {
        Date(timeIntervalSince1970: segundos)
    }
}
