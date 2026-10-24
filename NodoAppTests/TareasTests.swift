import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de TASK.1/TASK.2/TASK.3/TASK.4 sobre el `EstadoApp` real.
///
/// El arnes inyecta llavero, defaults, transporte y directorios: no toca el
/// telefono ni sale a internet. El plan y la ejecucion se guionizan con el mismo
/// transporte SSE que usa la app, asi que se comprueba el cuerpo real que se
/// manda al modelo y el libro que queda en disco.
@MainActor
final class TareasTests: XCTestCase {
    // MARK: - TASK.1: registro y lista

    func testCrearTareaLaPersisteYApareceEnLaListaConSuEstado() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let tarea = arnes.estado.crearTarea(instruccion: "Preparar el informe mensual")

        XCTAssertEqual(tarea.estado, .borrador)
        XCTAssertEqual(arnes.estado.tareas.map(\.id), [tarea.id])
        XCTAssertEqual(arnes.estado.tareas.first?.instruccion, "Preparar el informe mensual")

        // La lista sale del almacen real, no de una copia en memoria.
        let store = try TareaStore(directorio: arnes.directorioTareas)
        let cargada = try XCTUnwrap(store.cargar(id: tarea.id))
        XCTAssertEqual(cargada.instruccion, "Preparar el informe mensual")
        XCTAssertEqual(cargada.estado, .borrador)
    }

    func testAlArrancarUnaTareaEnCursoSeLeeComoInterrumpida() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Revisar\n2. Entregar")

        let tarea = arnes.estado.crearTarea(instruccion: "Cerrar el trimestre")
        await arnes.estado.generarPlan(id: tarea.id)

        // Se simula una app que murio con la tarea en curso. No se llama a
        // Empezar para no lanzar una ejecucion real que cambie el estado antes
        // de construir el EstadoApp de la "reapertura".
        let store = try TareaStore(directorio: arnes.directorioTareas)
        var enCurso = try XCTUnwrap(store.cargar(id: tarea.id))
        enCurso.estado = .enCurso
        try store.guardar(enCurso)

        // Un nuevo EstadoApp sobre el mismo almacen simula cerrar y abrir la app.
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
        XCTAssertEqual(recargada.estado, .interrumpida)

        XCTAssertEqual(store.cargar(id: tarea.id)?.estado, .interrumpida)
    }

    // MARK: - TASK.2: plan-primero

    func testGenerarPlanNoOfreceHerramientasYGuardaElPlanEnLaTarea() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Revisar la solicitud\n2. Preparar los datos\n3. Entregar")

        let tarea = arnes.estado.crearTarea(instruccion: "Preparar el informe")
        await arnes.estado.generarPlan(id: tarea.id)

        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)
        let cuerpo = try cuerpoDeLaPeticion(arnes, indice: 0)
        let json = try JSONSerialization.jsonObject(with: Data(cuerpo.utf8)) as? [String: Any]
        XCTAssertNil(
            json?["tools"],
            "El plan se genera en modo solo-texto: el payload no debe llevar tools"
        )

        let actual = try XCTUnwrap(arnes.estado.tareas.first { $0.id == tarea.id })
        XCTAssertEqual(actual.estado, .esperandoInicio)
        XCTAssertEqual(actual.plan?.pasos.map(\.texto), [
            "Revisar la solicitud",
            "Preparar los datos",
            "Entregar"
        ])

        // El plan sobrevive al cierre de la app.
        let store = try TareaStore(directorio: arnes.directorioTareas)
        XCTAssertEqual(store.cargar(id: tarea.id)?.plan?.pasos.count, 3)
    }

    func testSinPulsarEmpezarNoHayPasosNiLlamadaDeHerramienta() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Uno\n2. Dos")

        let tarea = arnes.estado.crearTarea(instruccion: "Solo planificar")
        await arnes.estado.generarPlan(id: tarea.id)

        let antes = try XCTUnwrap(arnes.estado.tareas.first { $0.id == tarea.id })
        XCTAssertEqual(antes.estado, .esperandoInicio)
        XCTAssertTrue(antes.pasos.isEmpty, "Sin Empezar no puede existir libro")
        XCTAssertEqual(arnes.transporte.cantidadDePeticiones, 1)
    }

    // MARK: - TASK.3: ejecucion y libro en vivo

    func testTraerUrlCreaElPasoIniciadoYTerminadoAntesDelResultadoFinal() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Traer los datos")

        let tarea = arnes.estado.crearTarea(instruccion: "Trae el informe")
        await arnes.estado.generarPlan(id: tarea.id)

        arnes.transporte.guionar(
            texto: "",
            uso: UsoTokens(entrada: 10, salida: 2),
            toolCalls: [
                ToolCall(
                    id: "c1",
                    nombre: "traer_url",
                    argumentos: "{\"url\":\"https://ejemplo.test/datos\"}"
                )
            ]
        )
        arnes.transporte.guionarUnaria(
            HTTPRespuesta(
                estado: 200,
                cabeceras: ["Content-Type": "text/plain"],
                cuerpo: Data("Contenido de la pagina de prueba".utf8)
            )
        )
        arnes.transporte.guionar(
            texto: "Listo, ya tengo los datos.",
            uso: UsoTokens(entrada: 20, salida: 5)
        )

        // Plan = stream 1, primera vuelta del bucle = stream 2, respuesta final
        // = stream 3. La retencion deja ver el disco ANTES del resultado final.
        arnes.transporte.retenerStream(en: 3)
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        let store = try TareaStore(directorio: arnes.directorioTareas)
        try await arnes.esperar(
            {
                store.cargar(id: tarea.id)?.pasos.first?.estado == .terminado
            },
            mensaje: "El paso de traer_url no se persistio como terminado"
        )

        let enDisco = try XCTUnwrap(store.cargar(id: tarea.id))
        let paso = try XCTUnwrap(enDisco.pasos.first)
        XCTAssertEqual(paso.herramienta, "traer_url")
        XCTAssertEqual(paso.estado, .terminado)
        XCTAssertEqual(paso.url, "https://ejemplo.test/datos")
        XCTAssertEqual(paso.llamadaID, "c1")
        XCTAssertNotNil(paso.fechaInicio)
        XCTAssertNotNil(paso.fechaFin)
        XCTAssertTrue(paso.resultado?.contains("Contenido de la pagina") == true)

        // El modelo todavia no ha dado la respuesta final: el paso ya estaba
        // persistido, que es justo lo que exige el libro en vivo.
        XCTAssertEqual(
            arnes.estado.tareas.first { $0.id == tarea.id }?.estado,
            .enCurso
        )

        arnes.transporte.liberarStreamRetenido()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        let completada = try XCTUnwrap(arnes.estado.tareas.first { $0.id == tarea.id })
        XCTAssertEqual(completada.pasos.count, 1)
        XCTAssertNotNil(completada.costoAcumuladoUSD)
        XCTAssertGreaterThan(completada.costoAcumuladoUSD ?? 0, 0)
    }

    func testDetenerAMitadDejaLaTareaDetenidaConLosPasosPreviosIntactos() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Traer dos paginas")

        let tarea = arnes.estado.crearTarea(instruccion: "Trae dos paginas")
        await arnes.estado.generarPlan(id: tarea.id)

        arnes.transporte.guionar(
            texto: "",
            uso: UsoTokens(entrada: 10, salida: 2),
            toolCalls: [
                ToolCall(
                    id: "c1",
                    nombre: "traer_url",
                    argumentos: "{\"url\":\"https://ejemplo.test/uno\"}"
                ),
                ToolCall(
                    id: "c2",
                    nombre: "traer_url",
                    argumentos: "{\"url\":\"https://ejemplo.test/dos\"}"
                )
            ]
        )
        arnes.transporte.guionarUnaria(
            HTTPRespuesta(estado: 200, cuerpo: Data("pagina uno".utf8))
        )
        arnes.transporte.guionarUnaria(
            HTTPRespuesta(estado: 200, cuerpo: Data("pagina dos".utf8))
        )

        // La segunda herramienta se queda esperando: ahi el dueno pulsa Detener.
        arnes.transporte.retenerUnaria(en: 2)
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        let store = try TareaStore(directorio: arnes.directorioTareas)
        try await arnes.esperar(
            {
                guard let libro = store.cargar(id: tarea.id)?.pasos else {
                    return false
                }
                return libro.count == 2
                    && libro[0].estado == .terminado
                    && libro[1].estado == .enCurso
            },
            mensaje: "La segunda herramienta no llegó a quedar en curso"
        )

        let antes = try XCTUnwrap(store.cargar(id: tarea.id)?.pasos.first)
        XCTAssertEqual(antes.estado, .terminado)
        XCTAssertEqual(antes.resultado, "pagina uno")

        arnes.estado.detenerTarea(id: tarea.id)

        XCTAssertEqual(
            arnes.estado.tareas.first { $0.id == tarea.id }?.estado,
            .detenida
        )
        let detenida = try XCTUnwrap(store.cargar(id: tarea.id))
        XCTAssertEqual(detenida.estado, .detenida)
        XCTAssertEqual(detenida.pasos.first?.estado, .terminado)
        XCTAssertEqual(detenida.pasos.first?.resultado, "pagina uno")

        // Se libera la red retenida para que no quede una continuacion colgada;
        // la generacion ya invalidada impide que ese resultado toque el libro.
        arnes.transporte.liberarUnariaRetenida()
        try await Task.sleep(nanoseconds: 100_000_000)

        let despues = try XCTUnwrap(store.cargar(id: tarea.id))
        XCTAssertEqual(despues.pasos.first?.estado, .terminado)
        XCTAssertEqual(despues.pasos.first?.resultado, "pagina uno")
    }

    // MARK: - TASK.4: aprobacion de escritura propuesta

    func testProponerMemoriaNoEscribeHastaAprobarYAlDenegarQuedaDenegado() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.estado.config.memoria = []
        arnes.transporte.guionar(texto: "1. Guardar el dato")

        let tarea = arnes.estado.crearTarea(instruccion: "Guarda que prefiero informes breves")
        await arnes.estado.generarPlan(id: tarea.id)

        arnes.transporte.guionar(
            texto: "",
            uso: UsoTokens(entrada: 10, salida: 2),
            toolCalls: [
                ToolCall(
                    id: "c1",
                    nombre: Memoria.nombreHerramientaTarea,
                    argumentos: "{\"accion\":\"guardar\",\"texto\":\"Prefiere informes breves\"}"
                )
            ]
        )
        arnes.transporte.guionar(texto: "Entendido, no guardé nada.")

        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            mensaje: "No se abrió la aprobación de proponer_memoria"
        )

        let store = try TareaStore(directorio: arnes.directorioTareas)
        let pendiente = try XCTUnwrap(store.cargar(id: tarea.id)?.pasos.first)
        XCTAssertEqual(pendiente.estado, .pendiente)
        XCTAssertEqual(pendiente.aprobacion, .pendiente)
        XCTAssertTrue(
            arnes.estado.config.memoria.allSatisfy {
                $0.texto != "Prefiere informes breves"
            },
            "La Memoria no puede cambiar antes de Aprobar"
        )

        arnes.estado.denegarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        let denegado = try XCTUnwrap(store.cargar(id: tarea.id)?.pasos.first)
        XCTAssertEqual(denegado.estado, .denegado)
        XCTAssertEqual(denegado.aprobacion, .denegada)
        XCTAssertEqual(denegado.resultado, "denegado por el dueno")
        XCTAssertTrue(
            arnes.estado.config.memoria.allSatisfy {
                $0.texto != "Prefiere informes breves"
            },
            "Denegar no puede escribir en Memoria"
        )

        // El rechazo volvio al modelo como resultado de la herramienta.
        let segunda = try cuerpoDeLaPeticion(arnes, indice: 2)
        XCTAssertTrue(segunda.contains("denegado por el dueno"))
    }

    func testProponerMemoriaAprobadaEscribeYDejaElPasoTerminado() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.estado.config.memoria = []
        arnes.transporte.guionar(texto: "1. Guardar el dato")

        let tarea = arnes.estado.crearTarea(instruccion: "Guarda que prefiero informes breves")
        await arnes.estado.generarPlan(id: tarea.id)

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "c1",
                    nombre: Memoria.nombreHerramientaTarea,
                    argumentos: "{\"accion\":\"guardar\",\"texto\":\"Prefiere informes breves\"}"
                )
            ]
        )
        arnes.transporte.guionar(texto: "Guardado.")

        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            mensaje: "No se abrió la aprobación de proponer_memoria"
        )

        XCTAssertTrue(arnes.estado.config.memoria.isEmpty)
        arnes.estado.aprobarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        XCTAssertTrue(
            arnes.estado.config.memoria.contains {
                $0.texto == "Prefiere informes breves"
            }
        )

        let store = try TareaStore(directorio: arnes.directorioTareas)
        let aprobado = try XCTUnwrap(store.cargar(id: tarea.id)?.pasos.first)
        XCTAssertEqual(aprobado.estado, .terminado)
        XCTAssertEqual(aprobado.aprobacion, .aprobada)
        XCTAssertTrue(aprobado.resultado?.contains("Guarde en Memoria") == true)
    }

    /// B2.4: la via de Tarea queda tipificada SIN cambiar su regimen. La prueba
    /// observable es el freno: aprobar una propuesta que reescribe una entrada
    /// sensible se rechaza igual que en Chat. La via vieja sin tipo la habria
    /// reescrito sin hoja.
    func testTareaNoReescribeUnaEntradaSensibleNiAprobandoLaHoja() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let sensible = EntradaMemoria(
            id: UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!,
            texto: "mi presión de prueba es 120 sobre 80",
            fecha: Date(timeIntervalSince1970: 400),
            categoria: .durableFact,
            categoriaSensible: .health
        )
        arnes.estado.config.memoria = [sensible]
        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Actualizar el dato")

        let tarea = arnes.estado.crearTarea(instruccion: "Actualiza mi presión")
        await arnes.estado.generarPlan(id: tarea.id)

        arnes.transporte.guionar(
            texto: "",
            toolCalls: [
                ToolCall(
                    id: "c-b24-tarea",
                    nombre: Memoria.nombreHerramientaTarea,
                    argumentos: #"{"accion":"actualizar","id":"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD","texto":"mi presión ahora es 130 sobre 90"}"#
                )
            ]
        )
        arnes.transporte.guionar(texto: "No se pudo actualizar.")

        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            mensaje: "No se abrió la aprobación de proponer_memoria"
        )

        arnes.estado.aprobarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        XCTAssertEqual(
            arnes.estado.config.memoria,
            [sensible],
            "Aprobar no puede reescribir una entrada sensible desde Tarea"
        )

        let store = try TareaStore(directorio: arnes.directorioTareas)
        let paso = try XCTUnwrap(store.cargar(id: tarea.id)?.pasos.first)
        XCTAssertTrue(
            paso.resultado?.contains("sensible") == true,
            "El rechazo interno explica por qué no se escribió: \(paso.resultado ?? "nil")"
        )
    }

    func testEnTareaNoSeOfrecenLasHerramientasDeChatYEnChatNoSeOfreceProponerMemoria() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        XCTAssertTrue(arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor))
        arnes.transporte.guionar(texto: "1. Responder")

        let tarea = arnes.estado.crearTarea(instruccion: "Solo responder")
        await arnes.estado.generarPlan(id: tarea.id)

        arnes.transporte.guionar(texto: "Listo")
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        let herramientasTarea = try nombresDeHerramientas(arnes, indice: 1)
        XCTAssertTrue(herramientasTarea.contains("traer_url"))
        XCTAssertTrue(herramientasTarea.contains(Memoria.nombreHerramientaTarea))
        XCTAssertFalse(herramientasTarea.contains(Memoria.nombreGuardar))
        XCTAssertFalse(herramientasTarea.contains(Memoria.nombreActualizar))
        XCTAssertFalse(herramientasTarea.contains(Memoria.nombreBorrar))
        XCTAssertFalse(herramientasTarea.contains(Memoria.nombreProponerSensible))
        XCTAssertFalse(
            herramientasTarea.contains { $0.contains("__") },
            "Sin servidor MCP configurado no puede aparecer ninguna herramienta remota"
        )

        // Chat normal con Memoria: ofrece las herramientas tipadas de escritura
        // (incluida la sensible de B2.4) y nunca la propuesta del Modo Tarea
        // (la frontera es por contexto, no por texto).
        arnes.transporte.guionar(texto: "Hola")
        arnes.estado.enviar("Hola")
        try await arnes.esperarTurno()

        let herramientasChat = try nombresDeHerramientas(arnes, indice: 2)
        XCTAssertTrue(herramientasChat.contains(Memoria.nombreGuardar))
        XCTAssertTrue(herramientasChat.contains(Memoria.nombreActualizar))
        XCTAssertTrue(herramientasChat.contains(Memoria.nombreProponerSensible))
        XCTAssertTrue(herramientasChat.contains(Memoria.nombreBorrar))
        XCTAssertFalse(herramientasChat.contains(Memoria.nombreHerramientaTarea))
    }

    // MARK: - Ayudas

    private func cuerpoDeLaPeticion(_ arnes: ArnesApp, indice: Int) throws -> String {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }

    private func nombresDeHerramientas(_ arnes: ArnesApp, indice: Int) throws -> [String] {
        let cuerpo = try cuerpoDeLaPeticion(arnes, indice: indice)
        let json = try JSONSerialization.jsonObject(with: Data(cuerpo.utf8))
            as? [String: Any]
        let tools = json?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { herramienta in
            (herramienta["function"] as? [String: Any])?["name"] as? String
        }
    }
}
