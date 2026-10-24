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

        let orden =
            "Recuerda que mi palabra clave de la barbería es LUNA-7 y que prefiero respuestas cortas."
        arnes.estado.enviar(orden)
        try await arnes.esperarTurno()

        XCTAssertNil(arnes.estado.errorDeTurno)
        let entrada = try XCTUnwrap(arnes.estado.config.memoria.first)
        XCTAssertEqual(entrada.texto, "Palabra clave de la barbería: LUNA-7")

        let elementos = arnes.estado.elementosVisiblesDelHilo()

        // B1.1: la lista es EXACTAMENTE usuario + aviso de memoria + respuesta.
        // Ningun mensaje de rol herramienta ni ningun `toolCall` deja elemento.
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: orden),
                .lineaMemoria(
                    texto: "Guardado en memoria: Palabra clave de la barbería: LUNA-7",
                    puedeDeshacer: true,
                    deshecho: false
                ),
                .burbujaAsistente(
                    segmentos: [.texto("Listo: lo guarde en tu Memoria.")]
                )
            ]
        )

        let lineas = elementos.filter { elemento in
            if case .lineaMemoria = elemento { return true }
            return false
        }
        XCTAssertEqual(lineas.count, 1, "Un guardado deja exactamente una linea")

        // El texto del resultado de la herramienta (con UUID) no esta en
        // ningun elemento de la lista.
        let resultadoHerramienta = CambioMemoria
            .guardada(entrada)
            .resultadoHerramienta
        for elemento in elementos {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains(resultadoHerramienta))
            XCTAssertFalse(descripcion.contains(entrada.id.uuidString))
            XCTAssertFalse(descripcion.contains(Memoria.nombreHerramientaChat))
            XCTAssertFalse(descripcion.contains("{"))
        }

        // B1.2: la linea se deshace en el sitio. El mismo elemento pasa a
        // `deshecho` sin accion y la lista de entradas vuelve al estado previo.
        let memorias = arnes.estado.eventosDeMemoriaVisibles(elementos)
        let indiceLinea = try XCTUnwrap(
            elementos.firstIndex { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }
        )
        let evento = try XCTUnwrap(memorias[indiceLinea])
        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: evento.id))
        XCTAssertTrue(arnes.estado.config.memoria.isEmpty)

        XCTAssertEqual(
            arnes.estado.elementosVisiblesDelHilo(),
            [
                .burbujaUsuario(texto: orden),
                .lineaMemoria(
                    texto: "Guardado en memoria: Palabra clave de la barbería: LUNA-7",
                    puedeDeshacer: false,
                    deshecho: true
                ),
                .burbujaAsistente(
                    segmentos: [.texto("Listo: lo guarde en tu Memoria.")]
                )
            ],
            "Deshacer deja la misma linea en estado deshecho y sin accion"
        )
    }

    // MARK: - (b bis) Formato de actualizacion y borrado (D-B1.2-c)

    func testActualizarMemoriaProduceUnaSolaLineaConElFormatoNuevo() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let idEntrada = UUID(
            uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        )!
        arnes.estado.config.memoria = [
            EntradaMemoria(id: idEntrada, texto: "Vive en Madrid")
        ]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b12-actualizar",
                    nombre: Memoria.nombreHerramientaChat,
                    argumentos: #"{"accion":"actualizar","id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","texto":"Vive en Barcelona"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Actualizado.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        let orden = "Actualiza mi memoria: ahora vivo en Barcelona"
        arnes.estado.enviar(orden)
        try await arnes.esperarTurno()

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let lineas = elementos.compactMap { elemento -> String? in
            if case .lineaMemoria(let texto, _, _) = elemento { return texto }
            return nil
        }
        XCTAssertEqual(
            lineas,
            ["Memoria actualizada: Vive en Barcelona"],
            "Actualizar deja exactamente una linea con el formato nuevo"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.count,
            1,
            "Actualizar no cambia el conteo de entradas (N -> N)"
        )
        XCTAssertEqual(
            arnes.estado.config.memoria.first?.texto,
            "Vive en Barcelona"
        )
    }

    func testBorrarMemoriaProduceLaLineaUnicaYDeshacerRestauraLaEntrada() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let idEntrada = UUID(
            uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        )!
        let original = EntradaMemoria(id: idEntrada, texto: "Vive en Madrid")
        arnes.estado.config.memoria = [original]
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "call-b12-borrar",
                    nombre: Memoria.nombreHerramientaChat,
                    argumentos: #"{"accion":"borrar","id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}"#
                )
            ]
        )
        arnes.transporte.guionar(
            texto: "Borrado.",
            uso: UsoTokens(entrada: 30, salida: 8)
        )

        arnes.estado.enviar("Borra de mi memoria que vivo en Madrid")
        try await arnes.esperarTurno()

        XCTAssertTrue(arnes.estado.config.memoria.isEmpty)

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        let lineas = elementos.compactMap { elemento -> String? in
            if case .lineaMemoria(let texto, _, _) = elemento { return texto }
            return nil
        }
        XCTAssertEqual(
            lineas,
            ["Memoria: entrada borrada · Vive en Madrid"],
            "Borrar deja exactamente una linea con el formato nuevo"
        )

        let memorias = arnes.estado.eventosDeMemoriaVisibles(elementos)
        let indiceLinea = try XCTUnwrap(
            elementos.firstIndex { elemento in
                if case .lineaMemoria = elemento { return true }
                return false
            }
        )
        let evento = try XCTUnwrap(memorias[indiceLinea])
        XCTAssertTrue(arnes.estado.deshacerCambioDeMemoria(id: evento.id))
        XCTAssertEqual(
            arnes.estado.config.memoria,
            [original],
            "Deshacer un borrado restaura la entrada en Mi Contexto"
        )
        XCTAssertEqual(
            arnes.estado.elementosVisiblesDelHilo().filter { elemento in
                if case .lineaMemoria(_, let puedeDeshacer, let deshecho) = elemento {
                    return puedeDeshacer || !deshecho
                }
                return false
            }.count,
            0,
            "Tras deshacer, la linea no ofrece accion"
        )
    }

    // MARK: - (b ter) La linea no tiene [Ver] ni tarjeta (D-B1.2-a/b)

    func testLaLineaMemoriaEsUnaSolaLineaSinVerNiTarjeta() throws {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fuente = try String(
            contentsOf: raiz.appendingPathComponent("Nodo/Views/ChatView.swift"),
            encoding: .utf8
        )
        let inicio = try XCTUnwrap(
            fuente.range(of: "struct LineaMemoria: View")
        )
        let resto = fuente[inicio.lowerBound...]
        let fin = try XCTUnwrap(resto.range(of: "\n}\n"))
        let componente = String(resto[..<fin.upperBound])

        XCTAssertTrue(
            componente.contains(".lineLimit(1)"),
            "La linea no puede crecer a dos filas"
        )
        XCTAssertTrue(
            componente.contains(".truncationMode(.tail)"),
            "El contenido largo se trunca con elipsis"
        )
        XCTAssertFalse(componente.contains("alVer"), "La linea no tiene [Ver]")
        XCTAssertFalse(componente.contains("\"Ver\""), "La linea no pinta [Ver]")
        XCTAssertFalse(componente.contains("brain"), "La linea no tiene icono")
        XCTAssertFalse(componente.contains("Image("), "La linea no tiene icono")
        XCTAssertFalse(
            componente.contains("background("),
            "La linea no tiene fondo de tarjeta"
        )
        XCTAssertFalse(
            componente.contains("overlay"),
            "La linea no tiene borde de tarjeta"
        )
        XCTAssertFalse(
            componente.contains("Capsule"),
            "La linea no tiene botones capsula"
        )
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

    // MARK: - (c bis) `toolCalls` de una burbuja visible (D-B1.1-b)

    func testLosToolCallsDeUnaBurbujaVisibleNoAportanNingunElemento() {
        let arnes = try! ArnesApp()
        defer { arnes.limpiar() }

        let idLlamada = "call-memoria"
        let uuid = "123E4567-E89B-12D3-A456-426614174000"
        arnes.estado.conversacion = Conversation(
            titulo: "Llamada visible",
            mensajes: [
                ChatMessage(rol: .usuario, texto: "Guarda que vivo en Madrid"),
                ChatMessage(
                    rol: .asistente,
                    texto: "Lo guardo.",
                    toolCalls: [
                        ToolCall(
                            id: idLlamada,
                            nombre: Memoria.nombreHerramientaChat,
                            argumentos: #"{"accion":"guardar","texto":"Vivo en Madrid"}"#
                        )
                    ]
                ),
                ChatMessage(
                    rol: .herramienta,
                    texto: "Guarde en Memoria la entrada \(uuid).",
                    toolCallId: idLlamada
                ),
                ChatMessage(rol: .asistente, texto: "Listo.")
            ]
        )

        let elementos = arnes.estado.elementosVisiblesDelHilo()
        XCTAssertEqual(
            elementos,
            [
                .burbujaUsuario(texto: "Guarda que vivo en Madrid"),
                .burbujaAsistente(segmentos: [.texto("Lo guardo.")]),
                .burbujaAsistente(segmentos: [.texto("Listo.")])
            ],
            "La burbuja del asistente no pinta la fila de toolCalls"
        )

        for elemento in elementos {
            let descripcion = String(describing: elemento)
            XCTAssertFalse(descripcion.contains(Memoria.nombreHerramientaChat))
            XCTAssertFalse(descripcion.contains(uuid))
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
