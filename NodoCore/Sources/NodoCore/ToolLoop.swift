import Foundation

/// Resultado de un turno completo, con las herramientas ya ejecutadas.
public struct ResultadoTurno: Equatable {
    /// Mensajes nuevos que se anadieron al historial, en orden: el del
    /// asistente y los de cada herramienta ejecutada.
    public var mensajesNuevos: [ChatMessage]
    /// Texto final visible.
    public var texto: String
    /// Cuantas vueltas dio el bucle.
    public var iteraciones: Int
    /// Si se corto por el limite y no porque el modelo terminara.
    public var seAgotoElLimite: Bool
    /// Suma del consumo de todas las llamadas internas del turno.
    public var usoTotal: UsoTokens?

    public init(
        mensajesNuevos: [ChatMessage],
        texto: String,
        iteraciones: Int,
        seAgotoElLimite: Bool = false,
        usoTotal: UsoTokens? = nil
    ) {
        self.mensajesNuevos = mensajesNuevos
        self.texto = texto
        self.iteraciones = iteraciones
        self.seAgotoElLimite = seAgotoElLimite
        self.usoTotal = usoTotal
    }
}

/// Ejecuta el ciclo: el modelo pide herramientas, se ejecutan, el resultado
/// vuelve al modelo, y asi hasta que responde sin pedir nada.
///
/// El limite de vueltas no es una precaucion teorica: sin el, un modelo que se
/// engancha pidiendo la misma herramienta deja la app pidiendo datos en bucle y
/// gasta cuota sin control.
public final class ToolLoop {
    private let motor: ChatEngine
    private let herramientas: [Herramienta]
    public let maxIteraciones: Int

    /// Se llama justo antes de ejecutar una herramienta, con la llamada que
    /// pidio el modelo. Sin gancho no cambia nada.
    ///
    /// Es async a proposito: la app persiste el paso en ese mismo instante y no
    /// puede hacerlo desde un ejecutor arbitrario sin saltar al MainActor.
    public var alIniciarHerramienta: ((ToolCall) async -> Void)?
    /// Se llama justo despues de ejecutar una herramienta, con el resultado
    /// que se le devolvera al modelo (tambien si fue un error).
    public var alTerminarHerramienta: ((ToolCall, String) async -> Void)?
    /// Se llama cuando el dueno deniega una herramienta. El paso se marca
    /// Denegado y el bucle sigue con el texto del rechazo.
    public var alDenegarHerramienta: ((ToolCall, String) async -> Void)?
    /// Se llama con el consumo de CADA llamada al modelo. La tarea lo sella con
    /// los precios del proveedor y lo acumula en su libro de gasto.
    public var alTerminarLlamadaModelo: ((UsoTokens) async -> Void)?
    /// Pregunta al usuario si una herramienta puede ejecutarse. Solo se usa
    /// cuando `requiereAprobacion` devuelve true.
    public var aprobador: ((ToolCall) async -> Bool)?
    /// Clasifica una llamada concreta. Si no hay gancho, nada pide aprobacion.
    public var requiereAprobacion: ((ToolCall) -> Bool)?

    public init(
        motor: ChatEngine,
        herramientas: [Herramienta],
        maxIteraciones: Int = 8,
        alIniciarHerramienta: ((ToolCall) async -> Void)? = nil,
        alTerminarHerramienta: ((ToolCall, String) async -> Void)? = nil,
        alDenegarHerramienta: ((ToolCall, String) async -> Void)? = nil,
        alTerminarLlamadaModelo: ((UsoTokens) async -> Void)? = nil,
        aprobador: ((ToolCall) async -> Bool)? = nil,
        requiereAprobacion: ((ToolCall) -> Bool)? = nil
    ) {
        self.motor = motor
        self.herramientas = herramientas
        self.maxIteraciones = maxIteraciones
        self.alIniciarHerramienta = alIniciarHerramienta
        self.alTerminarHerramienta = alTerminarHerramienta
        self.alDenegarHerramienta = alDenegarHerramienta
        self.alTerminarLlamadaModelo = alTerminarLlamadaModelo
        self.aprobador = aprobador
        self.requiereAprobacion = requiereAprobacion
    }

