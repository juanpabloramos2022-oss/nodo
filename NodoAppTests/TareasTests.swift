import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de TASK.1/TASK.2 sobre el `EstadoApp` real y su almacen temporal.
///
/// El arnes inyecta llavero, defaults, transporte y directorios: no toca el
/// telefono ni sale a internet. El plan se guioniza con el mismo transporte SSE
/// que usa la app, asi que se comprueba el cuerpo real que se manda al modelo.
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
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        XCTAssertEqual(arnes.estado.tareas.first?.estado, .enCurso)

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

        let store = try TareaStore(directorio: arnes.directorioTareas)
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

        // Empezar en TASK.2 solo autoriza: no crea pasos ni llama a nada.
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        let despues = try XCTUnwrap(arnes.estado.tareas.first { $0.id == tarea.id })
        XCTAssertEqual(despues.estado, .enCurso)
        XCTAssertTrue(despues.pasos.isEmpty)
        XCTAssertEqual(
            arnes.transporte.cantidadDePeticiones,
            1,
            "Empezar no puede ejecutar herramientas en TASK.2"
        )
    }

    // MARK: - Ayudas

    private func cuerpoDeLaPeticion(_ arnes: ArnesApp, indice: Int) throws -> String {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }
}
