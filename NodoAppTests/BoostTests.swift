import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de BOOST.1/BOOST.2 sobre el `EstadoApp` real.
///
/// El arnes es el mismo de TASK: transporte guionizado, llavero falso y
/// directorios temporales. Aqui se guioniza, en orden de cola, el plan y las
/// tres fases de la tuberia; asi se comprueba el orden real de las llamadas, el
/// libro que queda en disco y los sellos de costo de cada fase.
@MainActor
final class BoostTests: XCTestCase {
    // MARK: - BOOST.1: las tres fases

    func testBoostEjecutaOrquestacionAngulosYSintesisEnOrdenConCombosDistintos() async throws {
        let corrida = try await correrBoost()
        defer { corrida.arnes.limpiar() }

        let tarea = try tareaEnDisco(corrida)
        XCTAssertEqual(tarea.estado, .completada)

        // El libro conserva el orden de la tuberia: orquestacion, un angulo por
        // llamada y sintesis. Si el orden cambiara, la sintesis no tendria nada
        // que cruzar.
        XCTAssertEqual(
            tarea.pasos.map(\.fase),
            [.orquestacion, .angulo, .angulo, .sintesis]
        )
        XCTAssertEqual(tarea.pasos.map(\.numeroAngulo), [nil, 1, 2, nil])
        XCTAssertEqual(
            tarea.pasos.map(\.etiquetaDeFase),
            ["Orquestación", "Ángulo 1", "Ángulo 2", "Síntesis"]
        )

        // FASE 1 y FASE 3 van al combo fuerte: el de mayor precio de salida.
        XCTAssertEqual(tarea.pasos.first?.proveedorNombre, "sol")
        XCTAssertEqual(tarea.pasos.last?.proveedorNombre, "sol")

        // FASE 2: combos baratos DISTINTOS, en orden de precio ascendente.
        let angulos = tarea.pasos.filter { $0.fase == .angulo }
        XCTAssertEqual(angulos.map(\.proveedorNombre), ["deepseek", "glm"])
        XCTAssertEqual(Set(angulos.compactMap(\.proveedorID)).count, 2)

        // Sin herramientas: un angulo es analisis, no ejecucion.
        let orquestacion = try cuerpoDeLaPeticion(corrida.arnes, indice: 1)
        XCTAssertFalse(orquestacion.contains("\"tools\""))
        let sintesis = try cuerpoDeLaPeticion(corrida.arnes, indice: 4)
        XCTAssertFalse(sintesis.contains("\"tools\""))

        // El plan se pidio sobre la instruccion efectiva: /boost es el disparo,
        // no parte del encargo.
        let plan = try cuerpoDeLaPeticion(corrida.arnes, indice: 0)
        XCTAssertFalse(plan.contains("/boost"))
        XCTAssertTrue(plan.contains("migrar el servicio"))
    }

    // MARK: - BOOST.1: respuesta final y marca

    func testLaRespuestaFinalEsLaDeLaSintesisYLlevaLaMarcaDeVerificada() async throws {
        let corrida = try await correrBoost()
        defer { corrida.arnes.limpiar() }

        let tarea = try tareaEnDisco(corrida)
        XCTAssertEqual(tarea.resultado, "Respuesta final cruzada: migrar por fases.")
        XCTAssertTrue(
            tarea.verificadoPorCruce,
            "La sintesis corrio: la respuesta tiene que quedar marcada"
        )

        // La sintesis recibio los resultados de los DOS angulos: el cruce no es
        // una promesa, es el cuerpo real de la llamada.
        let sintesis = try cuerpoDeLaPeticion(corrida.arnes, indice: 4)
        XCTAssertTrue(sintesis.contains("El coste ronda los dos sprints."))
        XCTAssertTrue(sintesis.contains("El riesgo principal es la concurrencia."))
        XCTAssertTrue(sintesis.contains("deepseek"))
        XCTAssertTrue(sintesis.contains("glm"))
    }

    // MARK: - BOOST.1/COST: costo total

    func testCostoTotalDelBoostEsLaSumaDeLosSellosDeFase() async throws {
        let corrida = try await correrBoost()
        defer { corrida.arnes.limpiar() }

        let tarea = try tareaEnDisco(corrida)
        let sellos = tarea.pasos.compactMap(\.costoUSD)
        XCTAssertEqual(sellos.count, 4, "Cada fase tiene que quedar sellada")

        let suma = try XCTUnwrap(tarea.costoBoostUSD)
        XCTAssertEqual(suma, sellos.reduce(0, +), accuracy: 1e-12)
        XCTAssertGreaterThan(suma, 0)

        // El acumulado de la tarea es el plan mas la tuberia: el costo del
        // boost no se come ni duplica el de la planificacion.
        XCTAssertEqual(
            try XCTUnwrap(tarea.costoAcumuladoUSD),
            corrida.costoTrasPlan + suma,
            accuracy: 1e-12
        )
    }

