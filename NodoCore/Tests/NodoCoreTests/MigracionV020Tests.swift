import XCTest

@testable import NodoCore

/// Migracion desde el esquema de almacenamiento de la v0.2.0 (SPEC §5, Fase 4).
///
/// Los valores son de PRUEBA y genericos: en CI nunca entran datos de una
/// persona real. El objetivo es que una configuracion y una conversacion
/// guardadas por la version anterior se abran sin perder Memoria ni Tope y con
/// los campos nuevos en sus valores por defecto.
final class MigracionV020Tests: XCTestCase {
    private let idProveedor = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let idConversacion = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    func testConfiguracionDeV020ConservaMemoriaYTopeYEstrenaDefaults() throws {
        let json = """
        {
          "version": 1,
          "proveedores": [
            {
              "id": "\(idProveedor.uuidString)",
              "nombre": "Proveedor de prueba",
              "protocolo": "chatCompletions",
              "baseURL": "https://api.ejemplo.test/v1",
              "modelo": "modelo-de-prueba",
              "precioEntradaPorMillon": 0.03,
              "precioSalidaPorMillon": 0.12
            }
          ],
          "proveedorActivo": "\(idProveedor.uuidString)",
          "systemPrompt": "Memoria de prueba de la v0.2.0 con datos genericos.",
          "servidor": {
            "nombre": "Servidor",
            "url": "https://servidor.test/mcp",
            "activo": false
          },
          "topeAvisoCosto": 0.25
        }
        """

        let config = try AppConfig.desde(json: Data(json.utf8))

        // Lo que ya existia se conserva EXACTO.
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(
            config.memoria.map(\.texto),
            ["Memoria de prueba de la v0.2.0 con datos genericos."]
        )
        XCTAssertEqual(config.topeAvisoCosto, 0.25)
        XCTAssertEqual(config.topeAvisoCostoEfectivo, 0.25, accuracy: 0.0001)
        XCTAssertEqual(config.proveedorActivo, idProveedor)
        XCTAssertEqual(config.proveedores.first?.modelo, "modelo-de-prueba")

        // Lo nuevo toma sus defaults sin romper la lectura.
        XCTAssertEqual(config.skills, [])
        XCTAssertEqual(config.gasto, ContadoresGasto())
        XCTAssertNil(config.herramientasSinAprobacion)
    }

    func testConversacionDeV020AbreConLosCamposNuevosPorDefecto() throws {
        let json = """
        {
          "id": "\(idConversacion.uuidString)",
          "titulo": "Conversacion de prueba",
          "mensajes": [
            {
              "id": "00000000-0000-0000-0000-0000000000B1",
              "rol": "usuario",
              "texto": "Hola desde la version anterior",
              "fecha": "2025-01-15T10:00:00Z",
              "toolCalls": []
            },
            {
              "id": "00000000-0000-0000-0000-0000000000B2",
              "rol": "asistente",
              "texto": "Hola",
              "fecha": "2025-01-15T10:00:05Z",
              "toolCalls": []
            }
          ],
          "creada": "2025-01-15T10:00:00Z",
          "actualizada": "2025-01-15T10:00:05Z"
        }
        """

        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        let conversacion = try decodificador.decode(
            Conversation.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(conversacion.id, idConversacion)
        XCTAssertEqual(conversacion.titulo, "Conversacion de prueba")
        XCTAssertEqual(conversacion.mensajes.count, 2)

        // Campos que la v0.2.0 no guardaba: todos arrancan apagados o vacios.
        XCTAssertFalse(conversacion.fijada)
        XCTAssertFalse(conversacion.archivada)
        XCTAssertFalse(conversacion.avisoCostoMostrado)
        XCTAssertFalse(conversacion.sinMemoria)
        XCTAssertFalse(conversacion.modoTarea)
        XCTAssertFalse(conversacion.topeIgnorado)
        XCTAssertNil(conversacion.resumenCompactado)
        XCTAssertNil(conversacion.usoTrasCompactar)
        XCTAssertEqual(conversacion.mensajes.first?.skillsAplicadas, [])
        XCTAssertNil(conversacion.mensajes.first?.tokensEntrada)
        XCTAssertNil(conversacion.mensajes.first?.tokensSalida)
    }
}
