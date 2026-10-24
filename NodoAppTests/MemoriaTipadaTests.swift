import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la ejecucion real de las herramientas tipadas de Memoria (B2.1).
///
/// El turno se guioniza con el mismo transporte de la app: una respuesta SSE
/// que pide la herramienta y otra con la confirmacion del modelo. Asi se
/// ejercita el bucle completo, el ejecutor por turno, la escritura en
/// `config.memoria`, la linea de evento y su Deshacer sin red ni claves reales.
///
/// Los seis casos de fondo de la v0.3.1 (guardar, actualizar, borrar, sin
/// llamada, id desconocido y accion invalida) siguen aqui, migrados al esquema
/// tipado y con las mismas aserciones de estado y de Deshacer exacto.
@MainActor
final class MemoriaTipadaTests: XCTestCase {
    private let idUno = UUID(
        uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    )!
    private let idDos = UUID(
        uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    )!
    private let idDesconocido = UUID(
        uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    )!

    // MARK: - Guardar

    func testGuardarCreaLaTerceraEntradaConSuCategoriaYDeshacerLaElimina() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreGuardar,
                    argumentos: [
                        "content": "Prefiere cafe sin azucar",
                        "category": "preference"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Listo: lo guarde en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Guarda que prefiero cafe sin azucar")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria.count, 3)

        let entrada = try XCTUnwrap(arnes.estado.config.memoria.last)
        XCTAssertEqual(entrada.texto, "Prefiere cafe sin azucar")
        XCTAssertEqual(entrada.categoria, .preference)

        let linea = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertEqual(linea.cambioMemoria, CambioMemoria.guardada(entrada))
        XCTAssertTrue(linea.texto.hasPrefix("Guardado en memoria: "))
        XCTAssertFalse(linea.deshecho)

        // El resultado de la herramienta volvio al modelo en la segunda
        // peticion: sin eso no podria confirmar lo que hizo.
        let segunda = try cuerpoDeLaPeticion(arnes, indice: 1)
        let mensajes = try mensajesDe(segunda)
        let hayResultadoDeHerramienta = mensajes.contains { mensaje in
            guard mensaje["role"] as? String == "tool" else { return false }
            return (mensaje["content"] as? String)?.contains("Guarde") == true
        }
        XCTAssertTrue(
            hayResultadoDeHerramienta,
            "El resultado de save_memory no volvio al modelo: \(segunda)"
        )

        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, semilla())

        let deshecha = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertTrue(deshecha.deshecho)

