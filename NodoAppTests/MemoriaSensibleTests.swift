import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas del freno de categoria sensible con hoja de aprobacion (B2.4).
///
/// El turno se guioniza con el transporte de la app: el modelo pide
/// `propose_sensitive_memory`, el ejecutor detiene el turno y la hoja se
/// proyecta. Solo el evento [Aprobar] escribe; [Denegar], cerrar sin decidir y
/// cancelar dejan Mi Contexto intacto y cierran el `tool_call_id` con un
/// resultado interno de rechazo (rol `.herramienta`) que viaja al modelo.
@MainActor
final class MemoriaSensibleTests: XCTestCase {
    private let textoSalud =
        "mi presión arterial de prueba es 120 sobre 80"
    private let textoFinanzas =
        "mi presupuesto de prueba es 500 al mes"
    private let textoDocumento =
        "mi documento de prueba es el 0000-0000 de ejemplo"

    // MARK: - Turno 1: la propuesta no muta y [Denegar] cierra el turno

    func testProponerNoMutaYDenegarDejaCeroPersistenciaConRechazoInterno() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        let idLlamada = "call-b24-salud-1"
        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreProponerSensible,
                    argumentos: [
                        "content": textoSalud,
                        "sensitive_category": "health"
                    ],
                    idLlamada: idLlamada
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido: es una lectura normal de prueba.",
            uso: UsoTokens(entrada: 60, salida: 10)
        )

        arnes.estado.enviar(
            "Dato de prueba de salud: mi presión arterial de prueba es 120 "
                + "sobre 80, ¿qué significa?"
        )
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta sensible no apareció"
        )

        // Invocar la propuesta NO muta el registro.
        XCTAssertEqual(
            arnes.estado.config.memoria,
            [],
            "Proponer no puede escribir nada antes de [Aprobar]"
        )
        XCTAssertTrue(
            arnes.estado.eventosVisuales.allSatisfy { $0.cambioMemoria == nil },
            "Sin [Aprobar] no hay linea de guardado"
        )

        // La hoja es el unico artefacto del turno y muestra el texto exacto en
        // lenguaje llano.
        let pendientes = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(pendientes.count, 2, "\(pendientes)")
        XCTAssertEqual(
            try XCTUnwrap(pendientes.last),
            .hojaAprobacionMemoria(
                texto: textoSalud,
                categoriaSensible: .health,
                estado: .pendiente
            )
        )
        XCTAssertFalse(
            pendientes.contains { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }
        )

        arnes.estado.denegarPropuestaSensible()
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        XCTAssertEqual(
            arnes.estado.config.memoria,
            [],
            "[Denegar] no puede dejar la entrada escrita «por si acaso»"
        )
        XCTAssertTrue(
            arnes.estado.eventosVisuales.allSatisfy { $0.cambioMemoria == nil },
            "Denegar no deja linea de memoria"
        )
        XCTAssertNil(arnes.estado.propuestaMemoriaSensible)

        // Resultado interno de rechazo con rol .herramienta para ESE tool_call.
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, idLlamada)
        XCTAssertEqual(rechazo.texto, "denegado por el dueno")

        // Ningun elemento visible derivado del rechazo.
        let visibles = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            visibles,
            [
                .burbujaUsuario(
                    texto: "Dato de prueba de salud: mi presión arterial de "
                        + "prueba es 120 sobre 80, ¿qué significa?"
                ),
                .burbujaAsistente(
                    segmentos: [
                        .texto("Entendido: es una lectura normal de prueba.")
                    ]
                )
            ],
            "El hilo solo tiene las dos burbujas: ni hoja ni linea ni bloque"
        )

        // Turno siguiente: el tool_call_id denegado ya esta CERRADO en el
        // payload, nunca como llamada pendiente.
        arnes.transporte.guionar(
            texto: "Hola.",
            uso: UsoTokens(entrada: 20, salida: 2)
        )
        arnes.estado.enviar("Hola de nuevo")
        try await arnes.esperarTurno()

        let mensajes = try mensajesDeLaPeticion(arnes, indice: 2)
        let llamadas = mensajes
            .compactMap { $0["tool_calls"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["id"] as? String }
        let resultados = mensajes
            .filter { $0["role"] as? String == "tool" }
            .compactMap { $0["tool_call_id"] as? String }

        XCTAssertTrue(
            resultados.contains(idLlamada),
            "El rechazo tiene que viajar como resultado ya cerrado"
        )
        XCTAssertTrue(
            Set(llamadas).subtracting(resultados).isEmpty,
            "Ningun tool_call_id puede quedar huerfano en el payload"
        )
        XCTAssertFalse(
            mensajes.last.map { ($0["tool_calls"] as? [[String: Any]]) != nil }
                ?? false,
            "El payload no puede terminar con una llamada abierta"
        )
    }

    // MARK: - Turno 2: [Aprobar] escribe una entrada y su linea unica

    func testAprobarEscribeExactamenteUnaEntradaConSuCategoriaYLaLineaUnica() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreProponerSensible,
                    argumentos: [
                        "content": textoFinanzas,
                        "sensitive_category": "finances"
                    ],
                    idLlamada: "call-b24-finanzas-1"
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Anotado: 500 al mes.",
            uso: UsoTokens(entrada: 60, salida: 8)
        )

        arnes.estado.enviar("Dato de prueba de finanzas: mi presupuesto de prueba es 500 al mes")
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta sensible no apareció"
        )
        XCTAssertEqual(arnes.estado.config.memoria, [])

        arnes.estado.aprobarPropuestaSensible()
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            1,
            "[Aprobar] escribe exactamente una entrada"
        )
        let entrada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(entrada.texto, textoFinanzas)
        XCTAssertEqual(
            entrada.categoriaSensible,
            .finances,
            "La entrada conserva la categoria sensible declarada"
        )

        let lineas = arnes.estado.eventosVisuales.filter { $0.cambioMemoria != nil }
        XCTAssertEqual(lineas.count, 1, "Un solo artefacto: la linea unica")
        XCTAssertEqual(
            lineas.first?.texto,
            "Guardado en memoria: \(textoFinanzas)"
        )

        let visibles = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            visibles.filter { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }.count,
            1
        )
        XCTAssertNil(arnes.estado.propuestaMemoriaSensible)

        // El resultado interno que vuelve al modelo describe el guardado.
        let resultado = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertTrue(resultado.texto.contains("Guarde en Memoria"))
    }

    // MARK: - Cerrar sin decidir

    func testCerrarLaHojaSinDecidirEsDenegarYSinPersistencia() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreProponerSensible,
                    argumentos: [
                        "content": textoDocumento,
                        "sensitive_category": "documents_identifiers"
                    ],
                    idLlamada: "call-b24-documento-1"
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido.",
            uso: UsoTokens(entrada: 40, salida: 4)
        )

        arnes.estado.enviar("Dato de prueba: mi documento de prueba es el 0000-0000 de ejemplo")
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta sensible no apareció"
        )

        arnes.estado.cerrarPropuestaSensible()
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.memoria,
            [],
            "Cerrar sin tocar tambien es denegacion: cero persistencia"
        )
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, "call-b24-documento-1")
        XCTAssertEqual(rechazo.texto, "denegado por el dueno")
    }

    // MARK: - Categoria sensible forzada por la via no sensible

    func testSaveMemoryConCategoriaSensibleForzadaSeRechazaSinHoja() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
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
                        "content": textoSalud,
                        "category": "health"
                    ],
                    idLlamada: "call-b24-forzada-1"
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "No pude guardar eso.",
            uso: UsoTokens(entrada: 40, salida: 5)
        )

        arnes.estado.enviar("Dato de prueba de salud: mi presión arterial de prueba es 120 sobre 80")
        try await arnes.esperarTurno()

        XCTAssertEqual(
            arnes.estado.config.memoria,
            [],
            "save_memory no acepta una categoria sensible"
        )
        XCTAssertNil(
            arnes.estado.propuestaMemoriaSensible,
            "La via no sensible no puede abrir la hoja"
        )
        XCTAssertTrue(
            arnes.estado.eventosVisuales.allSatisfy { $0.cambioMemoria == nil }
        )
        let resultado = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertTrue(resultado.texto.contains("Error"), resultado.texto)
    }

    // MARK: - El freno vale tambien con el interruptor en OFF

    func testConOFFElFrenoSigueVigenteYSoloLaHojaDecide() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = false
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreProponerSensible,
                    argumentos: [
                        "content": textoSalud,
                        "sensitive_category": "health"
                    ],
                    idLlamada: "call-b24-off-1"
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido.",
            uso: UsoTokens(entrada: 40, salida: 4)
        )

        arnes.estado.enviar("Dato de prueba de salud: mi presión arterial de prueba es 120 sobre 80")
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "Con OFF la hoja sensible tampoco puede faltar"
        )

        // El payload de OFF ofrece la misma herramienta sensible que ON.
        let json = try jsonDeLaPeticion(arnes, indice: 0)
        XCTAssertTrue(
            nombresDeHerramientas(json).contains(Memoria.nombreProponerSensible),
            "OFF conserva propose_sensitive_memory: solo cambia el disparo"
        )

        arnes.estado.denegarPropuestaSensible()
        try await arnes.esperarTurno()

        XCTAssertEqual(arnes.estado.config.memoria, [])
        let rechazo = try XCTUnwrap(
            arnes.estado.conversacion.mensajes.last { $0.rol == .herramienta }
        )
        XCTAssertEqual(rechazo.toolCallId, "call-b24-off-1")
        XCTAssertEqual(rechazo.texto, "denegado por el dueno")
    }

    // MARK: - Chat Temporal: la herramienta nueva tampoco se ofrece

    func testElHiloTemporalSigueSinOfrecerProposeSensitiveMemory() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Entendido.",
            uso: UsoTokens(entrada: 30, salida: 3)
        )

        arnes.estado.nuevaConversacionTemporal()
        arnes.estado.enviar("Mi palabra clave de prueba es LUNA-7")
        try await arnes.esperarTurno()

        let json = try jsonDeLaPeticion(arnes, indice: 0)
        let herramientas = (json["tools"] as? [[String: Any]]) ?? []
        XCTAssertTrue(
            herramientas.isEmpty,
            "Un hilo temporal no ofrece ninguna herramienta de memoria"
        )
        XCTAssertFalse(
            nombresDeHerramientas(json).contains(Memoria.nombreProponerSensible)
        )
        XCTAssertEqual(arnes.estado.config.memoria, [])
    }

    // MARK: - La hoja nunca muestra el nombre tecnico ni un id

    func testLaHojaPresentaLenguajeLlanoSinNombreTecnicoNiId() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        arnes.estado.config.memoriaInteligente = true
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                llamada(
                    herramienta: Memoria.nombreProponerSensible,
                    argumentos: [
                        "content": textoSalud,
                        "sensitive_category": "health"
                    ],
                    idLlamada: "call-b24-texto-1"
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Entendido.",
            uso: UsoTokens(entrada: 40, salida: 4)
        )

        arnes.estado.enviar("Dato de prueba de salud: mi presión arterial de prueba es 120 sobre 80")
        try await arnes.esperar(
            { arnes.estado.propuestaMemoriaSensible != nil },
            mensaje: "La hoja de la propuesta sensible no apareció"
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let hoja = try XCTUnwrap(
            elementos.last(where: { elemento in
                if case .hojaAprobacionMemoria = elemento { return true }
                return false
            })
        )
        guard case .hojaAprobacionMemoria(
            let texto, let categoria, let estado
        ) = hoja else {
            return XCTFail("Se esperaba la hoja sensible")
        }
        XCTAssertEqual(texto, textoSalud, "La hoja muestra el texto EXACTO")
        XCTAssertEqual(categoria.etiquetaVisible, "Salud")
        XCTAssertEqual(estado, .pendiente)

        // Sobre el texto que la hoja presentaria (la linea de traza), ni nombre
        // tecnico ni id ni el rawValue de la categoria.
        let lineas = TrazaVista.lineasHilo(elementos, t: "0.0")
        let textoTraza = lineas.joined(separator: "\n")
        XCTAssertTrue(textoTraza.contains("MemoryApprovalSheet"), textoTraza)
        XCTAssertTrue(textoTraza.contains("categoria: \"Salud\""), textoTraza)
        XCTAssertFalse(
            textoTraza.contains(Memoria.nombreProponerSensible),
            textoTraza
        )
        XCTAssertFalse(textoTraza.contains("health"), textoTraza)
        XCTAssertFalse(
            textoTraza.range(
                of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                    + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                options: .regularExpression
            ) != nil,
            textoTraza
        )

        // Se cierra el turno para no dejar la continuacion colgada.
        arnes.estado.denegarPropuestaSensible()
        try await arnes.esperarTurno()
    }

    // MARK: - Ayudas

    private func llamada(
        herramienta: String,
        argumentos: [String: Any],
        idLlamada: String
    ) -> ToolCall {
        let datos = (try? JSONSerialization.data(withJSONObject: argumentos))
            ?? Data("{}".utf8)
        return ToolCall(
            id: idLlamada,
            nombre: herramienta,
            argumentos: String(decoding: datos, as: UTF8.self)
        )
    }

    private func jsonDeLaPeticion(
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

    private func mensajesDeLaPeticion(
        _ arnes: ArnesApp,
        indice: Int
    ) throws -> [[String: Any]] {
        let json = try jsonDeLaPeticion(arnes, indice: indice)
        return try XCTUnwrap(json["messages"] as? [[String: Any]])
    }

    private func nombresDeHerramientas(_ json: [String: Any]) -> [String] {
        let herramientas = json["tools"] as? [[String: Any]] ?? []
        return herramientas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
    }
}
