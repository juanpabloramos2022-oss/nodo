import XCTest

@testable import NodoCore

/// Pruebas del Chat Temporal (B2.2) en el nucleo.
///
/// El modo temporal NO es una bandera de interfaz: tiene un camino de payload
/// propio (ni bloque de Memoria ni herramientas de escritura) y un camino de
/// salida propio (no llega nunca al almacen). Estas pruebas fijan las dos
/// reglas donde viven —`Conversation.usaMemoriaEnPayload` y
/// `Conversation.sePersiste`— y las comprueban sobre el payload construido y
/// sobre el disco, no sobre el nombre de la bandera.
final class ChatTemporalTests: XCTestCase {
    private let idUno = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let idDos = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func semilla() -> [EntradaMemoria] {
        [
            EntradaMemoria(
                id: idUno,
                texto: "Prefiere respuestas cortas",
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

    private func conversacion(
        sinMemoria: Bool = false,
        esTemporal: Bool = false
    ) -> Conversation {
        Conversation(
            titulo: "Chat",
            mensajes: [
                ChatMessage(rol: .usuario, texto: "hola"),
                ChatMessage(rol: .asistente, texto: "que tal")
            ],
            sinMemoria: sinMemoria,
            esTemporal: esTemporal
        )
    }

    // MARK: - Las dos reglas

    func testLaTablaDeVerdadDeLosDosCaminos() {
        // Un chat normal usa Memoria y se persiste.
        let normal = conversacion()
        XCTAssertTrue(normal.usaMemoriaEnPayload)
        XCTAssertTrue(normal.sePersiste)

        // El toggle sin memoria de siempre: sin bloque, pero se sigue guardando.
        let sinMemoria = conversacion(sinMemoria: true)
        XCTAssertFalse(sinMemoria.usaMemoriaEnPayload)
        XCTAssertTrue(sinMemoria.sePersiste)

        // El temporal no usa Memoria aunque su bandera de sin memoria este en
        // false: son dos modos distintos y el temporal manda.
        let temporal = conversacion(esTemporal: true)
        XCTAssertFalse(temporal.usaMemoriaEnPayload)
        XCTAssertFalse(temporal.sePersiste)
        XCTAssertFalse(temporal.sinMemoria, "El temporal no reutiliza la bandera")

        let temporalSinMemoria = conversacion(sinMemoria: true, esTemporal: true)
        XCTAssertFalse(temporalSinMemoria.usaMemoriaEnPayload)
        XCTAssertFalse(temporalSinMemoria.sePersiste)
    }

    // MARK: - Camino de payload

    func testElHiloTemporalNoInyectaNingunaEntradaDeMemoria() {
        let memoria = semilla()
        let historial = Historial.paraEnviar(
            conversacion: conversacion(esTemporal: true),
            memoria: memoria
        )

        XCTAssertEqual(historial.count, 2, "Solo los mensajes del hilo")
        XCTAssertFalse(historial.contains { $0.rol == .sistema })
        for entrada in memoria {
            XCTAssertFalse(
                historial.contains { $0.texto.contains(entrada.texto) },
                "El hilo temporal inyecto la entrada \(entrada.id)"
            )
            XCTAssertFalse(
                historial.contains { $0.texto.contains(entrada.id.uuidString) },
                "El hilo temporal inyecto un id de entrada"
            )
        }
        XCTAssertFalse(
            historial.contains { $0.texto.contains(Memoria.cabeceraBloque) }
        )
    }

    /// Contraste positivo: el mismo guion en un chat normal si lleva bloque,
    /// con sus ids y categorias, y conserva el toggle sin memoria intacto.
    func testElMismoGuionEnUnChatNormalSiLlevaElBloque() {
        let memoria = semilla()
        let normal = Historial.paraEnviar(
            conversacion: conversacion(),
            memoria: memoria
        )

        XCTAssertEqual(normal.count, 3)
        XCTAssertEqual(normal.first?.rol, .sistema)
        XCTAssertEqual(normal.first?.texto, Memoria.bloqueSistema(entradas: memoria))
        for entrada in memoria {
            XCTAssertTrue(normal.first?.texto.contains(entrada.id.uuidString) == true)
            XCTAssertTrue(normal.first?.texto.contains(entrada.texto) == true)
        }

        // Y el chat normal sin memoria sigue como en la v0.3.1: sin bloque.
        let sinMemoria = Historial.paraEnviar(
            conversacion: conversacion(sinMemoria: true),
            memoria: memoria
        )
        XCTAssertFalse(sinMemoria.contains { $0.rol == .sistema })
    }

    // MARK: - Camino de salida

    func testElAlmacenRechazaUnHiloTemporalYNoEscribeNada() throws {
        let directorio = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodoTemporal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directorio) }
        let store = try ConversationStore(directorio: directorio)

        let temporal = conversacion(esTemporal: true)

        XCTAssertThrowsError(try store.guardar(temporal)) { error in
            XCTAssertEqual(
                error as? ErrorConversationStore,
                ErrorConversationStore.conversacionTemporal
            )
        }
        XCTAssertTrue(store.listar().isEmpty)
        XCTAssertNil(store.cargar(id: temporal.id))
        let archivos = try FileManager.default.contentsOfDirectory(
            atPath: directorio.path
        )
        XCTAssertTrue(archivos.isEmpty, "El hilo temporal dejo archivo: \(archivos)")

        // Contraste: el mismo contenido en un chat normal si se guarda.
        var normal = temporal
        normal.esTemporal = false
        try store.guardar(normal)
        XCTAssertEqual(store.listar().map(\.id), [normal.id])
    }

    // MARK: - Codificacion

    func testUnJSONViejoDecodificaComoTemporalFalse() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "titulo": "Vieja",
          "mensajes": [],
          "creada": 0.0,
          "actualizada": 0.0
        }
        """

        let conversacion = try JSONDecoder().decode(
            Conversation.self,
            from: Data(json.utf8)
        )

        XCTAssertFalse(conversacion.esTemporal)
        XCTAssertTrue(conversacion.sePersiste)
    }

    func testLaMarcaTemporalSobreviveAlJSON() throws {
        let original = conversacion(esTemporal: true)
        let vuelta = try JSONDecoder().decode(
            Conversation.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertTrue(vuelta.esTemporal)
        XCTAssertFalse(vuelta.sePersiste)
    }
}
