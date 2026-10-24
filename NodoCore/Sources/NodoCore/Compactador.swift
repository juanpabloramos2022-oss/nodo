import Foundation

/// Resultado puro de una compactacion.
///
/// `mensajes` son solo los mensajes que sobreviven en el hilo cuando la
/// compactacion se aplica. El resumen vive aparte (`resumen`) porque no es un
/// mensaje de la conversacion: se inyecta como contexto de sistema en cada
/// turno. Mantenerlos separados evita que la poda borre el resumen por
/// accidente y deja claro cuando la guarda de no-reduccion descarto el intento.
public struct ResultadoCompactacion: Equatable {
    /// Mensajes que quedan en el hilo. Si no se aplico, es el historial original
    /// completo: no se pierde nada.
    public let mensajes: [ChatMessage]
    /// Resumen que se debe guardar e inyectar en los turnos siguientes.
    ///
    /// Es nil cuando el modelo devolvio un resumen vacio o cuando el resumen no
    /// reducia el contexto: en ambos casos la compactacion no se aplica.
    public let resumen: String?
    /// Texto que devolvio el modelo aunque la guarda lo haya descartado.
    ///
    /// La app lo usa para distinguir un resumen vacio (fallo) de uno que no
    /// reducia (aviso). Si no se aplico, este texto NO se guarda ni se inyecta.
    public let resumenGenerado: String?
    /// Estimacion de tokens del historial completo antes de compactar.
    public let contextoOriginal: Int
    /// Estimacion de tokens que resultaria de resumir el prefijo y conservar
    /// los ultimos mensajes. Si no se aplico, es el valor que se comparo contra
    /// `contextoOriginal` para rechazar el resumen.
    public let contextoEstimado: Int
    /// True solo si habia un resumen no vacio y el contexto resultante era
    /// estrictamente menor que el original. Sin esta mejora no se toca el hilo.
    public let aplicada: Bool
}

/// Reglas puras de compactacion.
///
/// Vive en NodoCore para poder probar el comportamiento con una clausura de
/// resumen falsa, sin red ni simulador. La app solo aporta el historial abierto
/// y el motor real que produce el resumen.
public enum Compactador {
    /// Mensajes que sobreviven a cualquier compactacion.
    public static let mensajesConservados = 6
    /// Corte de mensajes conservados. Con este numero o menos no hay prefijo
    /// antiguo que resumir, asi que /compact no debe llamar al modelo.
    public static let minimoParaResumir = mensajesConservados

    /// Estimacion de tokens de un texto: caracteres / 4.
    ///
    /// Es la misma heuristica ligera que usa la app para la Memoria. Un texto
    /// vacio no pesa nada; uno no vacio pesa al menos un token.
    public static func estimarTokens(_ texto: String) -> Int {
        guard !texto.isEmpty else { return 0 }
        return max(1, texto.count / 4)
    }

    /// Estimacion del contexto que se mandaria al modelo.
    ///
    /// Suma el resumen (si lo hay) y cada mensaje. Se incluyen las llamadas de
    /// herramienta porque tambien viajan en el payload y ocupan ventana.
    public static func estimarContexto(
        mensajes: [ChatMessage],
        resumen: String? = nil
    ) -> Int {
        var total = estimarTokens(resumen ?? "")
        for mensaje in mensajes {
            let llamadas = mensaje.toolCalls
                .map { $0.nombre + $0.argumentos }
                .joined()
            let texto = mensaje.texto + llamadas
            total += max(1, texto.count / 4)
        }
        return total
    }

    /// Texto que se le pasa al resumidor.
    ///
    /// Se conservan los roles como prefijo porque el modelo necesita saber
    /// quien dijo cada cosa; el formato es solo para el resumen, nunca se
    /// guarda en la conversacion.
    public static func textoParaResumir(_ mensajes: [ChatMessage]) -> String {
        mensajes
            .map { "\($0.rol.rawValue): \($0.texto)" }
            .joined(separator: "\n\n")
    }

