import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Nivel 1 de la Partida B3-B (progreso vivo): el ViewModel del hilo
/// alimentado por eventos REALES del libro, con transporte y relojes
/// inyectados solo bajo la capa de estado.
///
/// POR QUE no se afirma aqui la cota de 300 ms en pared: el ViewModel emite la
/// primera senal en el ciclo inmediato a [Empezar], pero el tiempo de pared se
/// mide sobre la traza viva/temporizada del nivel 2 (`TrazaVistaTest`). Lo que
/// esta suite fija es el ORDEN de las transiciones, la procedencia del costo,
/// el bloqueo por aprobacion, la preservacion al detener y el caso R17.
@MainActor
final class ProgresoVivoTests: XCTestCase {

    private let planDosPasos = "1. Consultar https://ejemplo.test/datos\n"
        + "2. Guardar en Memoria una frase sobre el dominio"

    // MARK: - Utilidades

    /// Crea la tarea, genera su plan y conecta el hilo al estado real.
    private func preparar(
        _ arnes: ArnesApp,
        plan: String? = nil
    ) async throws -> (Tarea, HiloTareaViewModel) {
        XCTAssertTrue(
            arnes.estado.guardarClave("clave-de-prueba", para: arnes.proveedor)
        )
        arnes.transporte.guionar(texto: plan ?? planDosPasos)
        let tarea = arnes.estado.crearTarea(
            instruccion: "Consulta el dominio y propone guardarlo"
        )
        await arnes.estado.generarPlan(id: tarea.id)

        let hilo = HiloTareaViewModel()
        hilo.conectar(a: arnes.estado, tareaID: tarea.id)
        return (tarea, hilo)
    }

    private func guionarTraerUrl(
        _ arnes: ArnesApp,
        id: String = "c1",
        url: String = "https://ejemplo.test/datos"
    ) {
        arnes.transporte.guionar(
            texto: "",
            uso: UsoTokens(entrada: 10, salida: 2),
            toolCalls: [
                ToolCall(
                    id: id,
                    nombre: "traer_url",
                    argumentos: "{\"url\":\"\(url)\"}"
                )
            ]
        )
        arnes.transporte.guionarUnaria(
            HTTPRespuesta(
                estado: 200,
                cabeceras: ["Content-Type": "text/plain"],
                cuerpo: Data("Contenido de la pagina".utf8)
            )
        )
    }

    private func guionarPropuestaDeMemoria(
        _ arnes: ArnesApp,
        id: String = "c2"
    ) {
        arnes.transporte.guionar(
            texto: "",
            uso: UsoTokens(entrada: 12, salida: 3),
            toolCalls: [
                ToolCall(
                    id: id,
                    nombre: Memoria.nombreHerramientaTarea,
                    argumentos: #"{"accion":"guardar","texto":"El dominio ejemplo.test sirve para pruebas"}"#
                )
            ]
        )
    }

    /// Transiciones `(paso, estado)` en el orden en que la traza las emitio.
    private func transiciones(
        _ traza: [String]
    ) -> [(paso: Int, estado: String)] {
        var salida: [(Int, String)] = []
        for linea in traza {
            guard linea.contains("] StepRow(paso: ") else { continue }
            guard let paso = Self.numero(entre: "StepRow(paso: ", y: ",", en: linea),
                  let estado = Self.texto(entre: "estado: \"", y: "\"", en: linea)
            else { continue }
            salida.append((paso, estado))
        }
        return salida
    }

