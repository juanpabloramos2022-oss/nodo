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
    /// debe ser el de emision aunque las tareas que los entreguen se adelanten.
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
        /// Actividad visible del paso en curso (B3-B).
        ///
        /// Siempre nombra el paso real («Paso 2/3 · Consultando modelo…»); es
        /// la renovacion de actividad del latido y por eso entra en la traza
        /// como parte de `TaskHeader`. Vacia fuera de ejecucion.
        var actividad: String = ""
    }

    /// Fila viva del hilo (B3-B): el libro manda en estado, duracion y costo;
    /// el evento aporta el estado dinamico y el detalle humano.
    struct FilaViva: Equatable {
        var paso: Int
        var nombre: String
        var estado: ElementoTareaVisible.EstadoPaso
        var estadoDinamico: String
        var duracion: TimeInterval?
        var costo: Decimal?
        var detalle: String
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
    /// Filas vivas en orden de paso (B3-B). La vista pinta `elementos`; esto
    /// queda publicado para que los tests afirmen sobre las transiciones.
    @Published private(set) var filas: [FilaViva] = []
    /// Marca del toque en [Empezar]: el `t=0` de la traza.
    @Published private(set) var toqueEmpezar: Date?
    /// Instante de la primera senal activa con paso y estado dinamico reales.
    @Published private(set) var primeraSenal: Date?

    private var inicioTraza = Date()
    private var elementosAnteriores: [Elemento] = []
    private var cabeceraAnterior: Cabecera?

    // Cola serializada de eventos (R17) — superficie de B3-A, intacta.
    private var pendientes: [Int: Evento] = [:]
    private var siguienteSecuencia = 1
    private var textoEnCurso = ""
    private var filasEventos: [Int: ElementoTareaVisible.EstadoPaso] = [:]
    private var costoEventos: Decimal = 0
    private var estadoEventos: ElementoTareaVisible.EstadoTarea = .nuevaTarea

    // Tuberia viva de B3-B (B.1).
    private weak var estadoObservado: EstadoApp?
    private var tareaObservada: UUID?
    private var observador: UUID?
    private var pendientesVivos: [Int: EventoTareaEjecucion] = [:]
    private var siguienteSecuenciaViva = 1
    private var ejecucionViva = false
    private var textosDelPlan: [String] = []
    private var filasVivas: [Int: FilaViva] = [:]
    private var preludio: [Elemento] = []
    private var filasBase: [FilaViva] = []
    private var epilogo: [Elemento] = []
    private var aprobacionPendiente: Int?
    private var latido: Task<Void, Never>?
    private var inicioEspera: Date?
    private var detalleEspera = ""
    private var pasoEnEspera = 1
    private var pasoActividad = 1
    private var termino = false
    private let reloj: () -> Date

    init(reloj: @escaping () -> Date = { Date() }) {
        self.reloj = reloj
    }

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
        var deProyeccion = cabecera
        var plan: (pasos: [PasoPlan], version: Int)?
        var filasProyectadas: [ElementoTareaVisible] = []

        for elemento in proyeccion {
            switch elemento {
            case .cabeceraTarea(
                let estado,
                let pasoActual,
                let pasosTotales,
                let costoSellado
            ):
                deProyeccion = Cabecera(
                    estado: estado,
                    pasoActual: pasoActual,
                    pasosTotales: pasosTotales,
                    costoSellado: costoSellado
                )
            case .tarjetaPlan(let pasos, let version):
                plan = (pasos, version)
            case .filaPaso:
                filasProyectadas.append(elemento)
            }
        }

        var nuevoPreludio: [Elemento] = []
        let dePlanificacion = tarea.turnos.filter { !$0.despuesDeEjecutar }
        let posteriores = tarea.turnos.filter { $0.despuesDeEjecutar }

        for turno in dePlanificacion where turno.rol == .usuario {
            nuevoPreludio.append(.burbujaUsuario(texto: turno.texto))
        }

        if let plan {
            let acciones: [AccionPlan] = tarea.admiteEdicion
                ? [.empezar, .ajustar]
                : []
            nuevoPreludio.append(
                .tarjetaPlan(
                    pasos: plan.pasos,
                    version: plan.version,
                    acciones: acciones
                )
            )
            textosDelPlan = plan.pasos
                .sorted { $0.orden < $1.orden }
                .map(\.texto)
        } else {
            textosDelPlan = []
        }

        var nuevasFilasBase: [FilaViva] = []
        for elemento in filasProyectadas {
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
            nuevasFilasBase.append(
                FilaViva(
                    paso: paso,
                    nombre: nombreDelPaso(paso, porDefecto: etiqueta),
                    estado: estado,
                    estadoDinamico: "",
                    duracion: duracion,
                    costo: costo,
                    detalle: ""
                )
            )
        }

        var nuevoEpilogo: [Elemento] = []
        if let error = tarea.ultimoError,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nuevoEpilogo.append(.errorEnLinea(texto: error))
        }

        if let resultado = tarea.resultado,
           !resultado.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nuevoEpilogo.append(.resultadoFinal(texto: resultado))
        }

        for turno in posteriores where turno.rol == .usuario {
            nuevoEpilogo.append(.burbujaUsuario(texto: turno.texto))
        }

        preludio = nuevoPreludio
        filasBase = nuevasFilasBase
        epilogo = nuevoEpilogo

        // Una ejecucion viva manda en la cabecera: la rehidratacion no puede
        // devolver el hilo al estado de disco mientras el motor escribe.
        if !ejecucionViva {
            cabecera = deProyeccion
            cabeceraAnterior = deProyeccion
        } else if deProyeccion.pasosTotales > cabecera.pasosTotales {
            cabecera.pasosTotales = deProyeccion.pasosTotales
        }

        recomponer(ahora: reloj())
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

    // MARK: - Tuberia viva (B3-B, B.1)

    /// Conecta el hilo a la fuente de eventos de ejecucion de una tarea.
    ///
    /// La conexion es una suscripcion sincrona bajo `@MainActor`: cada evento
    /// se aplica en el orden en que el motor lo emitio, sin colas de fondo ni
    /// hilos de presentacion propios (§0.1).
    func conectar(a estado: EstadoApp, tareaID: UUID) {
        if tareaObservada == tareaID, estadoObservado === estado {
            return
        }
        desconectar()
        estadoObservado = estado
        tareaObservada = tareaID
        // La cola arranca donde va el emisor: un hilo que se abre a mitad de
        // una ejecucion no espera eventos que ya pasaron.
        siguienteSecuenciaViva = estado.secuenciaEventoTareaActual + 1
        observador = estado.observarEventosDeTarea { [weak self] evento in
            guard let self, evento.tareaID == tareaID else { return }
            self.aplicar(evento)
        }
        if let tarea = estado.tareas.first(where: { $0.id == tareaID }) {
            reconstruir(
                con: tarea,
                proyeccion: estado.elementosVisiblesDeTarea(tarea)
            )
        }
    }

    func desconectar() {
        if let observador, let estado = estadoObservado {
            estado.dejarDeObservarEventosDeTarea(observador)
        }
        observador = nil
        detenerLatido()
    }

    /// Relee la tarea observada y recompone el hilo.
    ///
    /// Es la ruta de rehidratacion (abrir la tarea, volver de segundo plano o
    /// cambiar el plan); las transiciones de ejecucion llegan por eventos.
    func sincronizarDesdeEstado() {
        guard let estado = estadoObservado,
              let tareaID = tareaObservada,
              let tarea = estado.tareas.first(where: { $0.id == tareaID })
        else { return }
        reconstruir(
            con: tarea,
            proyeccion: estado.elementosVisiblesDeTarea(tarea)
        )
    }

    /// Marca el toque en [Empezar]. Se llama INMEDIATAMENTE antes de la accion
    /// de la vista: es el `t=0` contra el que se mide la primera senal.
    func marcarToqueEmpezar(en fecha: Date? = nil) {
        let instante = fecha ?? reloj()
        toqueEmpezar = instante
        primeraSenal = nil
        inicioTraza = instante
        traza = []
        elementosAnteriores = []
        cabeceraAnterior = nil
        ejecucionViva = true
        termino = false
        aprobacionPendiente = nil
    }

    /// Aplica un evento de ejecucion respetando el orden de emision.
    ///
    /// Los eventos pueden llegar adelantados; se retienen hasta que su
    /// predecesor se aplica. En produccion llegan ya en orden, pero la cola es
    /// la garantia de §0.1 y el caso R17 la ejerce a proposito.
    func aplicar(_ evento: EventoTareaEjecucion) {
        pendientesVivos[evento.secuencia] = evento
        while let siguiente = pendientesVivos[siguienteSecuenciaViva] {
            pendientesVivos.removeValue(forKey: siguienteSecuenciaViva)
            aplicarEnOrdenVivo(siguiente)
            siguienteSecuenciaViva += 1
        }
    }

    private func aplicarEnOrdenVivo(_ evento: EventoTareaEjecucion) {
        // Una aprobacion pendiente congela el hilo: ningun evento de un paso
        // posterior avanza hasta que el dueno decida (§2.2).
        if let pendiente = aprobacionPendiente, evento.paso > pendiente,
           evento.tipo != .detenido,
           evento.tipo != .error,
           evento.tipo != .finalizada {
            return
        }

        switch evento.tipo {
        case .turnoIniciado:
            fijarFila(evento)
            actualizarCabecera(
                estado: .enCurso,
                evento: evento,
                actividad: Self.actividad(
                    paso: evento.paso,
                    total: evento.pasosTotales,
                    texto: evento.estadoDinamico
                )
            )
            marcarPrimeraSenal(evento)
            iniciarLatido(
                paso: evento.paso,
                pasoActividad: evento.paso,
                detalle: evento.estadoDinamico,
                en: evento.fecha
            )

        case .pasoIniciado:
            fijarFila(evento)
            actualizarCabecera(
                estado: .enCurso,
                evento: evento,
                actividad: Self.actividad(
                    paso: evento.paso,
                    total: evento.pasosTotales,
                    texto: evento.estadoDinamico
                )
            )
            marcarPrimeraSenal(evento)
            iniciarLatido(
                paso: evento.paso,
                pasoActividad: evento.paso,
                detalle: evento.estadoDinamico,
                en: evento.fecha
            )

        case .actividad:
            fijarFila(evento)
            actualizarCabecera(
                estado: .enCurso,
                evento: evento,
                actividad: Self.actividad(
                    paso: evento.paso,
                    total: evento.pasosTotales,
                    texto: evento.estadoDinamico
                )
            )

        case .pasoCerrado:
            // Ninguna fila cae de golpe a Completado: si el cierre llega sin
            // su En curso previo, se emite primero esa transicion visible.
            // Solo una fila PENDIENTE necesita su transicion previa: una fila
            // que venia de «Esperando tu aprobacion» pasa directo a su
            // desenlace (Denegado), porque nunca llego a ejecutarse.
            let previa = filasVivas[evento.paso]
            if previa == nil || previa?.estado == .pendiente {
                var transicion = previa ?? FilaViva(
                    paso: evento.paso,
                    nombre: nombreDelPaso(
                        evento.paso,
                        porDefecto: evento.etiqueta
                    ),
                    estado: .enCurso,
                    estadoDinamico: "",
                    duracion: nil,
                    costo: nil,
                    detalle: ""
                )
                transicion.estado = .enCurso
                filasVivas[evento.paso] = transicion
                recomponer(ahora: evento.fecha)
            }
            // La decision ya se tomo: el hilo deja de estar congelado.
            if aprobacionPendiente == evento.paso {
                aprobacionPendiente = nil
            }
            fijarFila(evento)
            actualizarCabecera(
                estado: evento.estado == .denegado
                    ? .enCurso
                    : (evento.estado == .error ? .error : .enCurso),
                evento: evento,
                actividad: Self.actividad(
                    paso: min(evento.paso + 1, max(evento.pasosTotales, 1)),
                    total: evento.pasosTotales,
                    texto: "Esperando la respuesta del modelo…"
                )
            )
            // El motor vuelve al modelo para el paso siguiente: la espera real
            // sigue y el latido no se corta entre pasos.
            iniciarLatido(
                paso: evento.paso,
                pasoActividad: min(
                    evento.paso + 1,
                    max(evento.pasosTotales, 1)
                ),
                detalle: "Esperando la respuesta del modelo…",
                en: evento.fecha
            )

        case .costoSellado:
            actualizarCabecera(
                estado: cabecera.estado,
                evento: evento,
                actividad: cabecera.actividad
            )

        case .aprobacionPendiente:
            aprobacionPendiente = evento.paso
            fijarFila(evento)
            actualizarCabecera(
                estado: .esperandoAprobacion,
                evento: evento,
                actividad: Self.actividad(
                    paso: evento.paso,
                    total: evento.pasosTotales,
                    texto: "Esperando tu aprobación"
                )
            )
            detenerLatido()

        case .detenido:
            termino = true
            detenerLatido()
            aprobacionPendiente = nil
            var fila = filasVivas[evento.paso] ?? FilaViva(
                paso: evento.paso,
                nombre: nombreDelPaso(
                    evento.paso,
                    porDefecto: evento.etiqueta
                ),
                estado: .detenido,
                estadoDinamico: "",
                duracion: nil,
                costo: nil,
                detalle: "Detenida por ti"
            )
            fila.estado = .detenido
            fila.estadoDinamico = ""
            fila.detalle = "Detenida por ti"
            filasVivas[evento.paso] = fila
            actualizarCabecera(
                estado: .detenida,
                evento: evento,
                actividad: ""
            )

        case .finalizada:
            termino = true
            detenerLatido()
            aprobacionPendiente = nil
            actualizarCabecera(
                estado: .completada,
                evento: evento,
                actividad: ""
            )

        case .error:
            termino = true
            detenerLatido()
            aprobacionPendiente = nil
            fijarFila(evento)
            actualizarCabecera(
                estado: .error,
                evento: evento,
                actividad: ""
            )
        }

        refrescarLibro(ahora: evento.fecha)
        recomponer(ahora: evento.fecha)
    }

    /// Relee el libro persistido sin tocar la cabecera viva.
    ///
    /// El evento se emite DESPUES de escribir el paso, asi que esta lectura ve
    /// ya el estado nuevo: la fila que pinta el hilo y el libro no divergen.
    private func refrescarLibro(ahora: Date) {
        guard let estado = estadoObservado,
              let tareaID = tareaObservada,
              let tarea = estado.tareas.first(where: { $0.id == tareaID })
        else { return }

        var nuevasBase: [FilaViva] = []
        for elemento in estado.elementosVisiblesDeTarea(tarea) {
            guard case .filaPaso(
                let paso,
                let estadoPaso,
                let etiqueta,
                let duracion,
                let costo
            ) = elemento else { continue }
            if esPasoDeErrorDeTarea(paso: paso, en: tarea) { continue }
            nuevasBase.append(
                FilaViva(
                    paso: paso,
                    nombre: nombreDelPaso(paso, porDefecto: etiqueta),
                    estado: estadoPaso,
                    estadoDinamico: "",
                    duracion: duracion,
                    costo: costo,
                    detalle: ""
                )
            )
        }
        filasBase = nuevasBase

        var nuevoEpilogo: [Elemento] = []
        if let error = tarea.ultimoError,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nuevoEpilogo.append(.errorEnLinea(texto: error))
        }
        if let resultado = tarea.resultado,
           !resultado.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nuevoEpilogo.append(.resultadoFinal(texto: resultado))
        }
        for turno in tarea.turnos where turno.despuesDeEjecutar
            && turno.rol == .usuario {
            nuevoEpilogo.append(.burbujaUsuario(texto: turno.texto))
        }
        epilogo = nuevoEpilogo
    }

    private func fijarFila(_ evento: EventoTareaEjecucion) {
        var fila = filasVivas[evento.paso] ?? FilaViva(
            paso: evento.paso,
            nombre: nombreDelPaso(evento.paso, porDefecto: evento.etiqueta),
            estado: .pendiente,
            estadoDinamico: "",
            duracion: nil,
            costo: nil,
            detalle: ""
        )
        fila.estado = evento.estado
        if !evento.etiqueta.isEmpty {
            fila.nombre = nombreDelPaso(
                evento.paso,
                porDefecto: evento.etiqueta
            )
        }
        fila.estadoDinamico = evento.estadoDinamico
        if let duracion = evento.duracion { fila.duracion = duracion }
        if let costo = evento.costo { fila.costo = costo }
        if !evento.detalle.isEmpty { fila.detalle = evento.detalle }
        filasVivas[evento.paso] = fila
    }

    private func actualizarCabecera(
        estado: ElementoTareaVisible.EstadoTarea,
        evento: EventoTareaEjecucion,
        actividad: String
    ) {
        var nueva = cabecera
        nueva.estado = estado
        if evento.paso > 0 { nueva.pasoActual = evento.paso }
        if evento.pasosTotales > 0 {
            nueva.pasosTotales = max(nueva.pasosTotales, evento.pasosTotales)
        }
        if let costo = evento.costoSelladoTarea {
            nueva.costoSellado = costo
        }
        nueva.actividad = actividad
        cabecera = nueva
    }

    private func marcarPrimeraSenal(_ evento: EventoTareaEjecucion) {
        guard primeraSenal == nil,
              evento.estado == .enCurso,
              !evento.estadoDinamico.isEmpty
        else { return }
        primeraSenal = evento.fecha
    }

    /// Rotulo del paso en curso: siempre nombra el paso real y su actividad.
    private static func actividad(
        paso: Int,
        total: Int,
        texto: String
    ) -> String {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return "" }
        guard total > 0 else { return limpio }
        return "Paso \(paso)/\(total) · \(limpio)"
    }

    /// Nombre visible del paso: el texto del plan si existe, o el rotulo
    /// humano del libro. Nunca el nombre tecnico de una herramienta.
    private func nombreDelPaso(_ paso: Int, porDefecto: String) -> String {
        if paso >= 1, paso <= textosDelPlan.count {
            let texto = textosDelPlan[paso - 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !texto.isEmpty {
                if texto.count <= 72 { return texto }
                return String(texto.prefix(72)) + "…"
            }
        }
        return porDefecto
    }

    // MARK: - Latido (B.2)

    /// Renueva la actividad visible mientras el motor espera red o modelo.
    ///
    /// El latido es una tarea bajo `@MainActor` que se cancela al cerrar la
    /// ejecucion, al detener o al entrar en aprobacion. Cada tick actualiza el
    /// estado dinamico con el tiempo de espera real: ningun tramo de espera
    /// queda sin actividad visible mas de 1,5 s.
    private func iniciarLatido(
        paso: Int,
        pasoActividad: Int,
        detalle: String,
        en fecha: Date
    ) {
        pasoEnEspera = paso
        self.pasoActividad = pasoActividad
        detalleEspera = detalle
        inicioEspera = fecha
        guard latido == nil else { return }
        latido = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.latir()
            }
        }
    }

    private func detenerLatido() {
        latido?.cancel()
        latido = nil
        inicioEspera = nil
    }

    private func latir() {
        guard !termino, aprobacionPendiente == nil, let inicio = inicioEspera
        else {
            detenerLatido()
            return
        }
        let ahora = reloj()
        let espera = max(0, ahora.timeIntervalSince(inicio))
        let texto = String(
            format: "%@ (%.1f s)",
            locale: Locale(identifier: "en_US_POSIX"),
            detalleEspera,
            espera
        )

        if var fila = filasVivas[pasoEnEspera], fila.estado == .enCurso {
            fila.estadoDinamico = texto
            filasVivas[pasoEnEspera] = fila
        }
        cabecera.actividad = Self.actividad(
            paso: pasoActividad,
            total: cabecera.pasosTotales,
            texto: texto
        )
        recomponer(ahora: ahora)
    }

    // MARK: - Composicion del hilo

    /// Une las filas del libro con las filas vivas y emite lo que cambio.
    private func recomponer(ahora: Date) {
        let ordenadas = filasCombinadas()
        var nuevos = preludio
        for fila in ordenadas {
            nuevos.append(
                .filaPaso(
                    paso: fila.paso,
                    estado: fila.estado,
                    etiquetaDinamica: etiquetaVisible(fila),
                    duracion: fila.duracion,
                    costo: fila.costo
                )
            )
        }
        nuevos.append(contentsOf: epilogo)

        emitirTraza(cabecera: cabecera, elementos: nuevos, ahora: ahora)
        elementosAnteriores = nuevos
        cabeceraAnterior = cabecera
        elementos = nuevos
        filas = ordenadas
    }

    private func filasCombinadas() -> [FilaViva] {
        var porPaso: [Int: FilaViva] = [:]
        for fila in filasBase { porPaso[fila.paso] = fila }

        for (paso, viva) in filasVivas {
            guard var base = porPaso[paso] else {
                porPaso[paso] = viva
                continue
            }
            if !viva.estadoDinamico.isEmpty {
                base.estadoDinamico = viva.estadoDinamico
            }
            if !viva.detalle.isEmpty { base.detalle = viva.detalle }
            if viva.estado == .denegado || viva.estado == .detenido
                || viva.estado == .error {
                base.estado = viva.estado
            }
            if base.duracion == nil { base.duracion = viva.duracion }
            if base.costo == nil { base.costo = viva.costo }
            porPaso[paso] = base
        }

        return porPaso.keys.sorted().compactMap { porPaso[$0] }
    }

    /// Texto de la fila: nombre real del paso y, si hay, su estado dinamico.
    private func etiquetaVisible(_ fila: FilaViva) -> String {
        if !fila.detalle.isEmpty {
            return "\(fila.nombre) · \(fila.detalle)"
        }
        if !fila.estadoDinamico.isEmpty {
            return "\(fila.nombre) · \(fila.estadoDinamico)"
        }
        return fila.nombre
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

    /// Numero de secuencia que la cola viva espera a continuacion.
    ///
    /// Lo usan las pruebas de contrato que inyectan un evento con el numero
    /// que el emisor habria usado, sin saltarse la cola.
    var secuenciaVivaEsperada: Int { siguienteSecuenciaViva }

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
    private func emitirTraza(
        cabecera nueva: Cabecera,
        elementos: [Elemento],
        ahora: Date
    ) {
        let t = Self.tiempo(ahora, desde: inicioTraza)
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
        let base = "[t=\(t)s] TaskHeader(estado: "
            + "\"\(escapar(cabecera.estado.titulo))\", "
            + "pasoActual: \(cabecera.pasoActual), "
            + "pasosTotales: \(cabecera.pasosTotales), "
            + "costoSellado: \"\(decimal(cabecera.costoSellado))\""
        guard !cabecera.actividad.isEmpty else { return base + ")" }
        return base + ", actividad: \"\(escapar(cabecera.actividad))\")"
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
