import Combine
import Foundation

import NodoCore

/// Modelo de presentacion del hilo de Tarea (B3-A, paso bloqueante A.2).
///
/// POR QUE un ViewModel propio: la vista de Tarea de la v0.3.1 pintaba un
/// formulario y un panel que se refrescaban al cerrar el turno. El hilo
/// conversacional necesita una lista ORDENADA de elementos que se reconstruya
/// desde la tarea persistida y que ademas admita eventos en vivo de la Partida
/// B. Todo el estado mutable vive aqui, bajo `@MainActor`: las mutaciones se
/// serializan en el hilo principal y en el orden en que el motor las emite
/// (§0.1 de la spec), de modo que la traza es total y reproducible.
///
/// Catalogo: `UI_INVARIANTS.md` declara CERRADO el enum `ElementoTareaVisible`
/// (cabecera, tarjeta de plan y fila de paso). El hilo necesita ademas la
/// burbuja del usuario, el error en linea y el resultado final; esos tres no
/// tienen caso en el enum cerrado y NO se anaden aqui a la fuerza. Este tipo
/// los modela en la capa de presentacion y los serializa a las etiquetas YA
/// validas del catalogo de traza (`UserBubble`, `ErrorBubble`,
/// `AssistantBubble`). La enmienda del catalogo la dictamina el lead; esta
/// sesion no la declara resuelta.
@MainActor
final class HiloTareaViewModel: ObservableObject {
    /// Accion que ofrece la tarjeta de plan en el hilo.
    enum AccionPlan: String, Equatable {
        case empezar
        case ajustar
    }

    /// Un elemento visible del hilo, en orden.
    enum Elemento: Equatable {
        case burbujaUsuario(texto: String)
        case tarjetaPlan(
            pasos: [PasoPlan],
            version: Int,
            acciones: [AccionPlan]
        )
        case filaPaso(
            paso: Int,
            estado: ElementoTareaVisible.EstadoPaso,
            etiquetaDinamica: String,
            duracion: TimeInterval?,
            costo: Decimal?
        )
        case errorEnLinea(texto: String)
        case resultadoFinal(texto: String)
    }

    /// Evento de ejecucion que la Partida B empujara a esta misma cola.
    ///
    /// A los aplica para probar la serializacion (R17): el orden de la traza
    /// debe ser el de emision aunque las tareas que los entregan se adelanten.
    enum Evento: Equatable {
        case deltaSSE(texto: String)
        case paso(indice: Int, estado: ElementoTareaVisible.EstadoPaso)
        case herramienta(paso: Int, etiqueta: String)
        case costoSellado(Decimal)
        case aprobacion(pendiente: Bool)
    }

    /// Cabecera fija: estado, paso y costo sellado de ESTA tarea.
    struct Cabecera: Equatable {
        var estado: ElementoTareaVisible.EstadoTarea
        var pasoActual: Int
        var pasosTotales: Int
        var costoSellado: Decimal
    }

    /// Estado final del ViewModel tras aplicar eventos, para comparar la
    /// corrida intercalada con la secuencial (R17).
    struct EstadoFinal: Equatable {
        var textoEnCurso: String
        var filas: [Int: ElementoTareaVisible.EstadoPaso]
        var costoSellado: Decimal
        var estado: ElementoTareaVisible.EstadoTarea
    }

    @Published private(set) var elementos: [Elemento] = []
    @Published private(set) var cabecera = Cabecera(
        estado: .nuevaTarea,
        pasoActual: 0,
        pasosTotales: 0,
        costoSellado: 0
    )
    /// Lineas de traza ya emitidas, en orden de aparicion.
    @Published private(set) var traza: [String] = []
    /// Colapso de la cabecera: lo decide el dueno y nunca la oculta del todo.
    @Published var colapsada = false

    private var inicioTraza = Date()
    private var elementosAnteriores: [Elemento] = []
    private var cabeceraAnterior: Cabecera?

    // Cola serializada de eventos (R17).
    private var pendientes: [Int: Evento] = [:]
    private var siguienteSecuencia = 1
    private var textoEnCurso = ""
    private var filasEventos: [Int: ElementoTareaVisible.EstadoPaso] = [:]
    private var costoEventos: Decimal = 0
    private var estadoEventos: ElementoTareaVisible.EstadoTarea = .nuevaTarea

    // MARK: - Reconstruccion desde la tarea persistida