    /// Fila viva del paso K, sin indice que pueda salirse del arreglo.
    private func fila(
        _ hilo: HiloTareaViewModel,
        paso: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HiloTareaViewModel.FilaViva {
        try XCTUnwrap(
            hilo.filas.first { $0.paso == paso },
            "No hay fila para el paso \(paso)",
            file: file,
            line: line
        )
    }

    private static func numero(
        entre inicio: String,
        y fin: String,
        en linea: String
    ) -> Int? {
        guard let rangoInicio = linea.range(of: inicio) else { return nil }
        let resto = linea[rangoInicio.upperBound...]
        guard let rangoFin = resto.range(of: fin) else { return nil }
        return Int(resto[..<rangoFin.lowerBound])
    }

    private static func texto(
        entre inicio: String,
        y fin: String,
        en linea: String
    ) -> String? {
        guard let rangoInicio = linea.range(of: inicio) else { return nil }
        let resto = linea[rangoInicio.upperBound...]
        guard let rangoFin = resto.range(of: fin) else { return nil }
        return String(resto[..<rangoFin.lowerBound])
    }

    // MARK: - (a) Orden Pendiente -> En curso -> Completado

    func testCadaFilaPasaDePendienteAEnCursoACompletadoSinSaltos() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        guionarTraerUrl(arnes)
        guionarPropuestaDeMemoria(arnes)
        arnes.transporte.guionar(
            texto: "Listo: no guardé nada porque lo denegaste.",
            uso: UsoTokens(entrada: 20, salida: 6)
        )

        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            mensaje: "La propuesta de memoria no llegó a la hoja"
        )
        arnes.estado.denegarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        let secuencia = transiciones(hilo.traza)
        XCTAssertFalse(secuencia.isEmpty, "La traza no registró transiciones")

        // Para CADA paso que llegó a Completado o Denegado hubo un En curso
        // anterior en la misma traza: ninguna fila cae de golpe.
        var vistos: [Int: Int] = [:]
        for (paso, estado) in secuencia {
            if estado == "Completado" || estado == "Denegado" {
                let enCurso = vistos[paso] ?? 0
                XCTAssertGreaterThan(
                    enCurso,
                    0,
                    "El paso \(paso) llegó a \(estado) sin En curso previo"
                )
            }
            if estado == "En curso" {
                vistos[paso] = (vistos[paso] ?? 0) + 1
            }
        }

