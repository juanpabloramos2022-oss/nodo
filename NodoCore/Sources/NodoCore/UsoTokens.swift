import Foundation

/// Consumo de tokens de una llamada al modelo.
///
/// Se guarda por separado la entrada y la salida porque cada una se cobra a un
/// precio distinto. Los mensajes de v0.1.0 no tienen estos datos y se quedan en
/// nil, sin inventar cifras.
public struct UsoTokens: Codable, Equatable {
    public var entrada: Int
    public var salida: Int

    public init(entrada: Int = 0, salida: Int = 0) {
        self.entrada = entrada
        self.salida = salida
    }

    /// Suma de entrada y salida, para el acumulado visible del chat.
    public var total: Int { entrada + salida }

    /// Suma dos consumos, que es lo que hace falta para juntar las llamadas
    /// internas de un turno con herramientas.
    public func sumando(_ otro: UsoTokens) -> UsoTokens {
        UsoTokens(entrada: entrada + otro.entrada, salida: salida + otro.salida)
    }

    public static func + (izquierda: UsoTokens, derecha: UsoTokens) -> UsoTokens {
        izquierda.sumando(derecha)
    }
}

/// Calculadora pura de costo estimado.
///
/// No conoce proveedores ni interfaces: solo tokens y precios por millon. Si
/// falta cualquiera de los dos precios devuelve nil, porque un costo inventado
/// es peor que no ensenar costo.
public enum CostoEstimado {
    /// Costo en dolares de un consumo a los precios indicados.
    public static func costo(
        uso: UsoTokens,
        precioEntrada: Double?,
        precioSalida: Double?
    ) -> Double? {
        guard let precioEntrada, let precioSalida,
              precioEntrada.isFinite, precioSalida.isFinite,
              precioEntrada >= 0, precioSalida >= 0
        else {
            return nil
        }

        let entrada = Double(uso.entrada) * precioEntrada
        let salida = Double(uso.salida) * precioSalida
        return (entrada + salida) / 1_000_000
    }

    /// Suma el consumo de los mensajes que lo tengan.
    ///
    /// Los mensajes sin cifras (los de v0.1.0) no suman. Devuelve nil si ninguno
    /// trae consumo, para que la vista no pinte una fila vacia.
    public static func usoAcumulado(de mensajes: [ChatMessage]) -> UsoTokens? {
        var total: UsoTokens?
        for mensaje in mensajes {
            guard let uso = mensaje.uso else { continue }
            total = total?.sumando(uso) ?? uso
        }
        return total
    }

    /// Costo acumulado de una conversacion a los precios dados.
    ///
    /// Devuelve nil si no hay consumo medido o si faltan precios.
    public static func acumulado(
        mensajes: [ChatMessage],
        precioEntrada: Double?,
        precioSalida: Double?
    ) -> Double? {
        guard let uso = usoAcumulado(de: mensajes) else { return nil }
        return costo(uso: uso, precioEntrada: precioEntrada, precioSalida: precioSalida)
    }
}
