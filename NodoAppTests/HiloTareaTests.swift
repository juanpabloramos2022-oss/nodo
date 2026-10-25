import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Nivel 1 de la Partida B3-A: contrato del hilo conversacional de Tarea.
///
/// POR QUE sobre el ViewModel y no sobre capturas: la spec exige listas
/// EXACTAS y ordenadas de elementos, aserciones negativas de formulario y una
/// serializacion de eventos reproducible. Nada de eso se prueba mirando
/// pixeles; todo se prueba sobre `HiloTareaViewModel` y el `EstadoApp` real
/// con transporte y disco temporales (mismo arnes de la v0.3.1).
@MainActor
final class HiloTareaTests: XCTestCase {
    private let encargo = """
    Consulta https://example.com y proponé guardar en Memoria una frase sobre ese dominio
    """
    private let ajuste = "Que la frase sea corta"

    private func preparar(_ arnes: ArnesApp) -> Tarea {
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        return arnes.estado.crearTarea()
    }

    private func tareaActual(_ arnes: ArnesApp, _ id: UUID) throws -> Tarea {
        try XCTUnwrap(arnes.estado.tareas.first { $0.id == id })
    }

    private func hiloDe(
        _ estado: EstadoApp,
        _ tarea: Tarea
    ) -> HiloTareaViewModel {
        let hilo = HiloTareaViewModel()
        hilo.reconstruir(
            con: tarea,
            proyeccion: estado.elementosVisiblesDeTarea(tarea)
        )
        return hilo
    }

    // MARK: - (a) La lista es exactamente burbuja y tarjeta