        // Y las filas finales son las del libro: 1 completada, 2 denegada.
        XCTAssertEqual(hilo.filas.count, 2)
        XCTAssertEqual(try fila(hilo, paso: 1).estado, .completado)
        XCTAssertEqual(try fila(hilo, paso: 2).estado, .denegado)
        XCTAssertEqual(
            hilo.cabecera.estado,
            .completada,
            "La cabecera cierra en Completada"
        )
    }

    // MARK: - (b) Primera senal en el ciclo inmediato a [Empezar]

    func testLaPrimeraSenalSaleEnElCicloInmediatoYNoEsTextoGenerico() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        guionarTraerUrl(arnes)
        arnes.transporte.guionar(
            texto: "Listo",
            uso: UsoTokens(entrada: 8, salida: 2)
        )

        // La red de la primera vuelta queda retenida: si la senal dependiera de
        // la respuesta del modelo, no existiria todavia.
        arnes.transporte.retenerStream(en: 2)
        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        // Sin ceder el actor ni una vez:
        XCTAssertNotNil(hilo.primeraSenal, "No hubo primera señal")
        let primera = try fila(hilo, paso: 1)
        XCTAssertEqual(primera.paso, 1)
        XCTAssertEqual(primera.estado, .enCurso)
        XCTAssertFalse(
            primera.estadoDinamico.isEmpty,
            "La fila en curso no tiene estado dinámico real"
        )
        XCTAssertTrue(
            primera.estadoDinamico.contains("Consultando modelo"),
            "Estado dinámico inesperado: \(primera.estadoDinamico)"
        )
        XCTAssertTrue(
            primera.nombre.contains("Consultar"),
            "La fila no lleva el nombre real del paso: \(primera.nombre)"
        )
        XCTAssertEqual(hilo.cabecera.estado, .enCurso)
        XCTAssertEqual(hilo.cabecera.pasoActual, 1)
        XCTAssertEqual(
            hilo.cabecera.pasosTotales,
            2,
            "N son los pasos del plan desde el primer instante"
        )

        arnes.transporte.liberarStreamRetenido()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)
    }

    // MARK: - (c) El costo es el sello del libro, no un recalculo

    func testElCostoDeCadaFilaYDeLaCabeceraSonLosSellosDelLibro() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        guionarTraerUrl(arnes)
        arnes.transporte.guionar(
            texto: "Listo",
            uso: UsoTokens(entrada: 9, salida: 3)
        )

        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        let enLibro = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertFalse(enLibro.pasos.isEmpty)
        for (indice, paso) in enLibro.pasos.enumerated() {
            let sello = try XCTUnwrap(
                paso.costoUSD,
                "El libro no selló el costo del paso \(indice + 1)"
            )
            XCTAssertEqual(
                try fila(hilo, paso: indice + 1).costo,
                Decimal(sello)
            )
        }
        XCTAssertEqual(
            hilo.cabecera.costoSellado,
            Decimal(enLibro.costoAcumuladoUSD ?? 0)
        )

        // Cambiar los precios del proveedor activo no mueve NINGUNA cifra:
        // las filas ya cerradas conservan su sello.
        let cabeceraAntes = hilo.cabecera.costoSellado
        let filasAntes = hilo.filas.map(\.costo)
        var config = arnes.estado.config
        for indice in config.proveedores.indices {
            config.proveedores[indice].precioEntradaPorMillon = 999
            config.proveedores[indice].precioSalidaPorMillon = 999
        }
        arnes.estado.config = config

        XCTAssertEqual(hilo.cabecera.costoSellado, cabeceraAntes)
        XCTAssertEqual(hilo.filas.map(\.costo), filasAntes)
        XCTAssertEqual(
            hilo.cabecera.costoSellado,
            Decimal(
                arnes.estado.tareas.first { $0.id == tarea.id }?
                    .costoAcumuladoUSD ?? 0
            ),
            "El sello del libro tampoco se revaloriza"
        )
    }

    // MARK: - (d) Aprobacion pendiente: estado y bloqueo del paso siguiente

    func testLaAprobacionPendienteDejaElHiloEsperandoYBloqueaElPasoSiguiente() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        guionarTraerUrl(arnes)
        guionarPropuestaDeMemoria(arnes)
        arnes.transporte.guionar(
            texto: "Listo",
            uso: UsoTokens(entrada: 14, salida: 4)
        )

        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            mensaje: "La propuesta de memoria no llegó a la hoja"
        )

        XCTAssertEqual(hilo.cabecera.estado, .esperandoAprobacion)
        XCTAssertEqual(try fila(hilo, paso: 2).estado, .esperandoAprobacion)

        // Un evento del paso siguiente no puede avanzar mientras la decision
        // este pendiente: la tarea no corre por detras de la hoja. Se ejerce
        // en un hilo aislado con los MISMOS eventos, para no consumir un
        // numero de secuencia de la corrida real que se esta midiendo.
        let congelado = HiloTareaViewModel()
        congelado.aplicar(
            EventoTareaEjecucion(
                secuencia: 1,
                tareaID: tarea.id,
                tipo: .turnoIniciado,
                paso: 1,
                pasosTotales: 2,
                etiqueta: "Consultar el dominio",
                estadoDinamico: "Consultando modelo…",
                estado: .enCurso
            )
        )
        congelado.aplicar(
            EventoTareaEjecucion(
                secuencia: 2,
                tareaID: tarea.id,
                tipo: .pasoIniciado,
                paso: 1,
                pasosTotales: 2,
                etiqueta: "Leer enlace",
                estadoDinamico: "Consultando ejemplo.test…",
                estado: .enCurso
            )
        )
        congelado.aplicar(
            EventoTareaEjecucion(
                secuencia: 3,
                tareaID: tarea.id,
                tipo: .pasoCerrado,
                paso: 1,
                pasosTotales: 2,
                estado: .completado,
                duracion: 1.1,
                costo: Decimal(string: "0.000004")
            )
        )
        congelado.aplicar(
            EventoTareaEjecucion(
                secuencia: 4,
                tareaID: tarea.id,
                tipo: .aprobacionPendiente,
                paso: 2,
                pasosTotales: 2,
                etiqueta: "Guardar en Memoria",
                estadoDinamico: "Esperando tu aprobación",
                estado: .esperandoAprobacion
            )
        )
        congelado.aplicar(
            EventoTareaEjecucion(
                secuencia: 5,
                tareaID: tarea.id,
                tipo: .pasoIniciado,
                paso: 3,
                pasosTotales: 2,
                etiqueta: "Paso intruso",
                estadoDinamico: "Ejecutando…",
                estado: .enCurso
            )
        )
        XCTAssertNil(
            congelado.filas.first { $0.paso == 3 },
            "El paso siguiente avanzó con la aprobación pendiente"
        )
        XCTAssertEqual(congelado.cabecera.estado, .esperandoAprobacion)

        arnes.estado.denegarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        XCTAssertEqual(try fila(hilo, paso: 2).estado, .denegado)
        // La denegacion no dejo entrada en Memoria.
        XCTAssertTrue(
            arnes.estado.config.memoria.allSatisfy {
                !$0.texto.contains("ejemplo.test sirve")
            },
            "La denegación escribió en Memoria"
        )
    }

    // MARK: - (e) Detener en K=2 conserva lo resuelto y el composer

    func testDetenerEnK2ConservaLaFila1YSoloEllaYElComposerQuedaDisponible() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        arnes.transporte.guionar(
            texto: "",
            uso: UsoTokens(entrada: 10, salida: 2),
            toolCalls: [
                ToolCall(
                    id: "c1",
                    nombre: "traer_url",
                    argumentos: #"{"url":"https://ejemplo.test/uno"}"#
                ),
                ToolCall(
                    id: "c2",
                    nombre: "traer_url",
                    argumentos: #"{"url":"https://ejemplo.test/dos"}"#
                )
            ]
        )
        arnes.transporte.guionarUnaria(
            HTTPRespuesta(estado: 200, cuerpo: Data("pagina uno".utf8))
        )
        arnes.transporte.guionarUnaria(
            HTTPRespuesta(estado: 200, cuerpo: Data("pagina dos".utf8))
        )
        arnes.transporte.retenerUnaria(en: 2)

        hilo.marcarToqueEmpezar()
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

        arnes.estado.detenerTarea(id: tarea.id)

        let detenida = try XCTUnwrap(store.cargar(id: tarea.id))
        XCTAssertEqual(detenida.estado, .detenida)
        XCTAssertEqual(detenida.pasos.count, 2)

        // Fila 1: completada, con resultado y sello.
        let primeraFila = try fila(hilo, paso: 1)
        XCTAssertEqual(primeraFila.estado, .completado)
        XCTAssertNotNil(primeraFila.duracion)
        XCTAssertNotNil(primeraFila.costo)
        XCTAssertEqual(detenida.pasos[0].resultado, "pagina uno")

        // Fila 2: NO completada.
        XCTAssertNotEqual(try fila(hilo, paso: 2).estado, .completado)
        XCTAssertNil(detenida.pasos[1].costoUSD)

        // No hay paso 3.
        XCTAssertNil(hilo.filas.first { $0.paso == 3 })

        // Composer disponible: ni planificando ni en curso.
        XCTAssertNil(arnes.estado.idTareaPlanificando)
        XCTAssertEqual(detenida.estado, .detenida)

        // Rehidratacion desde disco: misma fila 1 con sello, fila 2 sin cerrar.
        let rehidratado = HiloTareaViewModel()
        rehidratado.reconstruir(
            con: detenida,
            proyeccion: arnes.estado.elementosVisiblesDeTarea(detenida)
        )
        XCTAssertEqual(rehidratado.filas.count, 2)
        let rehidratadaUno = try fila(rehidratado, paso: 1)
        XCTAssertEqual(rehidratadaUno.estado, .completado)
        XCTAssertNotNil(rehidratadaUno.costo)
        XCTAssertNotEqual(try fila(rehidratado, paso: 2).estado, .completado)
        XCTAssertEqual(rehidratado.cabecera.estado, .detenida)
    }

    // MARK: - (f) Caso R17: interleaving de deltas, herramienta y paso siguiente

    func testElInterleavingDeEventosRealesRespetaElOrdenYNoPierdeTransiciones() {
        let tareaID = UUID()
        let eventos: [EventoTareaEjecucion] = [
            EventoTareaEjecucion(
                secuencia: 1,
                tareaID: tareaID,
                tipo: .turnoIniciado,
                paso: 1,
                pasosTotales: 2,
                etiqueta: "Consultar el dominio",
                estadoDinamico: "Consultando modelo…",
                estado: .enCurso
            ),
            EventoTareaEjecucion(
                secuencia: 2,
                tareaID: tareaID,
                tipo: .pasoIniciado,
                paso: 1,
                pasosTotales: 2,
                etiqueta: "Leer enlace",
                estadoDinamico: "Consultando ejemplo.test…",
                estado: .enCurso
            ),
            EventoTareaEjecucion(
                secuencia: 3,
                tareaID: tareaID,
                tipo: .costoSellado,
                paso: 1,
                pasosTotales: 2,
                costoSelladoTarea: Decimal(string: "0.000012"),
                estado: .enCurso
            ),
            EventoTareaEjecucion(
                secuencia: 4,
                tareaID: tareaID,
                tipo: .pasoCerrado,
                paso: 1,
                pasosTotales: 2,
                etiqueta: "Leer enlace",
                estado: .completado,
                duracion: 1.3,
                costo: Decimal(string: "0.000012")
            ),
            EventoTareaEjecucion(
                secuencia: 5,
                tareaID: tareaID,
                tipo: .pasoIniciado,
                paso: 2,
                pasosTotales: 2,
                etiqueta: "Guardar en Memoria",
                estadoDinamico: "Ejecutando la herramienta…",
                estado: .enCurso
            ),
            EventoTareaEjecucion(
                secuencia: 6,
                tareaID: tareaID,
                tipo: .aprobacionPendiente,
                paso: 2,
                pasosTotales: 2,
                etiqueta: "Guardar en Memoria",
                estadoDinamico: "Esperando tu aprobación",
                estado: .esperandoAprobacion
            ),
            EventoTareaEjecucion(
                secuencia: 7,
                tareaID: tareaID,
                tipo: .pasoCerrado,
                paso: 2,
                pasosTotales: 2,
                etiqueta: "Guardar en Memoria",
                estado: .denegado,
                detalle: "Denegada por ti"
            ),
            EventoTareaEjecucion(
                secuencia: 8,
                tareaID: tareaID,
                tipo: .finalizada,
                paso: 2,
                pasosTotales: 2
            )
        ]

        let secuencial = HiloTareaViewModel()
        for evento in eventos { secuencial.aplicar(evento) }

        // Se entregan adelantados y desordenados: la cola los reordena.
        let intercalado = HiloTareaViewModel()
        for indice in [3, 1, 7, 2, 5, 8, 4, 6] {
            intercalado.aplicar(eventos[indice - 1])
        }

        XCTAssertEqual(
            intercalado.traza,
            secuencial.traza,
            "La traza sigue el orden de emisión, no el de llegada"
        )
        XCTAssertEqual(intercalado.filas, secuencial.filas)
        XCTAssertEqual(intercalado.cabecera, secuencial.cabecera)

        let secuencia = transiciones(secuencial.traza)
        XCTAssertTrue(secuencia.contains { $0.paso == 1 && $0.estado == "Completado" })
        XCTAssertTrue(secuencia.contains { $0.paso == 2 && $0.estado == "Denegado" })
        XCTAssertEqual(try fila(secuencial, paso: 1).duracion, 1.3)
        XCTAssertEqual(
            try fila(secuencial, paso: 1).costo,
            Decimal(string: "0.000012")
        )
    }

    // MARK: - (g) Negativo: las cadenas demolidas no existen

    func testLasCadenasDemolidasNoAparecenEnLosTextosDelViewModel() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        guionarTraerUrl(arnes)
        arnes.transporte.guionar(
            texto: "Listo",
            uso: UsoTokens(entrada: 8, salida: 2)
        )

        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        var textos: [String] = [hilo.trazaTexto, hilo.cabecera.actividad]
        for elemento in hilo.elementos {
            switch elemento {
            case .burbujaUsuario(let texto): textos.append(texto)
            case .tarjetaPlan(let pasos, _, _):
                textos.append(contentsOf: pasos.map(\.texto))
            case .filaPaso(_, _, let etiqueta, _, _): textos.append(etiqueta)
            case .errorEnLinea(let texto): textos.append(texto)
            case .resultadoFinal(let texto): textos.append(texto)
            }
        }

        for demolida in [
            "La ejecución acaba de empezar",
            "Los pasos aparecerán aquí"
        ] {
            for texto in textos {
                XCTAssertFalse(
                    texto.contains(demolida),
                    "Sobrevive la cadena demolida «\(demolida)»"
                )
            }
        }

        // El catalogo cerrado no admite filas con JSON crudo ni UUIDs.
        for texto in textos {
            XCTAssertNil(
                texto.range(
                    of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                        + "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                    options: .regularExpression
                ),
                "Un UUID llegó a un texto visible"
            )
        }
    }
}
