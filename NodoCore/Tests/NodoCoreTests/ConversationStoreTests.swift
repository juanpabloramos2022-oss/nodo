import XCTest

@testable import NodoCore

final class ConversationStoreTests: XCTestCase {
    private var directorio: URL!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        directorio = Ayudas.directorioTemporal()
        store = try ConversationStore(directorio: directorio)
    }

    override func tearDownWithError() throws {
        if let directorio {
            try? FileManager.default.removeItem(at: directorio)
        }
    }

    func testGuardaYCarga() throws {
        let conversacion = Conversation(
            titulo: "Prueba",
            mensajes: [ChatMessage(rol: .usuario, texto: "hola")]
        )
        try store.guardar(conversacion)

        let cargada = try XCTUnwrap(store.cargar(id: conversacion.id))
        XCTAssertEqual(cargada.id, conversacion.id)
        XCTAssertEqual(cargada.titulo, "Prueba")
        XCTAssertEqual(cargada.mensajes.count, 1)
        XCTAssertEqual(cargada.mensajes.first?.texto, "hola")
    }

    func testListaOrdenadaPorFechaDescendente() throws {
        let vieja = Conversation(
            titulo: "vieja",
            actualizada: Date(timeIntervalSince1970: 1_000)
        )
        let nueva = Conversation(
            titulo: "nueva",
            actualizada: Date(timeIntervalSince1970: 2_000)
        )
        try store.guardar(vieja)
        try store.guardar(nueva)

        let lista = store.listar()
        XCTAssertEqual(lista.map(\.titulo), ["nueva", "vieja"])
    }

    func testBorrarNoAfectaALasDemas() throws {
        let una = Conversation(titulo: "una")
        let otra = Conversation(titulo: "otra")
        try store.guardar(una)
        try store.guardar(otra)

        try store.borrar(id: una.id)

        XCTAssertNil(store.cargar(id: una.id))
        XCTAssertNotNil(store.cargar(id: otra.id))
        XCTAssertEqual(store.listar().count, 1)
    }

    func testArchivoCorruptoNoRompeLaLista() throws {
        try store.guardar(Conversation(titulo: "buena"))

        let rutaMala = directorio.appendingPathComponent("\(UUID().uuidString).json")
        try Data("esto no es json".utf8).write(to: rutaMala)

        let lista = store.listar()
        XCTAssertEqual(lista.count, 1)
        XCTAssertEqual(lista.first?.titulo, "buena")
    }

    func testCargarArchivoCorruptoDevuelveNil() throws {
        let id = UUID()
        let rutaMala = directorio.appendingPathComponent("\(id.uuidString).json")
        try Data("{ roto".utf8).write(to: rutaMala)

        XCTAssertNil(store.cargar(id: id))
    }

    func testCargarInexistenteDevuelveNil() {
        XCTAssertNil(store.cargar(id: UUID()))
    }

    func testBorrarInexistenteNoLanza() {
        XCTAssertNoThrow(try store.borrar(id: UUID()))
    }

    func testCreaElDirectorioSiNoExiste() throws {
        let nuevo = Ayudas.directorioTemporal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: nuevo.path))

        let otroStore = try ConversationStore(directorio: nuevo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nuevo.path))
        XCTAssertEqual(otroStore.listar().count, 0)

        try? FileManager.default.removeItem(at: nuevo)
    }

    func testTituloSugeridoSaleDelPrimerMensaje() {
        let conversacion = Conversation(mensajes: [
            ChatMessage(rol: .sistema, texto: "prompt"),
            ChatMessage(rol: .usuario, texto: "Como hago pan\ncon masa madre")
        ])

        XCTAssertEqual(conversacion.tituloSugerido, "Como hago pan con masa madre")
    }

    func testTituloSugeridoSeRecorta() {
        let largo = String(repeating: "a", count: 200)
        let conversacion = Conversation(mensajes: [ChatMessage(rol: .usuario, texto: largo)])

        XCTAssertTrue(conversacion.tituloSugerido.hasSuffix("..."))
        XCTAssertLessThanOrEqual(conversacion.tituloSugerido.count, 51)
    }

    func testTituloSugeridoSinMensajes() {
        XCTAssertEqual(Conversation().tituloSugerido, "Conversacion")
    }

    func testDescartarUltimoTurnoSimple() {
        var conversacion = Conversation(mensajes: [
            ChatMessage(rol: .usuario, texto: "hola"),
            ChatMessage(rol: .asistente, texto: "buenas")
        ])

        let descartado = conversacion.descartarUltimoTurno()

        XCTAssertEqual(conversacion.mensajes.map(\.rol), [.usuario])
        XCTAssertEqual(conversacion.mensajes.first?.texto, "hola")
        XCTAssertEqual(descartado.map(\.rol), [.asistente])
        XCTAssertEqual(descartado.first?.texto, "buenas")
    }

    func testDescartarUltimoTurnoConHerramientas() {
        var conversacion = Conversation(mensajes: [
            ChatMessage(rol: .usuario, texto: "busca el precio"),
            ChatMessage(
                rol: .asistente,
                texto: "",
                toolCalls: [ToolCall(id: "llamada-1", nombre: "red", argumentos: "{}")]
            ),
            ChatMessage(rol: .herramienta, texto: "42", toolCallId: "llamada-1"),
            ChatMessage(rol: .asistente, texto: "Cuesta 42.")
        ])

        let descartado = conversacion.descartarUltimoTurno()

        XCTAssertEqual(conversacion.mensajes.map(\.rol), [.usuario])
        XCTAssertEqual(descartado.map(\.rol), [.asistente, .herramienta, .asistente])
    }

    func testDescartarUltimoTurnoSinRespuestaNoCambiaNada() {
        let mensajes = [ChatMessage(rol: .usuario, texto: "hola")]
        var conversacion = Conversation(mensajes: mensajes)

        let descartado = conversacion.descartarUltimoTurno()

        XCTAssertTrue(descartado.isEmpty)
        XCTAssertEqual(conversacion.mensajes, mensajes)
    }

    // MARK: - Fijar, archivar y buscar

    /// Un archivo tal como lo escribia v0.1.0, sin fijada ni archivada.
    func testJSONDeV010SinCamposNuevosSigueAbriendo() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "titulo": "Conversacion antigua",
          "mensajes": [
            {
              "id": "\(UUID().uuidString)",
              "rol": "usuario",
              "texto": "hola desde la version anterior",
              "fecha": "2024-01-01T10:00:00Z",
              "toolCalls": []
            }
          ],
          "creada": "2024-01-01T10:00:00Z",
          "actualizada": "2024-01-01T10:05:00Z"
        }
        """
        let ruta = directorio.appendingPathComponent("\(id.uuidString).json")
        try Data(json.utf8).write(to: ruta)

        XCTAssertEqual(store.listar().map(\.id), [id])
        let cargada = try XCTUnwrap(store.cargar(id: id))

        XCTAssertEqual(cargada.titulo, "Conversacion antigua")
        XCTAssertEqual(cargada.mensajes.first?.texto, "hola desde la version anterior")
        XCTAssertFalse(cargada.fijada)
        XCTAssertFalse(cargada.archivada)
    }

    func testFijadaYArchivadaSobrevivenAGuardarYCargar() throws {
        let conversacion = Conversation(
            titulo: "Con marcadores",
            fijada: true,
            archivada: true
        )
        try store.guardar(conversacion)

        let cargada = try XCTUnwrap(store.cargar(id: conversacion.id))

        XCTAssertTrue(cargada.fijada)
        XCTAssertTrue(cargada.archivada)
    }

    func testSeccionesPoneFijadasPrimeroYDejaFueraLasArchivadas() {
        let fijadaVieja = Conversation(
            titulo: "fijada vieja",
            actualizada: fecha(1_000),
            fijada: true
        )
        let fijadaNueva = Conversation(
            titulo: "fijada nueva",
            actualizada: fecha(2_000),
            fijada: true
        )
        let antigua = Conversation(titulo: "antigua", actualizada: fecha(3_000))
        let reciente = Conversation(titulo: "reciente", actualizada: fecha(4_000))
        let archivada = Conversation(
            titulo: "archivada",
            actualizada: fecha(5_000),
            archivada: true
        )

        let secciones = HistorialConversaciones.secciones(
            de: [antigua, archivada, reciente, fijadaVieja, fijadaNueva]
        )

        XCTAssertEqual(secciones.fijadas.map(\.titulo), ["fijada nueva", "fijada vieja"])
        XCTAssertEqual(secciones.recientes.map(\.titulo), ["reciente", "antigua"])
        XCTAssertEqual(secciones.archivadas.map(\.titulo), ["archivada"])
        XCTAssertEqual(
            secciones.principales.map(\.titulo),
            ["fijada nueva", "fijada vieja", "reciente", "antigua"]
        )
        XCTAssertFalse(secciones.principales.contains { $0.id == archivada.id })
    }

    func testBusquedaEncuentraPorTextoDeMensajeYNoSoloPorTitulo() {
        let porMensaje = Conversation(
            titulo: "Receta",
            mensajes: [ChatMessage(rol: .usuario, texto: "Como hago masa madre")]
        )
        let porTitulo = Conversation(
            titulo: "Masa madre facil",
            mensajes: [ChatMessage(rol: .usuario, texto: "otra cosa")]
        )
        let ajeno = Conversation(
            titulo: "Viaje",
            mensajes: [ChatMessage(rol: .usuario, texto: "billetes")]
        )

        let secciones = HistorialConversaciones.secciones(
            de: [porMensaje, porTitulo, ajeno],
            busqueda: "masa"
        )

        XCTAssertEqual(
            Set(secciones.principales.map(\.id)),
            Set([porMensaje.id, porTitulo.id])
        )
        XCTAssertFalse(secciones.principales.contains { $0.id == ajeno.id })
    }

    func testBusquedaDentroDeArchivadasNoLasDevuelveEnLaPrincipal() {
        let archivada = Conversation(
            titulo: "Vieja",
            mensajes: [ChatMessage(rol: .usuario, texto: "un secreto de masa")],
            archivada: true
        )

        let secciones = HistorialConversaciones.secciones(
            de: [archivada],
            busqueda: "secreto"
        )

        XCTAssertTrue(secciones.principales.isEmpty)
        XCTAssertEqual(secciones.archivadas.map(\.id), [archivada.id])
    }

    private func fecha(_ segundos: TimeInterval) -> Date {
        Date(timeIntervalSince1970: segundos)
    }
}