    func testTrasElEncargoLaListaEsSoloLaBurbujaYAlLlegarElPlanLaTarjeta() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)
        arnes.transporte.guionar(texto: "1. Consultar el dominio\n2. Proponer una frase")

        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )

        // E1: el encargo ya es un turno visible del hilo, sin plan todavia.
        var hilo = hiloDe(arnes.estado, try tareaActual(arnes, tarea.id))
        XCTAssertEqual(hilo.elementos, [.burbujaUsuario(texto: encargo)])

        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        let actual = try tareaActual(arnes, tarea.id)
        let plan = try XCTUnwrap(actual.plan)
        hilo = hiloDe(arnes.estado, actual)
        XCTAssertEqual(
            hilo.elementos,
            [
                .burbujaUsuario(texto: encargo),
                .tarjetaPlan(
                    pasos: plan.pasos,
                    version: 1,
                    acciones: [.empezar, .ajustar]
                )
            ]
        )

        // Asercion negativa sobre TIPOS de elemento: el hilo solo puede
        // proyectar burbuja, tarjeta, fila, error y resultado. No existe
        // ningun caso de caja de instruccion, boton de guardar ni seccion de
        // formulario; el switch es exhaustivo sobre el enum cerrado.
        for elemento in hilo.elementos {
            switch elemento {
            case .burbujaUsuario, .tarjetaPlan, .filaPaso, .errorEnLinea,
                 .resultadoFinal:
                break
            }
        }
    }

    // MARK: - (b) Antes de [Empezar] no corre nada

    func testAntesDeEmpezarHayCeroLibroYCeroHerramientas() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)
        arnes.transporte.guionar(texto: "1. Consultar\n2. Guardar la frase")

        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        let actual = try tareaActual(arnes, tarea.id)
        XCTAssertEqual(actual.estado, .esperandoInicio)
        XCTAssertTrue(actual.pasos.isEmpty, "Sin [Empezar] no puede existir libro")
        XCTAssertEqual(
            arnes.transporte.peticionesRegistradas.count,
            1,
            "Solo la llamada del plan: ningun ajuste ni paso ejecuta herramientas"
        )

        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.first?.cuerpo
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        )
        XCTAssertNil(
            json["tools"],
            "El plan se genera en modo solo-texto: el payload no lleva tools"
        )
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertFalse(
            mensajes.contains { $0["role"] as? String == "tool" },
            "Un plan sin ejecutar no puede traer mensajes de herramienta"
        )
    }

    // MARK: - (c) El ajuste produce PlanCard v2 y queda como turno

    func testElMensajeDeAjusteProducePlanV2YConservaElTurno() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)

        arnes.transporte.guionar(texto: "1. Consultar el dominio\n2. Proponer una frase")
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        arnes.transporte.guionar(texto: "1. Consultar el dominio\n2. Proponer una frase corta")
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: ajuste)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        let actual = try tareaActual(arnes, tarea.id)
        XCTAssertEqual(actual.turnos.map(\.texto), [encargo, ajuste])
        let plan = try XCTUnwrap(actual.plan)
        XCTAssertEqual(plan.version, 2, "Cada ajuste sube la version del plan")

        let hilo = hiloDe(arnes.estado, actual)
        XCTAssertEqual(
            hilo.elementos,
            [
                .burbujaUsuario(texto: encargo),
                .burbujaUsuario(texto: ajuste),
                .tarjetaPlan(
                    pasos: plan.pasos,
                    version: 2,
                    acciones: [.empezar, .ajustar]
                )
            ]
        )

        // El segundo payload lleva el encargo y el ajuste, y sigue sin tools.
        XCTAssertEqual(arnes.transporte.peticionesRegistradas.count, 2)
        let cuerpo = try XCTUnwrap(
            arnes.transporte.peticionesRegistradas.last?.cuerpo
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        )
        XCTAssertNil(json["tools"])
        let mensajes = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let usuario = try XCTUnwrap(
            mensajes.last { $0["role"] as? String == "user" }
        )
        let texto = try XCTUnwrap(usuario["content"] as? String)
        XCTAssertTrue(texto.contains(encargo), texto)
        XCTAssertTrue(texto.contains("Ajuste: \(ajuste)"), texto)
    }

    // MARK: - (d) Rehidratar reproduce la misma lista

    func testRehidratarDesdeDiscoReproduceLaMismaListaEnElMismoOrden() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)

        arnes.transporte.guionar(texto: "1. Consultar\n2. Proponer")
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        arnes.transporte.guionar(texto: "1. Consultar\n2. Proponer corto")
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: ajuste)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        let original = hiloDe(arnes.estado, try tareaActual(arnes, tarea.id))

        // Cerrar y abrir la app: otro EstadoApp sobre el mismo disco.
        let reiniciado = EstadoApp(
            llavero: arnes.llavero,
            transporte: arnes.transporte,
            defaults: arnes.defaults,
            directorioStore: arnes.directorioStore,
            directorioTareas: arnes.directorioTareas
        )
        let recargada = try XCTUnwrap(
            reiniciado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(recargada.plan?.version, 2)
        XCTAssertEqual(recargada.turnos.map(\.texto), [encargo, ajuste])

        let rehidratado = hiloDe(reiniciado, recargada)
        XCTAssertEqual(rehidratado.elementos, original.elementos)
    }

    // MARK: - (e) R17: interleaving forzado SSE + herramienta

    func testElInterleavingDeEventosRespetaElOrdenDeEmisionYElEstadoFinal() {
        let eventos: [HiloTareaViewModel.Evento] = [
            .deltaSSE(texto: "Consultando…"),
            .herramienta(paso: 1, etiqueta: "Leer enlace"),
            .paso(indice: 1, estado: .completado),
            .costoSellado(Decimal(string: "0.000012")!),
            .aprobacion(pendiente: true),
            .aprobacion(pendiente: false),
            .deltaSSE(texto: "Listo")
        ]

        let secuencial = HiloTareaViewModel()
        for (indice, evento) in eventos.enumerated() {
            secuencial.aplicar(evento, secuencia: indice + 1)
        }

        // Se entregan adelantados y desordenados: la cola los reordena.
        let intercalado = HiloTareaViewModel()
        for secuencia in [3, 1, 7, 2, 5, 4, 6] {
            intercalado.aplicar(eventos[secuencia - 1], secuencia: secuencia)
        }

        XCTAssertEqual(
            intercalado.traza,
            secuencial.traza,
            "La traza sigue el orden de emision, no el de llegada"
        )
        XCTAssertEqual(
            intercalado.estadoFinal,
            secuencial.estadoFinal,
            "El estado final es identico al de la corrida secuencial"
        )
        XCTAssertEqual(
            secuencial.estadoFinal.filas[1],
            .some(.completado)
        )
        XCTAssertEqual(
            secuencial.estadoFinal.costoSellado,
            Decimal(string: "0.000012")!
        )
        XCTAssertEqual(secuencial.estadoFinal.estado, .enCurso)
    }

    // MARK: - (f) La cabecera en los estados de §1.3

    func testLaCabeceraExponeEstadoYCostoSelladoEnTodosLosEstados() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let plan = PlanTarea(
            pasos: [PasoPlan(orden: 1, texto: "Consultar")],
            texto: "1. Consultar",
            version: 1
        )
        let pendienteDeAprobacion = Paso(
            descripcion: "Guardar la frase",
            estado: .pendiente,
            aprobacion: .pendiente
        )
        let costo = 0.25

        func tarea(
            _ estado: EstadoTarea,
            pasos: [Paso] = []
        ) -> Tarea {
            Tarea(
                instruccion: "Encargo de prueba",
                estado: estado,
                pasos: pasos,
                plan: plan,
                costoAcumuladoUSD: costo
            )
        }

        let casos: [
            (Tarea, Bool?, Bool?, ElementoTareaVisible.EstadoTarea)
        ] = [
            // E0
            (Tarea(instruccion: "", estado: .borrador), nil, nil, .nuevaTarea),
            // E1
            (tarea(.borrador), true, nil, .planificando),
            // E2
            (tarea(.esperandoInicio), nil, nil, .planPropuesto),
            // E3 (misma etiqueta; la espera se prueba aparte, sin transicion)
            (tarea(.esperandoInicio), nil, nil, .planPropuesto),
            // E4
            (tarea(.enCurso), nil, nil, .enCurso),
            // E5
            (
                tarea(.enCurso, pasos: [pendienteDeAprobacion]),
                nil,
                nil,
                .esperandoAprobacion
            ),
            // E6
            (tarea(.detenida), nil, nil, .detenida),
            // E7
            (tarea(.fallida), nil, nil, .error),
            // E8
            (tarea(.completada), nil, nil, .completada)
        ]

        for caso in casos {
            let (laTarea, planificando, aprobacion, esperado) = caso
            XCTAssertEqual(
                arnes.estado.estadoVisibleDeTarea(
                    laTarea,
                    planificando: planificando,
                    aprobacionPendiente: aprobacion
                ),
                esperado
            )

            let cabecera = arnes.estado.elementosVisiblesDeTarea(laTarea).first
            guard case .cabeceraTarea(_, _, _, let costoSellado) = cabecera else {
                XCTFail("La proyeccion no empieza por la cabecera fija")
                continue
            }
            XCTAssertEqual(
                costoSellado,
                Decimal(laTarea.costoAcumuladoUSD ?? 0),
                "La cabecera muestra el costo SELLADO de esta tarea"
            )
        }
    }

    // MARK: - E3 no avanza sola a E4

    func testElPlanEnEsperaNoAvanzaSoloAEjecucion() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)
        arnes.transporte.guionar(texto: "1. Consultar\n2. Proponer")

        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        let antes = try tareaActual(arnes, tarea.id)
        XCTAssertEqual(antes.estado, .esperandoInicio)
        XCTAssertTrue(antes.pasos.isEmpty)
        let peticiones = arnes.transporte.peticionesRegistradas.count

        // E2: plan recien propuesto, con las dos acciones y sin ejecucion.
        let planE2 = try XCTUnwrap(antes.plan)
        let hiloE2 = hiloDe(arnes.estado, antes)
        XCTAssertEqual(
            hiloE2.elementos.last,
            .some(
                .tarjetaPlan(
                    pasos: planE2.pasos,
                    version: 1,
                    acciones: [.empezar, .ajustar]
                )
            )
        )

        // E3: la vista no tiene cuenta atras ni ejecucion parcial; tras la
        // espera el plan sigue siendo el mismo y no se pidio nada nuevo.
        try await Task.sleep(nanoseconds: 150_000_000)

        let despues = try tareaActual(arnes, tarea.id)
        XCTAssertEqual(despues.estado, .esperandoInicio)
        XCTAssertTrue(despues.pasos.isEmpty)
        XCTAssertEqual(despues.plan?.version, 1)
        XCTAssertEqual(arnes.transporte.peticionesRegistradas.count, peticiones)
        XCTAssertEqual(hiloDe(arnes.estado, despues).elementos, hiloE2.elementos)
    }

    // MARK: - E7: error en linea, persistido y en su punto

    func testElErrorDePlanQuedaComoElementoDelHiloYSePersiste() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)
        arnes.transporte.guionar(texto: "")

        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        let actual = try tareaActual(arnes, tarea.id)
        let mensaje = try XCTUnwrap(actual.ultimoError)
        XCTAssertTrue(mensaje.contains("plan"), mensaje)

        let hilo = hiloDe(arnes.estado, actual)
        XCTAssertEqual(
            hilo.elementos,
            [
                .burbujaUsuario(texto: encargo),
                .errorEnLinea(texto: mensaje)
            ],
            "El error va como elemento del hilo, no como alerta que tapa"
        )

        // Salir y volver a entrar: el error sigue en el mismo punto.
        let reiniciado = EstadoApp(
            llavero: arnes.llavero,
            transporte: arnes.transporte,
            defaults: arnes.defaults,
            directorioStore: arnes.directorioStore,
            directorioTareas: arnes.directorioTareas
        )
        let recargada = try XCTUnwrap(
            reiniciado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(
            hiloDe(reiniciado, recargada).elementos,
            hilo.elementos
        )
    }

    // MARK: - E8: resultado final como ultimo elemento

    func testLaTareaCompletadaMuestraElResultadoFinalComoUltimoElemento() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let tarea = preparar(arnes)

        arnes.transporte.guionar(texto: "1. Responder")
        XCTAssertTrue(
            arnes.estado.registrarMensajeTarea(id: tarea.id, texto: encargo)
        )
        await arnes.estado.solicitarPlanTarea(id: tarea.id)

        arnes.transporte.guionar(texto: "Respuesta final de prueba")
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        let actual = try tareaActual(arnes, tarea.id)
        XCTAssertEqual(actual.resultado, "Respuesta final de prueba")
        XCTAssertNil(actual.ultimoError)

        let hilo = hiloDe(arnes.estado, actual)
        // M1-3: el resultado sigue siendo el último elemento y conserva el
        // texto del modelo; además declara, como párrafo aparte, el paso del
        // plan que no llegó a ejecutarse (el libro quedó vacío).
        guard case .some(.resultadoFinal(let texto)) = hilo.elementos.last else {
            return XCTFail("El resultado final no es el último elemento")
        }
        XCTAssertTrue(
            texto.hasPrefix("Respuesta final de prueba"),
            "El resultado final perdió el texto del modelo: \(texto)"
        )
        XCTAssertTrue(
            texto.contains(
                "El paso 1 del plan quedó sin ejecutar: "
                    + "la tarea se completó sin él."
            ),
            "La burbuja final no declara el paso abandonado: \(texto)"
        )
    }

    // MARK: - E6: detencion en el contenedor

    func testLaTareaDetenidaConservaSusFilasEnElContenedor() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let tarea = Tarea(
            instruccion: "Encargo detenido",
            estado: .detenida,
            pasos: [
                Paso(
                    descripcion: "Consultar el dominio",
                    estado: .terminado,
                    herramienta: "traer_url",
                    resultado: "contenido",
                    fechaInicio: Date(timeIntervalSince1970: 10),
                    fechaFin: Date(timeIntervalSince1970: 12)
                ),
                Paso(
                    descripcion: "Guardar la frase",
                    estado: .fallido,
                    resultado: "Detenida por el dueño.",
                    fechaFin: Date(timeIntervalSince1970: 13)
                )
            ],
            plan: PlanTarea(
                pasos: [
                    PasoPlan(orden: 1, texto: "Consultar el dominio"),
                    PasoPlan(orden: 2, texto: "Guardar la frase")
                ],
                texto: "1. Consultar\n2. Guardar"
            ),
            costoAcumuladoUSD: 0.1
        )

        let hilo = hiloDe(arnes.estado, tarea)
        XCTAssertEqual(hilo.cabecera.estado, .detenida)
        XCTAssertEqual(hilo.cabecera.costoSellado, Decimal(0.1))
        XCTAssertEqual(hilo.elementos.filter { elemento in
            if case .filaPaso = elemento { return true }
            return false
        }.count, 2)
        XCTAssertNil(
            hilo.elementos.last(where: { elemento in
                if case .resultadoFinal = elemento { return true }
                return false
            }),
            "Una tarea detenida no inventa un resultado final"
        )
    }

    // MARK: - Test negativo: el formulario no sobrevive en la vista

    func testLaVistaDeTareaYaNoTieneElementosDeFormulario() throws {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vista = try String(
            contentsOf: raiz.appendingPathComponent("Nodo/Views/TareaView.swift"),
            encoding: .utf8
        )
        for prohibido in [
            "TextEditor",
            "Guardar instrucción",
            "instruccion-tarea",
            "seccionInstruccion",
            "seccionPlan",
            "seccionTrabajo",
            "panel-trabajo-tarea",
            "regenerar-plan",
            "HojaNuevaTarea"
        ] {
            XCTAssertFalse(
                vista.contains(prohibido),
                "La demolicion dejo \(prohibido) en TareaView.swift"
            )
        }

        let raizTareas = try String(
            contentsOf: raiz.appendingPathComponent(
                "Nodo/Views/TareasRaizView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(
            raizTareas.contains("HojaNuevaTarea"),
            "Crear tarea ya no pasa por una hoja de formulario"
        )
        XCTAssertFalse(
            raizTareas.contains("TextEditor"),
            "Crear tarea ya no pasa por una hoja de formulario"
        )

        // El catalogo cerrado de Tarea sigue teniendo SOLO sus tres casos: esta
        // partida no lo amplia ni le cuela un elemento de formulario.
        let catalogo = try String(
            contentsOf: raiz.appendingPathComponent(
                "Nodo/Support/ElementoTareaVisible.swift"
            ),
            encoding: .utf8
        )
        for esperado in [
            "case cabeceraTarea(", "case tarjetaPlan(", "case filaPaso("
        ] {
            XCTAssertTrue(catalogo.contains(esperado), "Falta \(esperado)")
        }
        for prohibido in [
            "cajaInstruccion", "botonGuardar", "seccionFormulario",
            "cajaTexto", "seccionPlan", "seccionTrabajo"
        ] {
            XCTAssertFalse(
                catalogo.contains(prohibido),
                "El catalogo de Tarea no puede tener \(prohibido)"
            )
        }
    }
}