        // Lo deshecho no se puede deshacer dos veces.
        XCTAssertFalse(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, semilla())
    }

    // MARK: - Tope 1/turno

    /// Dos invocaciones de memoria en el MISMO turno: la primera aplica y la
    /// segunda se rechaza sin mutar y sin dejar linea adicional.
    func testLaSegundaLlamadaDeMemoriaDelTurnoSeRechazaSinMutar() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = semilla()
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
                    ],
                    idLlamada: "call-b21-guardar-1"
                ),
                llamada(
                    herramienta: Memoria.nombreGuardar,
                    argumentos: [
                        "content": "Mi animal favorito de prueba es el gato",
                        "category": "preference"
                    ],
                    idLlamada: "call-b21-guardar-2"
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Listo.",
            uso: UsoTokens(entrada: 40, salida: 8)
        )

        arnes.estado.enviar(
            "Recuerda dos cosas: mi color favorito de prueba es el verde "
                + "y mi animal favorito de prueba es el gato"
        )
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            3,
            "Solo la primera invocacion del turno puede crear una entrada"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.last?.texto,
            "Mi color favorito de prueba es el verde"
        )
        XCTAssertFalse(
            arnes.estado.config.memoria.contains {
                $0.texto.contains("animal favorito")
            },
            "La segunda invocacion no puede mutar el registro"
        )

        let lineas = eventosDeMemoria(arnes)
        XCTAssertEqual(
            lineas.count,
            1,
            "La segunda invocacion no puede dejar una linea visible"
        )

        let resultados = arnes.estado.conversacion.mensajes
            .filter { $0.rol == .herramienta }
        XCTAssertEqual(resultados.count, 2)
        XCTAssertTrue(
            resultados[0].texto.contains("Guarde"),
            "La primera llamada se aplica: \(resultados[0].texto)"
        )
        XCTAssertTrue(
            resultados[1].texto.contains("Error"),
            "La segunda llamada vuelve como error interno: \(resultados[1].texto)"
        )
    }

    // MARK: - Actualizar

    func testActualizarConElIdDeLaSemillaNoCreceNYDeshacerRestauraTextoYCategoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreActualizar,
                    argumentos: [
                        "entry_id": idUno.uuidString,
                        "content": "Vive en Barcelona",
                        "category": "correction"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Actualizado en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Corrige: ya no vivo en Madrid, vivo en Barcelona")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            2,
            "Actualizar no cambia el conteo de entradas (N -> N)"
        )
        let actualizada = try XCTUnwrap(
            arnes.estado.config.memoria.first { $0.id == idUno }
        )
        XCTAssertEqual(actualizada.texto, "Vive en Barcelona")
        XCTAssertEqual(actualizada.categoria, .correction)

        let linea = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertEqual(linea.texto, "Memoria actualizada: Vive en Barcelona")

        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(
            arnes.estado.config.memoria,
            original,
            "Deshacer devuelve texto y categoria exactos"
        )

        XCTAssertFalse(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, original)
    }

    /// Una categoria que no es `correction` ni la de la entrada corregida se
    /// rechaza antes de tocar el registro.
    func testActualizarConCategoriaIncoherenteSeRechaza() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreActualizar,
                    argumentos: [
                        "entry_id": idDos.uuidString,
                        "content": "No debe entrar",
                        "category": "commitment"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No pude actualizar esa entrada.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Actualiza la entrada con otra categoria")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(eventoDeMemoria(arnes))
        XCTAssertTrue(
            try resultadoDeHerramienta(arnes).contains("Error")
        )
    }

    func testActualizarConIdInventadoSeRechazaYNoCreaEntrada() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreActualizar,
                    argumentos: [
                        "entry_id": idDesconocido.uuidString,
                        "content": "No debe entrar",
                        "category": "correction"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No pude actualizar esa entrada.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Actualiza la entrada que no existe")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria,
            original,
            "Un id inventado no puede tocar la lista ni crear reemplazo"
        )
        XCTAssertNil(eventoDeMemoria(arnes))

        let resultado = try resultadoDeHerramienta(arnes)
        XCTAssertTrue(resultado.contains("Error"))
    }

    // MARK: - Borrar

    func testBorrarConElIdDeLaSemillaBajaNYDeshacerReinsertaLaEntradaCompleta() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreBorrar,
                    argumentos: ["entry_id": idUno.uuidString]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Borrado de tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Olvida que vivo en Madrid")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria,
            [original[1]],
            "Borra exactamente la entrada indicada (N -> N-1)"
        )

        let linea = try XCTUnwrap(eventoDeMemoria(arnes))
        XCTAssertEqual(linea.texto, "Memoria: entrada borrada · Vive en Madrid")
        XCTAssertTrue(
            arnes.estado.elementosVisiblesDelHilo().contains { elemento in
                if case .lineaMemoria(_, let puedeDeshacer, _) = elemento {
                    return puedeDeshacer
                }
                return false
            },
            "La linea de borrado ofrece Deshacer"
        )

        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(
            arnes.estado.config.memoria,
            original,
            "Deshacer un borrado reinserta la entrada completa y en su sitio"
        )

        XCTAssertFalse(arnes.estado.deshacerCambioDeMemoria(id: linea.id))
        XCTAssertEqual(arnes.estado.config.memoria, original)
    }

    func testBorrarConIdInventadoSeRechazaSinBorrarNiCrearNada() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreBorrar,
                    argumentos: ["entry_id": idDesconocido.uuidString]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No encontre esa entrada.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Borra la entrada que no existe")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria,
            original,
            "Un id inventado no borra ninguna otra entrada ni crea reemplazo"
        )
        XCTAssertNil(eventoDeMemoria(arnes))
        XCTAssertTrue(try resultadoDeHerramienta(arnes).contains("Error"))
    }

    // MARK: - Memoria sensible

    /// B2.4 cablea `propose_sensitive_memory` a la hoja: se ofrece, invocarla
    /// no muta el registro y sin [Aprobar] el turno cierra con rechazo.
    func testProposeSensitiveMemorySeOfreceYNoMutaSinAprobacion() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreProponerSensible,
                    argumentos: [
                        "content": "Toma insulina",
                        "sensitive_category": "health"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No puedo guardar eso sin tu aprobación.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Recuerda que tomo insulina")
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La propuesta sensible no abrió su hoja"
        )

        // Invocar la propuesta no muta nada: la hoja espera la decision.
        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(eventoDeMemoria(arnes))

        arnes.estado.denegarPropuestaSensible()
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(eventoDeMemoria(arnes))
        XCTAssertEqual(
            try resultadoDeHerramienta(arnes),
            Memoria.rechazoDenegado
        )

        let cuerpo = try cuerpoDeLaPeticion(arnes, indice: 0)
        XCTAssertTrue(
            cuerpo.contains(Memoria.nombreProponerSensible),
            "B2.4 ofrece propose_sensitive_memory en Chat"
        )
    }

    // MARK: - Sin llamada

    func testUnTurnoSinLlamadaALaHerramientaNoCambiaLaMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "Hola, ¿en que puedo ayudarte?",
            uso: UsoTokens(entrada: 20, salida: 6)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(eventoDeMemoria(arnes))
    }

    // MARK: - Errores de argumentos

    func testUnaCategoriaSensibleEnSaveMemoryDevuelveErrorYNoTocaLaMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreGuardar,
                    argumentos: [
                        "content": "Toma insulina",
                        "category": "health"
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No reconozco esa categoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Guarda esto en mi memoria")
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(eventoDeMemoria(arnes))
        XCTAssertTrue(try resultadoDeHerramienta(arnes).contains("Error"))
    }

    func testUnaConfianzaFueraDeRangoDevuelveErrorYNoTocaLaMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreGuardar,
                    argumentos: [
                        "content": "Dato con confianza rota",
                        "category": "durable_fact",
                        "confidence_score": 1.5
                    ]
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No pude guardar ese dato.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Guarda esto")
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria, original)
        XCTAssertNil(eventoDeMemoria(arnes))
        XCTAssertTrue(try resultadoDeHerramienta(arnes).contains("Error"))
    }

    // MARK: - Payload

    /// El payload de Chat lleva cada entrada con su id y su categoria, y ofrece
    /// las cuatro herramientas de escritura: B2.4 cablea la sensible a su hoja.
    func testElPayloadIncluyeIdCategoriaYLasCuatroHerramientasDeChat() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let original = semilla()
        arnes.estado.config.memoria = original
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Respuesta con memoria.",
            uso: UsoTokens(entrada: 40, salida: 8)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let cuerpo = try cuerpoDeLaPeticion(arnes, indice: 0)
        for entrada in original {
            XCTAssertTrue(cuerpo.contains(entrada.id.uuidString), cuerpo)
            XCTAssertTrue(cuerpo.contains(entrada.categoria.rawValue), cuerpo)
            XCTAssertTrue(cuerpo.contains(entrada.texto), cuerpo)
        }

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
                Memoria.nombreProponerSensible,
                Memoria.nombreBorrar
            ],
            "Chat ofrece las cuatro herramientas tipadas, la sensible incluida"
        )
        XCTAssertFalse(nombres.contains(Memoria.nombreHerramientaTarea))
    }

    // MARK: - Ayudas

    /// Las dos entradas sinteticas de la semilla de B2.1.
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

    /// Ultima linea de Memoria del hilo, deshecha o no.
    private func eventoDeMemoria(_ arnes: ArnesApp) -> EventoVisual? {
        eventosDeMemoria(arnes).last
    }

    private func eventosDeMemoria(_ arnes: ArnesApp) -> [EventoVisual] {
        arnes.estado.eventosVisuales.filter { $0.cambioMemoria != nil }
    }

    private func resultadoDeHerramienta(_ arnes: ArnesApp) throws -> String {
        try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        ).texto
    }

    /// Construye una llamada tipada con sus argumentos JSON.
    private func llamada(
        herramienta: String,
        argumentos: [String: Any],
        idLlamada: String = "llamada-memoria"
    ) -> ToolCall {
        let datos = (try? JSONSerialization.data(withJSONObject: argumentos))
            ?? Data("{}".utf8)
        return ToolCall(
            id: idLlamada,
            nombre: herramienta,
            argumentos: String(decoding: datos, as: UTF8.self)
        )
    }

    private func cuerpoDeLaPeticion(_ arnes: ArnesApp, indice: Int) throws -> String {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }

    private func mensajesDe(_ cuerpo: String) throws -> [[String: Any]] {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(json["messages"] as? [[String: Any]])
    }
}
