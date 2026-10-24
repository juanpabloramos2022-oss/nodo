import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas del guardado por juicio y del interruptor «Memoria inteligente»
/// (B2.3), en el nivel 1 de la matriz: estado y payload reales de la app.
///
/// El contrato que se afirma aqui es el de la ficha: ON y OFF ofrecen
/// EXACTAMENTE el mismo conjunto de herramientas tipadas y solo cambia la
/// instruccion de disparo del bloque de sistema. Ninguna prueba restaura la
/// herramienta sin tipo de la v0.3.1 como fixture de comparacion: la
/// comparacion es sobre la instruccion, no sobre el esquema.
@MainActor
final class MemoriaInteligenteTests: XCTestCase {
    private let idUno = UUID(
        uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    )!
    private let idDos = UUID(
        uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    )!

    // MARK: - Payload ON

    func testConONElPayloadOfreceElMismoConjuntoYElBloqueTraeLasCuatroCategorias() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Hola.",
            uso: UsoTokens(entrada: 20, salida: 4)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let json = try cuerpoJSON(arnes, indice: 0)
        XCTAssertEqual(
            nombresDeHerramientas(json),
            [
                Memoria.nombreGuardar,
                Memoria.nombreActualizar,
                Memoria.nombreProponerSensible,
                Memoria.nombreBorrar
            ],
            "ON ofrece el conjunto cableado de B2.1 con la via sensible de B2.4"
        )

