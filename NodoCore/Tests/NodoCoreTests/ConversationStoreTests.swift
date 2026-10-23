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
}
