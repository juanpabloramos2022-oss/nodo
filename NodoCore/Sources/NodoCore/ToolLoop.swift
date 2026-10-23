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

    public init(motor: ChatEngine, herramientas: [Herramienta], maxIteraciones: Int = 8) {
        self.motor = motor
        self.herramientas = herramientas
        self.maxIteraciones = maxIteraciones
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
            iteraciones += 1

            let respuesta = try await motor.responder(
                mensajes: mensajes,
                herramientas: definiciones,
                alRecibirTexto: alRecibirTexto
            )

            if let uso = respuesta.uso {
                usoTotal = usoTotal?.sumando(uso) ?? uso
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
                let resultado = await ejecutar(llamada)
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

    /// Ejecuta una herramienta y devuelve siempre texto.
    ///
    /// Un fallo no se propaga: se convierte en texto de error para el modelo.
    /// Asi puede corregir los argumentos o probar otra cosa en vez de que el
    /// turno entero se caiga por un nombre mal escrito.
    private func ejecutar(_ llamada: ToolCall) async -> String {
        guard let herramienta = herramientas.first(where: { $0.definicion.nombre == llamada.nombre }) else {
            return "Error: no existe la herramienta \(llamada.nombre)."
        }

        do {
            return try await herramienta.ejecutar(argumentos: llamada.argumentos)
        } catch let error as ErrorHerramienta {
            return "Error: \(error.errorDescription ?? "no se pudo ejecutar")"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