    /// Compacta con UNA sola llamada de resumen sobre el prefijo antiguo.
    ///
    /// El texto que recibe `resumir` son todos los mensajes menos los ultimos
    /// `mensajesConservados`. El historial completo nunca viaja al resumidor:
    /// resumir tambien lo reciente duplicaria contexto y gastaria tokens.
    ///
    /// Guarda de no-reduccion: si el resumen mas los mensajes conservados no
    /// pesan estrictamente menos que el historial original, no se aplica nada.
    /// Se devuelven los mensajes originales y `resumen` queda nil; guardar un
    /// resumen mas grande que lo resumido solo empeoraria la ventana.
    ///
    /// - Parameters:
    ///   - mensajes: historial completo que se quiere compactar.
    ///   - resumir: clausura que recibe el texto del prefijo y devuelve el
    ///     resumen. En la app es una llamada al modelo; en los tests, un doble.
    public static func compactar(
        mensajes: [ChatMessage],
        resumir: (String) async throws -> String
    ) async throws -> ResultadoCompactacion {
        let contextoOriginal = estimarContexto(mensajes: mensajes)
        let retenidos = Array(mensajes.suffix(mensajesConservados))
        let prefijo = Array(
            mensajes.dropLast(min(mensajesConservados, mensajes.count))
        )

        // Sin prefijo antiguo no hay nada que resumir: no se inventa una
        // llamada vacia ni se toca el hilo.
        guard !prefijo.isEmpty else {
            return ResultadoCompactacion(
                mensajes: mensajes,
                resumen: nil,
                resumenGenerado: nil,
                contextoOriginal: contextoOriginal,
                contextoEstimado: contextoOriginal,
                aplicada: false
            )
        }

        let generado = try await resumir(textoParaResumir(prefijo))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !generado.isEmpty else {
            return ResultadoCompactacion(
                mensajes: mensajes,
                resumen: nil,
                resumenGenerado: nil,
                contextoOriginal: contextoOriginal,
                contextoEstimado: contextoOriginal,
                aplicada: false
            )
        }

        let contextoResultante = estimarContexto(
            mensajes: retenidos,
            resumen: generado
        )
        guard contextoResultante < contextoOriginal else {
            return ResultadoCompactacion(
                mensajes: mensajes,
                resumen: nil,
                resumenGenerado: generado,
                contextoOriginal: contextoOriginal,
                contextoEstimado: contextoResultante,
                aplicada: false
            )
        }

        return ResultadoCompactacion(
            mensajes: retenidos,
            resumen: generado,
            resumenGenerado: generado,
            contextoOriginal: contextoOriginal,
            contextoEstimado: contextoResultante,
            aplicada: true
        )
    }

    /// Alias comodo de `compactar`, con el nombre que describe la operacion
    /// pura del resumidor. La semantica es la misma: una sola llamada.
    public static func resumir(
        mensajes: [ChatMessage],
        resumir: (String) async throws -> String
    ) async throws -> ResultadoCompactacion {
        try await compactar(mensajes: mensajes, resumir: resumir)
    }

    /// Alias con el nombre anterior, conservado para las llamadas que aun lo
    /// usan. No encadena pasadas ni acepta presupuesto.
    public static func resumirEnCadena(
        mensajes: [ChatMessage],
        resumir: (String) async throws -> String
    ) async throws -> ResultadoCompactacion {
        try await compactar(mensajes: mensajes, resumir: resumir)
    }

    /// Compatibilidad con la firma que recibia un presupuesto.
    ///
    /// El presupuesto ya no interviene: la unica decision es la guarda de
    /// no-reduccion. Se conserva la etiqueta para no romper llamadas viejas.
    public static func resumirEnCadena(
        mensajes: [ChatMessage],
        presupuesto _: Int?,
        resumir: (String) async throws -> String
    ) async throws -> ResultadoCompactacion {
        try await compactar(mensajes: mensajes, resumir: resumir)
    }
}
