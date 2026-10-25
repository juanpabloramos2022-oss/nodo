import XCTest

@testable import NodoCore

/// Pruebas del modelo de Tarea, del parser de planes y de su almacen.
///
/// Viven en NodoCore para que `swift test` las corra sin simulador: el flujo
/// plan-primero depende de que el plan se normalice y se guarde igual en la
/// app y en las pruebas.
final class TareaTests: XCTestCase {
    private var directorio: URL!
    private var store: TareaStore!

    override func setUpWithError() throws {
        directorio = Ayudas.directorioTemporal()
        store = try TareaStore(directorio: directorio)
    }

    override func tearDownWithError() throws {
        if let directorio {
            try? FileManager.default.removeItem(at: directorio)
        }
    }

    // MARK: - Plan

    func testPlanDesdeListaNumeradaConservaOrdenYTexto() {
        let plan = PlanTarea.desde(
            texto: "1. Revisar la solicitud\n2) Preparar los datos\n- Entregar el informe"
        )

        XCTAssertEqual(plan.pasos.map(\.texto), [
            "Revisar la solicitud",
            "Preparar los datos",
            "Entregar el informe"
        ])
        XCTAssertEqual(plan.pasos.map(\.orden), [1, 2, 3])
    }

    func testPlanAceptaFormatoPasoYDescartaCabecera() {
        let plan = PlanTarea.desde(
            texto: "Plan:\nPaso 1: Abrir el archivo\nPaso 2: Cerrar el archivo"
        )

        XCTAssertEqual(plan.pasos.map(\.texto), [
            "Abrir el archivo",
            "Cerrar el archivo"
        ])
    }

    func testPlanSinListaSeConservaComoUnUnicoPaso() {
        let plan = PlanTarea.desde(texto: "Revisar todo y avisar al dueno.")

        XCTAssertEqual(plan.pasos.count, 1)
        XCTAssertEqual(plan.pasos.first?.texto, "Revisar todo y avisar al dueno.")
    }

    func testPlanVacioNoInventaPasos() {
        let plan = PlanTarea.desde(texto: "   \n  ")

        XCTAssertTrue(plan.pasos.isEmpty)
        XCTAssertTrue(plan.estaVacio)
    }

    // MARK: - Tarea

    func testTareaConservaPlanYProgresoDelLibro() throws {
        let plan = PlanTarea.desde(texto: "1. Uno\n2. Dos")
        let tarea = Tarea(
            instruccion: "Hacer algo",
            estado: .esperandoInicio,
            pasos: [
                Paso(descripcion: "Uno", estado: .terminado),
                Paso(descripcion: "Dos", estado: .pendiente)
            ],
            plan: plan
        )

        let datos = try JSONEncoder().encode(tarea)
        let cargada = try JSONDecoder().decode(Tarea.self, from: datos)

        XCTAssertEqual(cargada.id, tarea.id)
        XCTAssertEqual(cargada.instruccion, "Hacer algo")
        XCTAssertEqual(cargada.estado, .esperandoInicio)
        XCTAssertEqual(cargada.plan?.pasos.count, 2)
        XCTAssertEqual(cargada.progreso?.terminados, 1)
        XCTAssertEqual(cargada.progreso?.total, 2)
    }

    func testTareaSinLibroNoTieneProgreso() {
        let tarea = Tarea(instruccion: "Sin ejecutar", estado: .esperandoInicio)

        XCTAssertNil(tarea.progreso)
        XCTAssertEqual(tarea.titulo, "Sin ejecutar")
    }

