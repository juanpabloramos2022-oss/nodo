import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Suite de contrato de la proyeccion visible (P0.2).
///
/// POR QUE: la v0.3.1 verifico mutaciones del modelo de datos (la entrada se
/// guardo, el paso se anadio) sin verificar nunca que exponia la capa de
/// presentacion. Esta suite afirma listas exactas y ordenadas de
/// `ElementoHiloVisible`, `ElementoTareaVisible` y `ElementoBusquedaVisible`
/// sin simulador grafico ni capturas: si un estado necesita pixeles, esta mal
/// planteado y se reescribe contra la proyeccion.
///
/// Usa el arnes de persistencia temporal y el doble de transporte ya
/// permitidos desde la P0 de la v0.3.1.
@MainActor
final class ViewModelSnapshotTest: XCTestCase {

    // MARK: - (a) Turno simple sin herramientas

    func testTurnoSimpleProduceBurbujaDeUsuarioYDeAsistente() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(
            texto: "Hola, ¿en qué puedo ayudarte?",
            uso: UsoTokens(entrada: 20, salida: 6)
        )

        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Hola"),
                .burbujaAsistente(
                    segmentos: [.texto("Hola, ¿en qué puedo ayudarte?")]
                )
            ]
        )
    }

    // MARK: - (b) Guardado de memoria con la respuesta archivada de v0.3.1

    func testGuardadoDeMemoriaProduceUnaLineaYNoFiltraElResultadoDeLaHerramienta() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.config.memoria = []
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        // Respuesta real archivada en humos/mem-humo-1.json de la v0.3.1.
        // El archivo trae dos llamadas `memoria_chat`; el contrato de esta
        // partida exige UN artefacto de memoria por turno, asi que el fixture
        // inyecta la primera llamada (la de LUNA-7) y deja constancia aqui.
        // La segunda del archivo es:
        //   call_01_YbcqWVGKwT9QMSax5B2j5076
        //   {"accion": "guardar", "texto": "Prefiere respuestas cortas"}
        let llamadaArchivada = ToolCall(
            id: "call_00_WVjAe73tY4ubrvEhwMnB9307",
            nombre: Memoria.nombreHerramientaChat,
            argumentos: #"{"accion": "guardar", "texto": "Palabra clave de la barbería: LUNA-7"}"#
        )
        arnes.transporte.guionar(texto: "", toolCalls: [llamadaArchivada])
        arnes.transporte.guionar(
            texto: "Listo: lo guarde en tu Memoria.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar(
            "Recuerda que mi palabra clave de la barbería es LUNA-7 y que prefiero respuestas cortas."
        )
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        let entrada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(entrada.texto, "Palabra clave de la barbería: LUNA-7")

        let elementos = arnes.estado.elementosVisiblesDelHilo()

        let lineas = elementos.filter { elemento in
            if case .lineaMemoria = elemento { return true }
            return false
        }
        XCTAssertEqual(lineas.count, 1, "Un guardado deja exactamente una linea")
        XCTAssertEqual(
            lineas,
            [
                .lineaMemoria(
                    texto: "Guarde en Memoria: Palabra clave de la barbería: LUNA-7",
                    puedeDeshacer: true,
                    deshecho: false
                )
            ]
        )

        XCTAssertTrue(
            elementos.contains(where: { elemento in
                if case .burbujaAsistente = elemento { return true }
                return false
            }),
            "El turno conserva la burbuja del asistente"
        )

        // El texto del resultado de la herramienta (con UUID) no esta en
        // ningun elemento de la lista.
        let resultadoHerramienta = CambioMemoria
            .guardada(entrada)
            .resultadoHerramienta
        for elemento in elementos {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains(resultadoHerramienta))
            XCTAssertFalse(descripcion.contains(entrada.id.uuidString))
        }
    }

    // MARK: - (c) Mensajes de herramienta de traer_url intercalados

    func testLosMensajesDeHerramientaNoProducenElementos() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        let idLlamada = "call-traer-url"
        arnes.estado.conversacion = Conversation(
            titulo: "Herramientas",
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Busca el pronóstico"),
                ChatMessage(
                    rol: .asistente,
                    texto: "",
                    toolCalls: [
                        ToolCall(
                            id: idLlamada,
                            nombre: "traer_url",
                            argumentos: #"{"url":"https://example.com"}"#
                        )
                    ]
                ),
                ChatMessage(
                    rol: .herramienta,
                    texto: #"{"titulo":"Ejemplo","contenido":"texto interno"}"#,
                    toolCallId: idLlamada
                ),
                ChatMessage(
                    rol: .asistente,
                    texto: "El pronóstico es soleado."
                )
            ]
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Busca el pronóstico"),
                .burbujaAsistente(
                    segmentos: [.texto("El pronóstico es soleado.")]
                )
            ]
        )

        for elemento in elementos {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains("traer_url"))
            XCTAssertFalse(descripcion.contains("texto interno"))
            XCTAssertFalse(descripcion.contains("{"))
        }
    }

    // MARK: - (d) Divisor de compactacion y error de turno persistido

    func testDivisorDeCompactacionYErrorDeTurnoAparecenEnSuPosicion() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        var mensajes: [ChatMessage] = []
        for indice in 1...8 {
            mensajes.append(
                ChatMessage(
                    rol: indice.isMultiple(of: 2) ? .asistente : .usuario,
                    texto: "Mensaje \(indice): "
                        + String(repeating: "contexto largo ", count: 20)
                )
            )
        }
        arnes.estado.conversacion = Conversation(
            titulo: "Compactación",
            mensajes: mensajes
        )
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(texto: "Resumen breve.")
        arnes.estado.compactar()
        try await arnes.esperarCompactacion()

        arnes.estado.errorDeTurno = "No se pudo contactar al proveedor."

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos.first,
            ElementoHiloVisible.divisor(
                texto: "── Conversación compactada: se resumieron 2 mensajes ──"
            )
        )
        XCTAssertEqual(
            elementos.last,
            ElementoHiloVisible.errorTurno(
                texto: "No se pudo contactar al proveedor."
            )
        )
    }

    // MARK: - (e) Propuesta sensible pendiente

    func testPropuestaSensiblePendienteEsElUnicoArtefactoDelTurno() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(
                    rol: .usuario,
                    texto: "Guarda que mi color favorito es verde"
                )
            ]
        )
        arnes.estado.propuestaMemoriaSensible = PropuestaMemoriaSensible(
            texto: "Color favorito: verde",
            categoriaSensible: .intimate,
            estado: .pendiente
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Guarda que mi color favorito es verde"),
                .hojaAprobacionMemoria(
                    texto: "Color favorito: verde",
                    categoriaSensible: .intimate,
                    estado: .pendiente
                )
            ]
        )

        XCTAssertFalse(
            elementos.contains(where: { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }),
            "Mientras la propuesta esta pendiente no hay linea de guardado"
        )
    }

    // MARK: - (f) Prosa y bloque de codigo

    func testLaBurbujaDelAsistenteSeparaProsaYCodigoEnOrden() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        let respuesta = "Aquí tienes el ejemplo:\n\n"
            + "```swift\n"
            + "let mensaje = \"LUNA-7\"\n"
            + "print(mensaje)\n"
            + "```"

        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Muéstrame un ejemplo"),
                ChatMessage(rol: .asistente, texto: respuesta)
            ]
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Muéstrame un ejemplo"),
                .burbujaAsistente(
                    segmentos: [
                        .texto("Aquí tienes el ejemplo:"),
                        .codigo(
                            lenguaje: "swift",
                            textoCrudo: "let mensaje = \"LUNA-7\"\nprint(mensaje)"
                        )
                    ]
                )
            ]
        )
    }

    func testUnaCercaSinLenguajeProduceCodigoConLenguajeNil() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Ejemplo"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Así:\n```\nlet x = 1\n```"
                )
            ]
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Ejemplo"),
                .burbujaAsistente(
                    segmentos: [
                        .texto("Así:"),
                        .codigo(lenguaje: nil, textoCrudo: "let x = 1")
                    ]
                )
            ]
        )
    }

    // MARK: - (g) Tarea en ejecucion

    func testLaTareaProyectaCabeceraPlanVersionadoYFilasDePaso() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        let inicio = Date(timeIntervalSince1970: 1_000)
        let fin = Date(timeIntervalSince1970: 1_010)
        let plan = PlanTarea(
            pasos: [
                PasoPlan(orden: 1, texto: "Revisar el contexto"),
                PasoPlan(orden: 2, texto: "Resumir los hallazgos")
            ],
            texto: "1. Revisar el contexto\n2. Resumir los hallazgos"
        )
        let tarea = Tarea(
            instruccion: "Investiga el tema",
            estado: .enCurso,
            pasos: [
                Paso(
                    descripcion: "Buscar fuentes",
                    estado: .terminado,
                    herramienta: "buscar_web",
                    costoUSD: 0.25,
                    fechaInicio: inicio,
                    fechaFin: fin
                ),
                Paso(
                    descripcion: "Leer el enlace",
                    estado: .enCurso,
                    herramienta: "traer_url",
                    fechaInicio: fin
                ),
                Paso(
                    descripcion: "Resumir",
                    estado: .pendiente
                )
            ],
            plan: plan,
            costoAcumuladoUSD: 0.5
        )

        let elementos = arnes.estado.elementosVisiblesDeTarea(tarea)
        XCTAssertEqual(
            elementos,
            [
                .cabeceraTarea(
                    estado: .enCurso,
                    pasoActual: 2,
                    pasosTotales: 3,
                    costoSellado: Decimal(0.5)
                ),
                .tarjetaPlan(pasos: plan.pasos, version: 1),
                .filaPaso(
                    paso: 1,
                    estado: .completado,
                    etiquetaDinamica: "Paso 1",
                    duracion: 10,
                    costo: Decimal(0.25)
                ),
                .filaPaso(
                    paso: 2,
                    estado: .enCurso,
                    etiquetaDinamica: "Leer enlace",
                    duracion: nil,
                    costo: nil
                ),
                .filaPaso(
                    paso: 3,
                    estado: .pendiente,
                    etiquetaDinamica: "Paso 3",
                    duracion: nil,
                    costo: nil
                )
            ]
        )

        for elemento in elementos {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains("buscar_web"))
            XCTAssertFalse(descripcion.contains("traer_url"))
            XCTAssertFalse(descripcion.contains(tarea.id.uuidString))
        }
    }

    // MARK: - (h) Busqueda sin coincidencias

    func testLaBusquedaSinCoincidenciasDevuelveElEstadoVacioExplicito() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        let conversaciones = [
            Conversation(
                titulo: "Recetas",
                mensajes: [
                    ChatMessage(rol: .usuario, texto: "Hablemos de recetas")
                ]
            )
        ]

        let sinCoincidencias = arnes.estado.elementosVisiblesDeBusqueda(
            "LUNA-7",
            en: conversaciones
        )
        XCTAssertEqual(sinCoincidencias, [.sinResultados(termino: "LUNA-7")])

        let conCoincidencia = arnes.estado.elementosVisiblesDeBusqueda(
            "recetas",
            en: conversaciones
        )
        XCTAssertEqual(
            conCoincidencia,
            [
                .resultadoBusqueda(
                    titulo: "Recetas",
                    vistaPrevia: "Hablemos de recetas"
                )
            ]
        )
    }

    // MARK: - Test negativo obligatorio

    func testUnMensajeDeHerramientaConUUIDYJSONNoProduceNingunElemento() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        let id = UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!
        let json = #"{"id":"123E4567-E89B-12D3-A456-426614174000","resultado":"dato interno"}"#

        arnes.estado.conversacion = Conversation(
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Hola"),
                ChatMessage(
                    rol: .asistente,
                    texto: "",
                    toolCalls: [
                        ToolCall(
                            id: "call-1",
                            nombre: "traer_url",
                            argumentos: "{}"
                        )
                    ]
                ),
                ChatMessage(
                    rol: .herramienta,
                    texto: json,
                    toolCallId: "call-1"
                ),
                ChatMessage(rol: .asistente, texto: "Listo.")
            ]
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Hola"),
                .burbujaAsistente(segmentos: [.texto("Listo.")])
            ]
        )

        for elemento in elementos {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains(id.uuidString))
            XCTAssertFalse(descripcion.contains("dato interno"))
            XCTAssertFalse(descripcion.contains("{"))
        }
    }
}
