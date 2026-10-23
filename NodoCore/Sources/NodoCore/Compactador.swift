import Foundation

/// Resultado puro de una compactacion en cadena.
///
/// `mensajes` son solo los mensajes que sobreviven en el hilo. El resumen vive
/// aparte (`resumen`) porque no es un mensaje de la conversacion: se inyecta
/// como contexto de sistema en cada turno. Mantenerlos separados evita que la
/// poda borre el resumen por accidente y permite declarar el caso de rescate.
public struct ResultadoCompactacion: Equatable {
    /// Ultimos mensajes que se conservan intactos (como maximo 6).
    public let mensajes: [ChatMessage]
    /// Resumen final que se debe inyectar en los turnos siguientes.
    ///
    /// Es nil cuando la cadena se agoto sin bajar del presupuesto y se aplico
    /// el rescate: en ese caso solo quedan los ultimos mensajes y el resultado
    /// lo declara con `conservoUltimos`.
    public let resumen: String?
    /// Ultimo resumen generado, aunque el rescate lo haya descartado.
    ///
    /// La app lo usa para avisar de lo ocurrido sin volver a inventar contexto:
    /// si `resumen` es nil, este texto NO se inyecta en los turnos.
    public let ultimoResumen: String?
    /// Cuantas llamadas de resumen se hicieron (0..3).
    public let pasadas: Int
    /// Estimacion de tokens del contexto final (resumen inyectado + mensajes).
    public let contextoEstimado: Int
    /// Presupuesto contra el que se comparo, si se conocia.
    public let presupuesto: Int?
    /// True si se hicieron las tres pasadas sin bajar y se conservaron solo
    /// los ultimos 6 mensajes.
    public let conservoUltimos: Bool

    /// True si el contexto final sigue por encima del presupuesto.
    ///
    /// Puede ser true incluso en el rescate si los ultimos 6 mensajes ya no
    /// caben por si solos: no se recortan mas porque perder el hilo reciente es
    /// peor que declarar el exceso.
    public var excedePresupuesto: Bool {
        guard let presupuesto else { return false }
        return contextoEstimado > presupuesto
    }
}

/// Reglas puras de compactacion en cadena.
///
/// Vive en NodoCore para poder probar el comportamiento con una clausura de
/// resumen falsa, sin red ni simulador. La app solo aporta el presupuesto del
/// chat abierto y el motor real que produce cada resumen.
public enum Compactador {
    /// Mensajes que sobreviven a cualquier compactacion.
    public static let mensajesConservados = 6
    /// Minimo de mensajes para que /compact tenga sentido. Es el mismo corte
    /// que usa la app para avisar "la conversacion es corta": por debajo de
    /// este numero no hay nada que resumir sin perder el hilo entero.
    public static let minimoParaResumir = 6
    /// Tope duro de pasadas: mas alla de tres resumenes, insistir solo gasta
    /// tokens sin garantizar que el contexto baje.
    public static let maxPasadas = 3
    /// Fraccion de la ventana que se considera presupuesto util. Se deja aire
    /// para el prompt de sistema, las skills y la respuesta que viene.
    public static let umbralPresupuesto = 0.8

    /// Presupuesto en tokens para una ventana y un umbral.
    ///
    /// Devuelve nil si no hay ventana o si el umbral no es positivo: sin
    /// denominador no se inventa un limite. El umbral se puede pasar mayor que
    /// 1 si el usuario quiere permitir pasarse de la ventana, pero el valor por
    /// defecto deja un margen del 20 %.
    public static func presupuesto(
        ventana: Int,
        umbral: Double = umbralPresupuesto
    ) -> Int? {
        guard ventana > 0, umbral > 0, umbral.isFinite else { return nil }
        return max(1, Int((Double(ventana) * umbral).rounded(.down)))
    }

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

    /// Texto que se le pasa al resumidor en la primera pasada.
    ///
    /// Se conservan los roles como prefijo porque el modelo necesita saber
    /// quien dijo cada cosa; el formato es solo para el resumen, nunca se
    /// guarda en la conversacion.
    public static func textoParaResumir(_ mensajes: [ChatMessage]) -> String {
        mensajes
            .map { "\($0.rol.rawValue): \($0.texto)" }
            .joined(separator: "\n\n")
    }

