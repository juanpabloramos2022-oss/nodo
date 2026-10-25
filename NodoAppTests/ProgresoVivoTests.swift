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

        // Ninguna fila cae de golpe: un paso que llega a Completado pasó antes
        // por En curso, y uno Denegado pasó antes por «Esperando aprobación»
        // (se deniega ANTES de ejecutarse, así que nunca estuvo En curso).
        var vistos: [Int: Set<String>] = [:]
        for (paso, estado) in secuencia {
            switch estado {
            case "Completado":
                XCTAssertTrue(
                    vistos[paso, default: []].contains("En curso"),
                    "El paso \(paso) llegó a Completado sin En curso previo"
                )
            case "Denegado":
                XCTAssertTrue(
                    vistos[paso, default: []].contains("Esperando aprobación"),
                    "El paso \(paso) llegó a Denegado sin pasar por la hoja"
                )
            default:
                break
            }
            vistos[paso, default: []].insert(estado)
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
        // M1: el denominador es el LIBRO. Al tocar [Empezar] el libro acaba de
        // resetearse, asi que N = 1; el plan de 2 pasos no es la unidad del
        // progreso (no hay mapeo 1:1 entre plan y libro).
        XCTAssertEqual(
            hilo.cabecera.pasosTotales,
            1,
            "N es el libro (vacio tras el toque), no los pasos del plan"
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

        // M2-unit: con el estado real, la única condición de render de la
        // tarjeta devuelve la solicitud de ESTA tarea para la fila que espera.
        XCTAssertNotNil(
            hilo.solicitudAprobacionEnHilo(
                paso: 2,
                estado: try fila(hilo, paso: 2).estado
            ),
            "La tarjeta no se renderizaría con la solicitud real en curso"
        )

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
                estado: .enCurso,
                costoSelladoTarea: Decimal(string: "0.000012")
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

    // MARK: - (h) M1: el denominador es el libro, no el plan

    /// Plan de siete pasos: la tarjeta los muestra, el libro ejecuta dos.
    private let planSietePasos = """
    1. Consultar https://ejemplo.test/datos
    2. Guardar en Memoria una frase sobre el dominio
    3. Extraer los datos clave del dominio
    4. Redactar una frase breve
    5. Comprobar el límite de extensión
    6. Presentar la frase al usuario
    7. Guardar la frase en Memoria
    """

    /// Discriminador de M1: plan de 7 pasos con libro de 2 → 2/2, nunca 7.
    ///
    /// Es la forma de B3-B: el plan promete siete pasos y el modelo resuelve
    /// la tarea en dos llamadas de herramienta. La cabecera en vivo y la
    /// proyeccion de reapertura tienen que decir LO MISMO (2/2) y la tarjeta
    /// de plan conserva sus siete pasos.
    func testLaCabeceraCuentaElLibroYNoElPlanEnVivoYAlReabrir() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes, plan: planSietePasos)
        let conPlan = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(
            conPlan.plan?.pasos.count,
            7,
            "El guion necesita un plan de 7 pasos"
        )

        guionarTraerUrl(arnes)
        guionarPropuestaDeMemoria(arnes)
        arnes.transporte.guionar(
            texto: "Listo: no guardé nada porque lo denegaste.",
            uso: UsoTokens(entrada: 20, salida: 6)
        )

        hilo.marcarToqueEmpezar()
        XCTAssertTrue(arnes.estado.empezarTarea(id: tarea.id))

        // Primera señal: el libro está vacío, así que el total es 1.
        XCTAssertEqual(hilo.cabecera.pasoActual, 1)
        XCTAssertEqual(hilo.cabecera.pasosTotales, 1)

        try await arnes.esperar(
            { arnes.estado.solicitudAprobacion != nil },
            mensaje: "La propuesta de memoria no llegó a la hoja"
        )
        // Dos pasos en el libro → 2/2.
        XCTAssertEqual(hilo.cabecera.pasoActual, 2)
        XCTAssertEqual(hilo.cabecera.pasosTotales, 2)

        arnes.estado.denegarSolicitud()
        try await arnes.esperarTarea(id: tarea.id, estado: .completada)

        XCTAssertEqual(hilo.cabecera.estado, .completada)
        XCTAssertEqual(hilo.cabecera.pasoActual, 2)
        XCTAssertEqual(
            hilo.cabecera.pasosTotales,
            2,
            "El cierre declara 2/2: el plan de 7 no es el denominador"
        )

        // El epílogo vivo (refrescarLibro) declara el abandono del plan.
        XCTAssertEqual(
            textoFinal(hilo),
            "Listo: no guardé nada porque lo denegaste.\n\n"
                + "Los pasos 3–7 del plan quedaron sin ejecutar: "
                + "la tarea se completó sin ellos."
        )

        // Reapertura: la proyección lee el libro y da el mismo 2/2.
        let enLibro = try XCTUnwrap(
            arnes.estado.tareas.first { $0.id == tarea.id }
        )
        XCTAssertEqual(enLibro.pasos.count, 2)
        XCTAssertEqual(enLibro.plan?.pasos.count, 7)
        let reabierto = HiloTareaViewModel()
        reabierto.reconstruir(
            con: enLibro,
            proyeccion: arnes.estado.elementosVisiblesDeTarea(enLibro)
        )
        XCTAssertEqual(reabierto.cabecera.estado, .completada)
        XCTAssertEqual(reabierto.cabecera.pasoActual, 2)
        XCTAssertEqual(
            reabierto.cabecera.pasosTotales,
            2,
            "Al reabrir el denominador no puede cambiar a 7"
        )

        // Y la tarjeta de plan sigue mostrando sus siete pasos.
        var pasosDeLaTarjeta: Int?
        for elemento in reabierto.elementos {
            if case .tarjetaPlan(let pasos, _, _) = elemento {
                pasosDeLaTarjeta = pasos.count
            }
        }
        XCTAssertEqual(
            pasosDeLaTarjeta,
            7,
            "La tarjeta de plan no se toca: muestra el plan completo"
        )
    }

    // MARK: - (i) M1: el hueco entre pasos no anticipa la fila siguiente

    /// Identificador de las tareas sintéticas de estos eventos.
    private let idDeEventos = UUID()

    private func evento(
        _ secuencia: Int,
        _ tipo: EventoTareaEjecucion.Tipo,
        paso: Int,
        total: Int,
        etiqueta: String = "",
        dinamico: String = "",
        estado: ElementoTareaVisible.EstadoPaso = .pendiente,
        duracion: TimeInterval? = nil,
        detalle: String = ""
    ) -> EventoTareaEjecucion {
        EventoTareaEjecucion(
            secuencia: secuencia,
            tareaID: idDeEventos,
            tipo: tipo,
            paso: paso,
            pasosTotales: total,
            etiqueta: etiqueta,
            estadoDinamico: dinamico,
            estado: estado,
            duracion: duracion,
            detalle: detalle
        )
    }

    /// Tras cerrar el paso 1 no hay fila 2 ni actividad que nombre un paso 2.
    ///
    /// §2.3 literal presupone una secuencia pre-conocida; en este motor el
    /// paso siguiente todavía no existe cuando K cierra. La actividad del
    /// hueco es texto plano, sin prefijo «Paso K/N».
    func testAlCerrarElPasoNoHayFilaSiguienteNiActividadQueLaNombre() {
        let hilo = HiloTareaViewModel()
        hilo.aplicar(
            evento(
                1, .turnoIniciado, paso: 1, total: 1,
                etiqueta: "Consultar el dominio",
                dinamico: "Consultando modelo…", estado: .enCurso
            )
        )
        hilo.aplicar(
            evento(
                2, .pasoIniciado, paso: 1, total: 1,
                etiqueta: "Leer enlace",
                dinamico: "Consultando ejemplo.test…", estado: .enCurso
            )
        )
        hilo.aplicar(
            evento(
                3, .pasoCerrado, paso: 1, total: 1,
                estado: .completado, duracion: 1.1
            )
        )

        XCTAssertNil(
            hilo.filas.first { $0.paso == 2 },
            "El cierre anticipó una fila que el modelo no propuso"
        )
        XCTAssertEqual(
            hilo.cabecera.pasoActual,
            1,
            "La cabecera se queda en el último paso real"
        )
        XCTAssertEqual(
            hilo.cabecera.actividad,
            "Esperando la respuesta del modelo…",
            "La actividad del hueco no es el texto plano"
        )
        XCTAssertFalse(
            hilo.cabecera.actividad.contains("Paso 2"),
            "La actividad del hueco nombra un paso que no existe"
        )
        XCTAssertFalse(
            hilo.traza.contains { $0.contains("Paso 2") },
            "La traza nombró el paso 2 antes de que existiera"
        )
    }

    /// La fila K+1 nace EN EL ACTO de su primer evento real.
    ///
    /// `aprobacionPendiente` la deja Esperando en la misma aplicación (nunca
    /// En curso: no se ejecutó) y `pasoIniciado` la deja En curso en la misma
    /// aplicación, sin esperar refresco ni ceder el actor.
    func testLaFilaSiguienteNaceEnLaMismaAplicacionDeSuPrimerEvento() {
        let hilo = HiloTareaViewModel()
        hilo.aplicar(
            evento(
                1, .turnoIniciado, paso: 1, total: 1,
                etiqueta: "Consultar el dominio",
                dinamico: "Consultando modelo…", estado: .enCurso
            )
        )
        hilo.aplicar(
            evento(
                2, .pasoIniciado, paso: 1, total: 1,
                etiqueta: "Leer enlace",
                dinamico: "Consultando ejemplo.test…", estado: .enCurso
            )
        )
        hilo.aplicar(
            evento(
                3, .pasoCerrado, paso: 1, total: 1,
                estado: .completado, duracion: 1.1
            )
        )

        hilo.aplicar(
            evento(
                4, .aprobacionPendiente, paso: 2, total: 2,
                etiqueta: "Guardar en Memoria",
                dinamico: "Esperando tu aprobación",
                estado: .esperandoAprobacion
            )
        )
        XCTAssertEqual(
            hilo.filas.first { $0.paso == 2 }?.estado,
            .esperandoAprobacion,
            "La fila 2 no nació Esperando en la misma aplicación"
        )
        XCTAssertEqual(hilo.cabecera.estado, .esperandoAprobacion)

        hilo.aplicar(
            evento(
                5, .pasoIniciado, paso: 2, total: 2,
                etiqueta: "Guardar en Memoria",
                dinamico: "Ejecutando la herramienta…", estado: .enCurso
            )
        )
        XCTAssertEqual(
            hilo.filas.first { $0.paso == 2 }?.estado,
            .enCurso,
            "La fila 2 no nació En curso en la misma aplicación"
        )
        XCTAssertEqual(hilo.cabecera.pasoActual, 2)
    }

    /// El cierre por denegación tampoco anticipa el paso siguiente.
    func testAlDenegarElPasoNoHayActividadQueNombreElPasoSiguiente() {
        let hilo = HiloTareaViewModel()
        hilo.aplicar(
            evento(
                1, .turnoIniciado, paso: 1, total: 1,
                etiqueta: "Consultar el dominio",
                dinamico: "Consultando modelo…", estado: .enCurso
            )
        )
        hilo.aplicar(
            evento(
                2, .pasoIniciado, paso: 1, total: 1,
                etiqueta: "Leer enlace",
                dinamico: "Consultando ejemplo.test…", estado: .enCurso
            )
        )
        hilo.aplicar(
            evento(
                3, .pasoCerrado, paso: 1, total: 1,
                estado: .completado, duracion: 1.1
            )
        )
        hilo.aplicar(
            evento(
                4, .aprobacionPendiente, paso: 2, total: 2,
                etiqueta: "Guardar en Memoria",
                dinamico: "Esperando tu aprobación",
                estado: .esperandoAprobacion
            )
        )
        hilo.aplicar(
            evento(
                5, .pasoCerrado, paso: 2, total: 2,
                estado: .denegado, detalle: "Denegada por ti"
            )
        )

        XCTAssertEqual(
            hilo.filas.first { $0.paso == 2 }?.estado,
            .denegado
        )
        XCTAssertNil(
            hilo.filas.first { $0.paso == 3 },
            "Tras denegar el paso 2 apareció una fila 3"
        )
        XCTAssertEqual(hilo.cabecera.pasoActual, 2)
        XCTAssertEqual(
            hilo.cabecera.actividad,
            "Esperando la respuesta del modelo…"
        )
        XCTAssertFalse(
            hilo.traza.contains { $0.contains("Paso 3") },
            "La traza nombró el paso 3 tras denegar el 2"
        )
    }

    // MARK: - (j) M1: la burbuja final declara el plan abandonado

    private func planDe(_ cuantos: Int) -> PlanTarea {
        var pasos: [PasoPlan] = []
        for orden in 1...cuantos {
            pasos.append(PasoPlan(orden: orden, texto: "Paso \(orden) del plan"))
        }
        return PlanTarea(
            pasos: pasos,
            texto: pasos.map { "\($0.orden). \($0.texto)" }
                .joined(separator: "\n")
        )
    }

    /// Tarea con libro de `cuantos` pasos resueltos y plan opcional.
    private func tareaConLibro(
        _ cuantos: Int,
        plan: Int?,
        estado: EstadoTarea = .completada,
        resultado: String? = "Respuesta final."
    ) -> Tarea {
        var libro: [Paso] = []
        if cuantos > 0 {
            for indice in 1...cuantos {
                libro.append(
                    Paso(
                        descripcion: "Paso \(indice) del libro",
                        estado: .terminado,
                        herramienta: "traer_url",
                        resultado: "ok",
                        llamadaID: "c\(indice)",
                        fechaInicio: Date(timeIntervalSince1970: Double(indice)),
                        fechaFin: Date(
                            timeIntervalSince1970: Double(indice) + 1
                        )
                    )
                )
            }
        }
        return Tarea(
            instruccion: "Encargo",
            estado: estado,
            pasos: libro,
            plan: plan.map { planDe($0) },
            resultado: resultado
        )
    }

    private func textoFinal(_ hilo: HiloTareaViewModel) -> String? {
        for elemento in hilo.elementos.reversed() {
            if case .resultadoFinal(let texto) = elemento { return texto }
        }
        return nil
    }

    private func hiloReconstruido(_ tarea: Tarea) throws -> HiloTareaViewModel {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let hilo = HiloTareaViewModel()
        hilo.reconstruir(
            con: tarea,
            proyeccion: arnes.estado.elementosVisiblesDeTarea(tarea)
        )
        return hilo
    }

    /// Caso B3-B: plan de 7, libro de 2 → declara «pasos 3–7».
    func testLaBurbujaFinalDeclaraElRangoDePasosDelPlanAbandonados() throws {
        let hilo = try hiloReconstruido(tareaConLibro(2, plan: 7))
        XCTAssertEqual(
            textoFinal(hilo),
            "Respuesta final.\n\n"
                + "Los pasos 3–7 del plan quedaron sin ejecutar: "
                + "la tarea se completó sin ellos."
        )
    }

    /// Un solo paso abandonado va en singular.
    func testLaBurbujaFinalUsaElSingularParaUnSoloPasoAbandonado() throws {
        let hilo = try hiloReconstruido(tareaConLibro(6, plan: 7))
        XCTAssertEqual(
            textoFinal(hilo),
            "Respuesta final.\n\n"
                + "El paso 7 del plan quedó sin ejecutar: "
                + "la tarea se completó sin él."
        )
    }

    /// Sin plan no hay nada que declarar.
    func testSinPlanLaBurbujaFinalNoDeclaraAbandono() throws {
        let hilo = try hiloReconstruido(tareaConLibro(2, plan: nil))
        XCTAssertEqual(textoFinal(hilo), "Respuesta final.")
    }

    /// Con el libro completo tampoco: el plan se ejecutó entero.
    func testConElLibroCompletoLaBurbujaFinalNoDeclaraAbandono() throws {
        let hilo = try hiloReconstruido(tareaConLibro(2, plan: 2))
        XCTAssertEqual(textoFinal(hilo), "Respuesta final.")
    }

    /// Una tarea detenida no declara abandono: no se completó.
    func testLaTareaDetenidaNoDeclaraAbandono() throws {
        let hilo = try hiloReconstruido(
            tareaConLibro(2, plan: 7, estado: .detenida)
        )
        XCTAssertEqual(textoFinal(hilo), "Respuesta final.")
    }

    // MARK: - (k) M2-unit: la condición de render de la tarjeta de aprobación

    /// Matriz de `solicitudAprobacionEnHilo`: la única condición de render.
    func testSolicitudAprobacionEnHiloSoloDevuelveLaDeSuFilaYSuTarea() async throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }
        let (tarea, hilo) = try await preparar(arnes)

        // Sin solicitud vigente: nil aunque la fila se pinte Esperando.
        XCTAssertNil(
            hilo.solicitudAprobacionEnHilo(paso: 2, estado: .esperandoAprobacion),
            "La tarjeta se rindió sin solicitud vigente"
        )

        // Solicitud de OTRA tarea: nil.
        let otra = arnes.estado.crearTarea(instruccion: "Otra tarea")
        arnes.estado.solicitudAprobacion = SolicitudAprobacion(
            tareaID: otra.id,
            herramienta: "traer_url",
            descripcion: "Leer un enlace"
        )
        XCTAssertNil(
            hilo.solicitudAprobacionEnHilo(paso: 2, estado: .esperandoAprobacion),
            "La tarjeta se rindió con la solicitud de otra tarea"
        )

        // Solicitud de ESTA tarea + fila Esperando: la devuelve.
        let propia = SolicitudAprobacion(
            tareaID: tarea.id,
            herramienta: "traer_url",
            descripcion: "Leer un enlace"
        )
        arnes.estado.solicitudAprobacion = propia
        XCTAssertEqual(
            hilo.solicitudAprobacionEnHilo(paso: 2, estado: .esperandoAprobacion),
            propia
        )

        // Fila En curso: nil. Fila Denegado con solicitud residual: nil.
        XCTAssertNil(hilo.solicitudAprobacionEnHilo(paso: 2, estado: .enCurso))
        XCTAssertNil(hilo.solicitudAprobacionEnHilo(paso: 2, estado: .denegado))

        arnes.estado.solicitudAprobacion = nil
    }
}