    // MARK: - Ayudas

    /// Configuracion con tres combos de precios distintos.
    ///
    /// El combo fuerte es "sol" (mayor precio de salida); los baratos son
    /// "deepseek" y "glm", en ese orden ascendente. Los nombres son los del
    /// ejemplo del dueno para que el test se lea como la regla.
    private static func configuracionDeBoost() -> AppConfig {
        let deepseek = ProviderConfig(
            nombre: "deepseek",
            baseURL: "https://api.deepseek.test/v1",
            modelo: "deepseek-chat",
            precioEntradaPorMillon: 0.10,
            precioSalidaPorMillon: 0.20
        )
        let glm = ProviderConfig(
            nombre: "glm",
            baseURL: "https://api.glm.test/v1",
            modelo: "glm-4",
            precioEntradaPorMillon: 0.50,
            precioSalidaPorMillon: 0.80
        )
        let sol = ProviderConfig(
            nombre: "sol",
            baseURL: "https://api.sol.test/v1",
            modelo: "sol-pro",
            precioEntradaPorMillon: 2.00,
            precioSalidaPorMillon: 8.00
        )
        return AppConfig(
            proveedores: [deepseek, glm, sol],
            proveedorActivo: sol.id
        )
    }

    /// Guioniza plan, orquestacion, dos angulos y sintesis, y ejecuta Empezar.
    ///
    /// Devuelve tambien el costo acumulado tras el plan, que es la linea base
    /// para comprobar que el total de la tarea es plan + fases.
    private func correrBoost() async throws -> (
        arnes: ArnesApp,
        id: UUID,
        costoTrasPlan: Double
    ) {
        let arnes = try ArnesApp(config: Self.configuracionDeBoost())
        for proveedor in arnes.estado.config.proveedores {
            XCTAssertTrue(
                arnes.estado.guardarClave(
                    "clave-\(proveedor.nombre)",
                    para: proveedor
                ),
                "No se pudo sembrar la clave de \(proveedor.nombre)"
            )
        }

        // Stream 1: plan. Se pide sobre la instruccion efectiva, sin /boost.
        arnes.transporte.guionar(
            texto: "1. Revisar el estado del arte\n2. Contrastar cifras",
            uso: UsoTokens(entrada: 50, salida: 10)
        )

        let tarea = arnes.estado.crearTarea(
            instruccion: "/boost ¿Conviene migrar el servicio a Swift 6?"
        )
        await arnes.estado.generarPlan(id: tarea.id)

        let costoTrasPlan = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }?.costoAcumuladoUSD
        )

        // Stream 2: orquestacion (combo fuerte).
        arnes.transporte.guionar(
            texto: "1. Coste de la migración\n2. Riesgos de concurrencia",
            uso: UsoTokens(entrada: 100, salida: 40)
        )
        // Stream 3 y 4: un angulo por llamada, cada uno con su combo barato.
        arnes.transporte.guionar(
            texto: "El coste ronda los dos sprints.",
            uso: UsoTokens(entrada: 60, salida: 20)
        )
        arnes.transporte.guionar(
            texto: "El riesgo principal es la concurrencia.",
            uso: UsoTokens(entrada: 61, salida: 21)
        )
        // Stream 5: sintesis (combo fuerte).
        arnes.transporte.guionar(
            texto: "Respuesta final cruzada: migrar por fases.",
            uso: UsoTokens(entrada: 200, salida: 60)
        )

        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        return (arnes, tarea.id, costoTrasPlan)
    }

    private func tareaEnDisco(
        _ corrida: (arnes: ArnesApp, id: UUID, costoTrasPlan: Double)
    ) throws -> Tarea {
        let store = try TareaStore(directorio: corrida.arnes.directorioTareas)
        return try XCTUnwrap(store.cargar(id: corrida.id))
    }

    private func cuerpoDeLaPeticion(_ arnes: ArnesApp, indice: Int) throws -> String {
        let peticiones = arnes.transporte.peticionesRegistradas
        XCTAssertGreaterThan(peticiones.count, indice)
        let datos = try XCTUnwrap(peticiones[indice].cuerpo)
        return try XCTUnwrap(String(data: datos, encoding: .utf8))
    }
}