    /// Compacta resumiendo y, si el contexto estimado sigue sobre el
    /// presupuesto, vuelve a resumir sobre el resultado anterior.
    ///
    /// - Parameters:
    ///   - mensajes: historial completo que se quiere compactar.
    ///   - presupuesto: tokens maximos deseados. nil significa que no hay
    ///     ventana conocida: se hace una sola pasada y no se encadena.
    ///   - resumir: clausura que recibe el texto a resumir y devuelve el
    ///     resumen. En la app es una llamada al modelo; en los tests, un doble.
    ///
    /// La primera pasada resume el historial completo (igual que hacia
    /// /compact). Las siguientes resumen el resultado de la anterior: el
    /// resumen mas los ultimos mensajes que se conservaran. Si las tres
    /// pasadas no bastan, se descarta el resumen y se conservan los ultimos 6
    /// mensajes, dejando constancia en `conservoUltimos`.
    public static func resumirEnCadena(
        mensajes: [ChatMessage],
        presupuesto: Int?,
        resumir: (String) async throws -> String
    ) async throws -> ResultadoCompactacion {
        let retenidos = Array(mensajes.suffix(mensajesConservados))

        guard !mensajes.isEmpty else {
            return ResultadoCompactacion(
                mensajes: [],
                resumen: nil,
                ultimoResumen: nil,
                pasadas: 0,
                contextoEstimado: 0,
                presupuesto: presupuesto,
                conservoUltimos: false
            )
        }

        var entrada = textoParaResumir(mensajes)
        var resumen: String?
        var ultimoResumen: String?
        var pasadas = 0
        var contexto = estimarContexto(mensajes: retenidos)

        while pasadas < maxPasadas {
            let generado = try await resumir(entrada)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pasadas += 1
            ultimoResumen = generado.isEmpty ? nil : generado
            resumen = ultimoResumen
            contexto = estimarContexto(mensajes: retenidos, resumen: resumen)

            // Sin presupuesto no hay nada contra lo que encadenar: una pasada
            // deja el resumen y los ultimos mensajes, que es el contrato de
            // /compact cuando la ventana del modelo no esta definida.
            guard let presupuesto else {
                return ResultadoCompactacion(
                    mensajes: retenidos,
                    resumen: resumen,
                    ultimoResumen: ultimoResumen,
                    pasadas: pasadas,
                    contextoEstimado: contexto,
                    presupuesto: nil,
                    conservoUltimos: false
                )
            }

            if contexto <= presupuesto {
                return ResultadoCompactacion(
                    mensajes: retenidos,
                    resumen: resumen,
                    ultimoResumen: ultimoResumen,
                    pasadas: pasadas,
                    contextoEstimado: contexto,
                    presupuesto: presupuesto,
                    conservoUltimos: false
                )
            }

            if pasadas < maxPasadas {
                // "Sobre el resultado": el resumen anterior viaja junto con
                // los mensajes que se van a conservar, para que la segunda
                // pasada tambien pueda comprimir lo que quedo del hilo.
                entrada = textoParaResumir(
                    [ChatMessage(rol: .sistema, texto: resumen ?? "")] + retenidos
                )
            }
        }

        // Rescate: se agotaron las pasadas con el contexto aun por encima del
        // presupuesto. Se descarta el resumen (puede ser justo lo que sobra) y
        // se conservan los ultimos 6, declarandolo en el resultado.
        let contextoFinal = estimarContexto(mensajes: retenidos)
        return ResultadoCompactacion(
            mensajes: retenidos,
            resumen: nil,
            ultimoResumen: ultimoResumen,
            pasadas: pasadas,
            contextoEstimado: contextoFinal,
            presupuesto: presupuesto,
            conservoUltimos: true
        )
    }

    /// Variante comoda cuando se conoce la ventana del proveedor.
    public static func resumirEnCadena(
        mensajes: [ChatMessage],
        ventana: Int,
        umbral: Double = umbralPresupuesto,
        resumir: (String) async throws -> String
    ) async throws -> ResultadoCompactacion {
        try await resumirEnCadena(
            mensajes: mensajes,
            presupuesto: presupuesto(ventana: ventana, umbral: umbral),
            resumir: resumir
        )
    }
}