    /// Reconstruye el hilo desde la tarea y su proyeccion visible.
    ///
    /// El orden es fijo y no depende de fechas ni de diccionarios:
    /// turnos de planificacion -> tarjeta de plan vigente -> filas del libro ->
    /// error en linea -> resultado final -> turnos posteriores a la ejecucion.
    /// Rehidratar la tarea produce exactamente la misma lista.
    func reconstruir(
        con tarea: Tarea,
        proyeccion: [ElementoTareaVisible]
    ) {
        var nuevaCabecera = cabecera
        var plan: (pasos: [PasoPlan], version: Int)?
        var filas: [ElementoTareaVisible] = []

        for elemento in proyeccion {
            switch elemento {
            case .cabeceraTarea(
                let estado,
                let pasoActual,
                let pasosTotales,
                let costoSellado
            ):
                nuevaCabecera = Cabecera(
                    estado: estado,
                    pasoActual: pasoActual,
                    pasosTotales: pasosTotales,
                    costoSellado: costoSellado
                )
            case .tarjetaPlan(let pasos, let version):
                plan = (pasos, version)
            case .filaPaso:
                filas.append(elemento)
            }
        }

        var nuevos: [Elemento] = []
        let dePlanificacion = tarea.turnos.filter { !$0.despuesDeEjecutar }
        let posteriores = tarea.turnos.filter { $0.despuesDeEjecutar }

        for turno in dePlanificacion where turno.rol == .usuario {
            nuevos.append(.burbujaUsuario(texto: turno.texto))
        }

        if let plan {
            let acciones: [AccionPlan] = tarea.admiteEdicion
                ? [.empezar, .ajustar]
                : []
            nuevos.append(
                .tarjetaPlan(
                    pasos: plan.pasos,
                    version: plan.version,
                    acciones: acciones
                )
            )
        }

        for elemento in filas {
            guard case .filaPaso(
                let paso,
                let estado,
                let etiqueta,
                let duracion,
                let costo
            ) = elemento else { continue }
            // El paso sintetico «Error: …» que el motor anade al fallar una
            // tarea no se pinta como fila: el error va como elemento en linea
            // en el punto exacto donde ocurrio (E7).
            if esPasoDeErrorDeTarea(paso: paso, en: tarea) {
                continue
            }
            nuevos.append(
                .filaPaso(
                    paso: paso,
                    estado: estado,
                    etiquetaDinamica: etiqueta,
                    duracion: duracion,
                    costo: costo
                )
            )
        }

        if let error = tarea.ultimoError,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nuevos.append(.errorEnLinea(texto: error))
        }