    public func ejecutar(
        historial: [ChatMessage],
        alRecibirTexto: ((String) -> Void)? = nil
    ) async throws -> ResultadoTurno {
        var mensajes = historial
        var nuevos: [ChatMessage] = []
        var textoAcumulado = ""
        var iteraciones = 0
        var usoTotal: UsoTokens?

        let definiciones = herramientas.map { $0.definicion }

        /// Cierra el turno con el consumo total en el ultimo mensaje de
        /// asistente. Ese es el que pinta la vista y el que suma el acumulado
        /// guardado, asi que no se repite el uso en las llamadas intermedias.
        func armarResultado(seAgotoElLimite: Bool) -> ResultadoTurno {
            var mensajesFinales = nuevos
            if let usoTotal,
               let indice = mensajesFinales.lastIndex(where: { $0.rol == .asistente }) {
                mensajesFinales[indice].tokensEntrada = usoTotal.entrada
                mensajesFinales[indice].tokensSalida = usoTotal.salida
            }
            return ResultadoTurno(
                mensajesNuevos: mensajesFinales,
                texto: textoAcumulado,
                iteraciones: iteraciones,
                seAgotoElLimite: seAgotoElLimite,
                usoTotal: usoTotal
            )
        }

        while iteraciones < maxIteraciones {
            // Detener tiene que cortar tambien entre vueltas, no solo durante
            // una peticion de red: si el modelo ya respondio, no se le vuelve a
            // llamar con la tarea cancelada.
            try Task.checkCancellation()
            iteraciones += 1

            let respuesta = try await motor.responder(
                mensajes: mensajes,
                herramientas: definiciones,
                alRecibirTexto: alRecibirTexto
            )
            try Task.checkCancellation()

            if let uso = respuesta.uso {
                usoTotal = usoTotal?.sumando(uso) ?? uso
                // COST: cada llamada se sella por separado, antes de seguir.
                // Asi el panel de la tarea tiene el costo vivo y no solo el
                // total al cerrar el turno.
                await alTerminarLlamadaModelo?(uso)
            }

            if !respuesta.texto.isEmpty {
                textoAcumulado += respuesta.texto
            }

            let mensajeAsistente = ChatMessage(
                rol: .asistente,
                texto: respuesta.texto,
                toolCalls: respuesta.toolCalls
            )
            mensajes.append(mensajeAsistente)
            nuevos.append(mensajeAsistente)

            guard respuesta.pideHerramientas else {
                return armarResultado(seAgotoElLimite: false)
            }

            for llamada in respuesta.toolCalls {
                let resultado = try await ejecutarConAprobacion(llamada)
                let mensajeHerramienta = ChatMessage(
                    rol: .herramienta,
                    texto: resultado,
                    toolCalls: [],
                    toolCallId: llamada.id
                )
                mensajes.append(mensajeHerramienta)
                nuevos.append(mensajeHerramienta)
            }
        }

        return armarResultado(seAgotoElLimite: true)
    }

    /// Aplica la politica de aprobacion y, si toca, ejecuta la herramienta.
    ///
    /// Si el usuario rechaza (o no hay aprobador), la herramienta no corre: el
    /// modelo recibe el texto del rechazo y decide si sigue o cierra el turno.
    /// Los ganchos de inicio y fin solo envuelven una ejecucion real.
    private func ejecutarConAprobacion(_ llamada: ToolCall) async throws -> String {
        if requiereAprobacion?(llamada) == true {
            let aprobada: Bool
            if let aprobador {
                aprobada = await aprobador(llamada)
            } else {
                aprobada = false
            }

            // Detener mientras la hoja esta abierta cancela la tarea: no se
            // ejecuta nada aunque la continuacion se haya resuelto.
            try Task.checkCancellation()

            guard aprobada else {
                let motivo = "denegado por el dueno"
                await alDenegarHerramienta?(llamada, motivo)
                return motivo
            }
        }

        try Task.checkCancellation()
        await alIniciarHerramienta?(llamada)
        let resultado = try await ejecutar(llamada)
        // Si Detener llego mientras la herramienta trabajaba, el resultado ya
        // no se publica como terminado: el paso queda como lo dejo Detener.
        try Task.checkCancellation()
        await alTerminarHerramienta?(llamada, resultado)
        return resultado
    }

    /// Ejecuta una herramienta y devuelve siempre texto.
    ///
    /// Un fallo no se propaga: se convierte en texto de error para el modelo.
    /// Asi puede corregir los argumentos o probar otra cosa en vez de que el
    /// turno entero se caiga por un nombre mal escrito. La cancelacion si se
    /// propaga: es una orden del dueno, no un error de la herramienta.
    private func ejecutar(_ llamada: ToolCall) async throws -> String {
        guard let herramienta = herramientas.first(where: { $0.definicion.nombre == llamada.nombre }) else {
            return "Error: no existe la herramienta \(llamada.nombre)."
        }

        do {
            return try await herramienta.ejecutar(argumentos: llamada.argumentos)
        } catch let error as ErrorHerramienta {
            if Task.isCancelled { throw CancellationError() }
            return "Error: \(error.errorDescription ?? "no se pudo ejecutar")"
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return "Error: \(error.localizedDescription)"
        }
    }
}