        let bloque = try bloqueDeSistema(json)
        for categoria in [
            "durable_fact", "preference", "correction", "commitment"
        ] {
            XCTAssertTrue(
                bloque.contains(categoria),
                "ON presenta la categoria \(categoria): \(bloque)"
            )
        }
        XCTAssertTrue(bloque.contains("Ante la duda entre guardar y no guardar, no guardes"))
        XCTAssertTrue(bloque.contains("No guardes detalles efimeros"))
        XCTAssertTrue(bloque.contains("SOLO invocando las herramientas"))
        XCTAssertTrue(bloque.contains("Memoria inteligente activada"))
        XCTAssertFalse(bloque.contains(Memoria.instruccionDeOrdenExplicita))
    }

    // MARK: - OFF: mismo conjunto, solo cambia el disparo

    func testConOFFCambiaSoloElDisparoYConservaLasHerramientas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // Turno ON.
        arnes.estado.config.memoriaInteligente = true
        arnes.transporte.guionar(
            texto: "Hola.",
            uso: UsoTokens(entrada: 20, salida: 4)
        )
        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        // Turno OFF en el mismo chat.
        arnes.estado.fijarMemoriaInteligente(false)
        arnes.transporte.guionar(
            texto: "Hola otra vez.",
            uso: UsoTokens(entrada: 20, salida: 4)
        )
        arnes.estado.enviar("Hola otra vez")
        try await arnes.esperarTurno()

        let jsonON = try cuerpoJSON(arnes, indice: 0)
        let jsonOFF = try cuerpoJSON(arnes, indice: 1)

        XCTAssertEqual(
            nombresDeHerramientas(jsonON),
            nombresDeHerramientas(jsonOFF),
            "OFF ofrece EXACTAMENTE las mismas herramientas que ON"
        )
        XCTAssertEqual(
            nombresDeHerramientas(jsonOFF),
            [
                Memoria.nombreGuardar,
                Memoria.nombreActualizar,
                Memoria.nombreProponerSensible,
                Memoria.nombreBorrar
            ]
        )

        let bloqueOFF = try bloqueDeSistema(jsonOFF)
        XCTAssertTrue(bloqueOFF.contains(Memoria.instruccionDeOrdenExplicita))
        XCTAssertFalse(bloqueOFF.contains("Memoria inteligente activada"))
        XCTAssertFalse(bloqueOFF.contains("cuatro categorias tipadas"))

        // La lista de entradas no cambio al apagar el interruptor.
        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(
            arnes.estado.eventosVisuales.first { $0.cambioMemoria != nil }
        )
    }

    // MARK: - Alternar no toca la lista

    func testAlternarDosVecesElInterruptorNoTocaLasEntradas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        let antes = arnes.estado.config.memoria

        arnes.estado.fijarMemoriaInteligente(true)
        XCTAssertTrue(arnes.estado.config.memoriaInteligente)
        XCTAssertEqual(arnes.estado.config.memoria, antes)

        arnes.estado.fijarMemoriaInteligente(false)
        XCTAssertFalse(arnes.estado.config.memoriaInteligente)
        XCTAssertEqual(arnes.estado.config.memoria, antes)

        arnes.estado.fijarMemoriaInteligente(true)
        arnes.estado.fijarMemoriaInteligente(false)

        XCTAssertEqual(
            arnes.estado.config.memoria,
            original,
            "Alternar el interruptor no crea, borra ni edita entradas"
        )
    }

    // MARK: - Un turno con guardado autonomo: un solo artefacto

    func testUnGuardadoAutonomoDejaExactamenteUnaLineaYNingunBloqueCrudo() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreGuardar,
                    argumentos: [
                        "content": "Mi color favorito de prueba es el verde",
                        "category": "preference"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Guardado. El verde queda como tu color de prueba.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Mi color favorito de prueba es el verde")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria.count, 3)
        XCTAssertEqual(
            arnes.estado.eventosVisuales.filter { $0.cambioMemoria != nil }.count,
            1,
            "Un guardado produce un solo evento de memoria"
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let avisos = elementos.filter { elemento in
            if case .lineaMemoria(_, _, _) = elemento { return true }
            return false
        }
        XCTAssertEqual(
            avisos.count,
            1,
            "La lista renderizable tiene exactamente 1 linea de aviso"
        )

        let traza = TrazaVista.lineasHilo(elementos, t: "0.0")
            .joined(separator: "\n")
        XCTAssertTrue(
            traza.contains(
                "MemoryLineNotice(text: \"Guardado en memoria: "
                    + "Mi color favorito de prueba es el verde\", "
                    + "hasUndo: true)"
            ),
            traza
        )
        XCTAssertEqual(
            traza.components(separatedBy: "MemoryLineNotice").count - 1,
            1
        )

        // 0 bloques crudos: ni JSON, ni etiqueta tecnica, ni UUID visible.
        XCTAssertFalse(traza.contains("{"))
        XCTAssertFalse(traza.contains("HERRAMIENTA"))
        XCTAssertFalse(traza.contains(Memoria.nombreGuardar))
        XCTAssertNil(
            traza.range(
                of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                options: .regularExpression
            ),
            "Ningun UUID llega a la vista: \(traza)"
        )
    }

    // MARK: - OFF: un turno sin orden no muta nada

    func testConOFFUnTurnoSinOrdenExplicitaNoMutaLaMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        arnes.estado.config.memoriaInteligente = false
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "El verde es un color primario.",
            uso: UsoTokens(entrada: 25, salida: 8)
        )

        arnes.estado.enviar("Mi color favorito de prueba es el verde")
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.memoria,
            original,
            "Sin orden explicita y con OFF no se guarda nada"
        )
        XCTAssertNil(
            arnes.estado.eventosVisuales.first { $0.cambioMemoria != nil },
            "Sin llamada no hay linea de memoria"
        )

        let json = try cuerpoJSON(arnes, indice: 0)
        let bloque = try bloqueDeSistema(json)
        XCTAssertTrue(bloque.contains(Memoria.instruccionDeOrdenExplicita))
        XCTAssertFalse(bloque.contains("Memoria inteligente activada"))
        XCTAssertEqual(
            nombresDeHerramientas(json),
            [
                Memoria.nombreGuardar,
                Memoria.nombreActualizar,
                Memoria.nombreProponerSensible,
                Memoria.nombreBorrar
            ],
            "OFF conserva las herramientas tipadas con su ejecutor"
        )

        let respuesta = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .asistente }
        ).texto.lowercased()
        XCTAssertFalse(respuesta.contains("guard"))
        XCTAssertFalse(respuesta.contains("memoria"))
        XCTAssertFalse(respuesta.contains("anot"))
    }

    // MARK: - Ayudas

    private func semilla() -> [EntradaMemoria] {
        [
            EntradaMemoria(
                id: idUno,
                texto: "Vive en Madrid",
                fecha: Date(timeIntervalSince1970: 100),
                categoria: .durableFact
            ),
            EntradaMemoria(
                id: idDos,
                texto: "Prefiere respuestas breves",
                fecha: Date(timeIntervalSince1970: 200),
                categoria: .preference
            )
        ]
    }

    private func llamada(
        herramienta: String,
        argumentos: [String: Any],
        idLlamada: String = "llamada-b23"
    ) -> ToolCall {
        let datos = (try? JSONSerialization.data(withJSONObject: argumentos))
            ?? Data("{}".utf8)
        return ToolCall(
            id: idLlamada,
            nombre: herramienta,
            argumentos: String(decoding: datos, as: UTF8.self)
        )
    }

    private func cuerpoJSON(
        _ arnes: ArnesApp,
        indice: Int
    ) throws -> [String: Any] {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: datos) as? [String: Any]
        )
    }

    private func nombresDeHerramientas(_ json: [String: Any]) -> [String] {
        let herramientas = json["tools"] as? [[String: Any]] ?? []
        return herramientas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
    }

    private func bloqueDeSistema(_ json: [String: Any]) throws -> String {
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let sistema = try XCTUnwrap(
            mensajes.first { $0["role"] as? String == "system" }
        )
        return try XCTUnwrap(sistema["content"] as? String)
    }
}