        if let resultado = tarea.resultado,
           !resultado.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nuevos.append(.resultadoFinal(texto: resultado))
        }

        for turno in posteriores where turno.rol == .usuario {
            nuevos.append(.burbujaUsuario(texto: turno.texto))
        }

        emitirTraza(cabecera: nuevaCabecera, elementos: nuevos)
        cabecera = nuevaCabecera
        cabeceraAnterior = nuevaCabecera
        elementosAnteriores = nuevos
        elementos = nuevos
    }

    /// El unico paso con descripcion «Error: …» y sin herramienta es el que
    /// `finalizarTareaConError` anade para cerrar la tarea. Se omite como fila
    /// porque su texto ya se pinta como `ErrorBubble`.
    private func esPasoDeErrorDeTarea(paso: Int, en tarea: Tarea) -> Bool {
        guard paso >= 1, paso <= tarea.pasos.count else { return false }
        let delLibro = tarea.pasos[paso - 1]
        return delLibro.herramienta == nil
            && delLibro.estado == .fallido
            && delLibro.descripcion.hasPrefix("Error: ")
    }

    // MARK: - Eventos serializados (R17)

    /// Aplica un evento con numero de emision.
    ///
    /// Los eventos pueden llegar adelantados (dos tareas compitiendo); se
    /// retienen hasta que su predecesor se aplica. El resultado es el mismo
    /// que el de la corrida secuencial y la traza respeta el orden de emision.
    func aplicar(_ evento: Evento, secuencia: Int) {
        pendientes[secuencia] = evento
        while let siguiente = pendientes[siguienteSecuencia] {
            pendientes.removeValue(forKey: siguienteSecuencia)
            aplicarEnOrden(siguiente, secuencia: siguienteSecuencia)
            siguienteSecuencia += 1
        }
    }

    /// Estado final del ViewModel, para la comparacion secuencial/intercalada.
    var estadoFinal: EstadoFinal {
        EstadoFinal(
            textoEnCurso: textoEnCurso,
            filas: filasEventos,
            costoSellado: costoEventos,
            estado: estadoEventos
        )
    }

    private func aplicarEnOrden(_ evento: Evento, secuencia: Int) {
        // Tiempo determinista por numero de emision: dos corridas con los
        // mismos eventos producen exactamente las mismas lineas.
        let t = String(format: "%.2f", Double(secuencia) / 100.0)
        switch evento {
        case .deltaSSE(let texto):
            textoEnCurso += texto
            traza.append(
                "[t=\(t)s] StreamingBubble(\"\(Self.escapar(textoEnCurso))\")"
            )

        case .paso(let indice, let estado):
            filasEventos[indice] = estado
            traza.append(
                "[t=\(t)s] StepRow(paso: \(indice), estado: "
                    + "\"\(estado.titulo)\", etiqueta: \"Paso \(indice)\", "
                    + "duracion: nil, costo: nil)"
            )

        case .herramienta(let paso, let etiqueta):
            filasEventos[paso] = .enCurso
            traza.append(
                "[t=\(t)s] StepRow(paso: \(paso), estado: \"En curso\", "
                    + "etiqueta: \"\(Self.escapar(etiqueta))\", "
                    + "duracion: nil, costo: nil)"
            )

        case .costoSellado(let costo):
            costoEventos = costo
            estadoEventos = .enCurso
            traza.append(
                Self.lineaCabecera(
                    Cabecera(
                        estado: .enCurso,
                        pasoActual: cabecera.pasoActual,
                        pasosTotales: cabecera.pasosTotales,
                        costoSellado: costo
                    ),
                    t: t
                )
            )

        case .aprobacion(let pendiente):
            estadoEventos = pendiente ? .esperandoAprobacion : .enCurso
            traza.append(
                Self.lineaCabecera(
                    Cabecera(
                        estado: estadoEventos,
                        pasoActual: cabecera.pasoActual,
                        pasosTotales: cabecera.pasosTotales,
                        costoSellado: costoEventos
                    ),
                    t: t
                )
            )
        }
    }

    // MARK: - Traza

    /// Emite solo lo nuevo o cambiado, como `SesionTraza` en el hilo del Chat.
    private func emitirTraza(cabecera nueva: Cabecera, elementos: [Elemento]) {
        let t = Self.tiempo(Date(), desde: inicioTraza)
        if cabeceraAnterior != nueva {
            traza.append(Self.lineaCabecera(nueva, t: t))
        }
        for (indice, elemento) in elementos.enumerated() {
            if indice >= elementosAnteriores.count
                || elementosAnteriores[indice] != elemento {
                traza.append(Self.linea(elemento, t: t))
            }
        }
    }

    /// Vuelca la traza completa a texto plano.
    var trazaTexto: String {
        traza.isEmpty ? "" : traza.joined(separator: "\n") + "\n"
    }

    private static func lineaCabecera(_ cabecera: Cabecera, t: String) -> String {
        "[t=\(t)s] TaskHeader(estado: "
            + "\"\(escapar(cabecera.estado.titulo))\", "
            + "pasoActual: \(cabecera.pasoActual), "
            + "pasosTotales: \(cabecera.pasosTotales), "
            + "costoSellado: \"\(decimal(cabecera.costoSellado))\")"
    }

    private static func linea(_ elemento: Elemento, t: String) -> String {
        switch elemento {
        case .burbujaUsuario(let texto):
            return "[t=\(t)s] UserBubble(\"\(escapar(texto))\")"

        case .tarjetaPlan(let pasos, let version, let acciones):
            let textos = pasos
                .map { "\"\(escapar($0.texto))\"" }
                .joined(separator: ", ")
            let accionesTexto = acciones.map(\.rawValue).joined(separator: ", ")
            return "[t=\(t)s] PlanCard(pasos: [\(textos)], "
                + "version: \(version), acciones: [\(accionesTexto)])"

        case .filaPaso(
            let paso,
            let estado,
            let etiqueta,
            let duracion,
            let costo
        ):
            let duracionTexto = duracion.map {
                String(
                    format: "%.1f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    $0
                )
            } ?? "nil"
            let costoTexto = costo.map { "\"\(decimal($0))\"" } ?? "nil"
            return "[t=\(t)s] StepRow(paso: \(paso), "
                + "estado: \"\(escapar(estado.titulo))\", "
                + "etiqueta: \"\(escapar(etiqueta))\", "
                + "duracion: \(duracionTexto), costo: \(costoTexto))"

        case .errorEnLinea(let texto):
            return "[t=\(t)s] ErrorBubble(\"\(escapar(texto))\")"

        case .resultadoFinal(let texto):
            return "[t=\(t)s] AssistantBubble(\"\(escapar(texto))\")"
        }
    }

    private static func tiempo(_ fecha: Date, desde inicio: Date) -> String {
        let segundos = max(0, fecha.timeIntervalSince(inicio))
        return String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            segundos
        )
    }

    private static func decimal(_ valor: Decimal) -> String {
        String(describing: valor)
    }

    /// Escapa una cadena para que la traza siga siendo una linea por elemento.
    static func escapar(_ valor: String) -> String {
        var salida = ""
        salida.reserveCapacity(valor.count)
        for caracter in valor {
            switch caracter {
            case "\\": salida += "\\\\"
            case "\"": salida += "\\\""
            case "\n": salida += "\\n"
            case "\r": salida += "\\r"
            case "\t": salida += "\\t"
            default: salida.append(caracter)
            }
        }
        return salida
    }
}
