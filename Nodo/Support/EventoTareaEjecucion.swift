import Foundation

/// Un evento de ejecucion del libro de pasos, tal como lo emite el motor y lo
/// consume el ViewModel del hilo (B3-B, paso bloqueante B.1).
///
/// POR QUE un tipo propio y no una lectura de `tareas`: la vista de Tarea se
/// reconstruia desde el estado persistido y solo al cerrar el turno. El
/// progreso vivo necesita la TRANSICION en el instante en que ocurre, con su
/// marca de tiempo de pared, para que la traza pruebe la primera senal y el
/// latido. El libro sigue siendo la fuente de verdad (cada evento se emite
/// DESPUES de escribir el paso); este tipo es el canal, no un segundo estado.
///
/// Serializacion (§0.1): lo emite `EstadoApp` y lo aplica
/// `HiloTareaViewModel`, ambos `@MainActor`, con `secuencia` monotona. El
/// ViewModel reordena por secuencia, asi que el orden de la traza es el de
/// emision aunque dos tareas se adelanten.
struct EventoTareaEjecucion: Equatable {
    /// Que ocurrio. No hay caso para un resultado crudo de herramienta: el
    /// detalle visible es siempre un rotulo humano.
    enum Tipo: Equatable {
        /// [Empezar]: el motor arranca y consulta al modelo. Es la primera
        /// senal, emitida antes de abrir la red.
        case turnoIniciado
        /// El paso K entra al libro y pasa a En curso.
        case pasoIniciado
        /// Cambio del estado dinamico del paso en curso (latido incluido).
        case actividad
        /// El paso K cerro: completado, denegado, detenido o con error.
        case pasoCerrado
        /// Sello nuevo del mensaje: la cabecera mueve su costo vivo.
        case costoSellado
        /// El paso K espera la decision del dueno en la hoja.
        case aprobacionPendiente
        /// [Detener] en el paso K.
        case detenido
        /// La tarea cerro sin error.
        case finalizada
        /// Error en linea sobre el paso K.
        case error
    }

    /// Numero de emision, 1-based y monotono por app.
    let secuencia: Int
    let tareaID: UUID
    /// Instante de pared de la emision. Es la marca que mide los umbrales.
    let fecha: Date
    let tipo: Tipo
    /// Paso visible (1-based). En `turnoIniciado` es el paso 1.
    let paso: Int
    let pasosTotales: Int
    /// Nombre real del paso (el del plan, o el rotulo humano del libro).
    let etiqueta: String
    /// Estado dinamico legible: «Consultando modelo…», «Esperando respuesta
    /// (1,4 s)…». Vacio cuando el evento no aporta uno.
    let estadoDinamico: String
    /// Estado visible de la fila que este evento fija.
    let estado: ElementoTareaVisible.EstadoPaso
    let duracion: TimeInterval?
    let costo: Decimal?
    /// Costo sellado acumulado de la tarea tras este evento.
    let costoSelladoTarea: Decimal?
    /// Texto humano adicional (motivo de denegacion, mensaje de error).
    let detalle: String

    init(
        secuencia: Int,
        tareaID: UUID,
        fecha: Date = Date(),
        tipo: Tipo,
        paso: Int,
        pasosTotales: Int,
        etiqueta: String = "",
        estadoDinamico: String = "",
        estado: ElementoTareaVisible.EstadoPaso = .pendiente,
        duracion: TimeInterval? = nil,
        costo: Decimal? = nil,
        costoSelladoTarea: Decimal? = nil,
        detalle: String = ""
    ) {
        self.secuencia = secuencia
        self.tareaID = tareaID
        self.fecha = fecha
        self.tipo = tipo
        self.paso = paso
        self.pasosTotales = pasosTotales
        self.etiqueta = etiqueta
        self.estadoDinamico = estadoDinamico
        self.estado = estado
        self.duracion = duracion
        self.costo = costo
        self.costoSelladoTarea = costoSelladoTarea
        self.detalle = detalle
    }
}