    /// B3-A: un archivo escrito antes del hilo no trae turnos, ni error, ni
    /// version de plan. Se lee con los defaults y no pierde la tarea.
    func testUnArchivoViejoSeLeeConTurnosVaciosYVersionUno() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "instruccion": "Tarea vieja",
          "estado": "esperandoInicio",
          "plan": {
            "pasos": [{"orden": 1, "texto": "Uno"}],
            "texto": "1. Uno"
          },
          "fechaCreacion": "2026-01-01T00:00:00Z",
          "fechaActualizacion": "2026-01-01T00:00:00Z"
        }
        """
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        let tarea = try decodificador.decode(
            Tarea.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(tarea.instruccion, "Tarea vieja")
        XCTAssertEqual(tarea.turnos, [])
        XCTAssertNil(tarea.ultimoError)
        XCTAssertEqual(tarea.versionPlan, 0)
        XCTAssertEqual(tarea.plan?.version, 1)
        XCTAssertEqual(tarea.instruccionParaPlan, "Tarea vieja")
    }

    func testElLibroConservaHerramientaResultadoAprobacionYCosto() throws {
        let tarea = Tarea(
            instruccion: "Guardar un dato",
            estado: .completada,
            pasos: [
                Paso(
                    descripcion: "Guardar en Memoria: Prefiere informes breves",
                    estado: .denegado,
                    herramienta: Memoria.nombreHerramientaTarea,
                    argumentos: "{\"accion\":\"guardar\"}",
                    resultado: "denegado por el dueno",
                    llamadaID: "c1",
                    aprobacion: .denegada,
                    fechaInicio: Date(timeIntervalSince1970: 1_000),
                    fechaFin: Date(timeIntervalSince1970: 1_001)
                )
            ],
            costoAcumuladoUSD: 0.00042
        )

        let datos = try JSONEncoder().encode(tarea)
        let cargada = try JSONDecoder().decode(Tarea.self, from: datos)
        let paso = try XCTUnwrap(cargada.pasos.first)

        XCTAssertEqual(paso.herramienta, Memoria.nombreHerramientaTarea)
        XCTAssertEqual(paso.estado, .denegado)
        XCTAssertEqual(paso.aprobacion, .denegada)
        XCTAssertEqual(paso.resultado, "denegado por el dueno")
        XCTAssertEqual(cargada.costoAcumuladoUSD, 0.00042)
    }

    // MARK: - Store

    func testStoreGuardaListaYOrdenaPorActualizacion() throws {
        let vieja = Tarea(
            instruccion: "Vieja",
            fechaActualizacion: Date(timeIntervalSince1970: 1_000)
        )
        let nueva = Tarea(
            instruccion: "Nueva",
            fechaActualizacion: Date(timeIntervalSince1970: 2_000)
        )
        try store.guardar(vieja)
        try store.guardar(nueva)

        XCTAssertEqual(store.listar().map(\.instruccion), ["Nueva", "Vieja"])
        XCTAssertEqual(store.cargar(id: vieja.id)?.estado, .borrador)
    }

    func testStoreBorraSoloLaTareaIndicada() throws {
        let una = Tarea(instruccion: "Una")
        let otra = Tarea(instruccion: "Otra")
        try store.guardar(una)
        try store.guardar(otra)

        try store.borrar(id: una.id)

        XCTAssertNil(store.cargar(id: una.id))
        XCTAssertNotNil(store.cargar(id: otra.id))
    }

    func testMarcarInterrumpidasSoloTocaLasQueEstabanEnCurso() throws {
        let enCurso = Tarea(instruccion: "En curso", estado: .enCurso)
        let esperando = Tarea(instruccion: "Esperando", estado: .esperandoInicio)
        try store.guardar(enCurso)
        try store.guardar(esperando)

        let cambiadas = store.marcarInterrumpidas(
            fecha: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(cambiadas, 1)
        XCTAssertEqual(store.cargar(id: enCurso.id)?.estado, .interrumpida)
        XCTAssertEqual(store.cargar(id: esperando.id)?.estado, .esperandoInicio)
    }

    func testArchivoCorruptoNoRompeLaLista() throws {
        try store.guardar(Tarea(instruccion: "Buena"))

        let rutaMala = directorio.appendingPathComponent("\(UUID().uuidString).json")
        try Data("esto no es json".utf8).write(to: rutaMala)

        XCTAssertEqual(store.listar().count, 1)
        XCTAssertEqual(store.listar().first?.instruccion, "Buena")
    }
}
