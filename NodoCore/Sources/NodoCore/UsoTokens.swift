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
/// Las funciones base solo reciben tokens y precios por millon; las que valoran
/// mensajes resuelven el proveedor registrado de cada uno sin tocar interfaces.
/// Si falta cualquiera de los dos precios devuelve nil, porque un costo
/// inventado es peor que no ensenar costo.
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

    /// Costo de un mensaje con los precios del proveedor que lo genero.
    ///
    /// Se usa el proveedor anotado en el propio mensaje y, solo si no lo trae
    /// (mensajes viejos), el proveedor registrado del chat. Nunca el activo
    /// global: cambiar de modelo no puede reescribir la factura pasada.
    public static func costo(
        de mensaje: ChatMessage,
        proveedores: [ProviderConfig],
        proveedorDelChat: UUID?
    ) -> Double? {
        guard let uso = mensaje.uso else { return nil }
        let id = mensaje.proveedorID ?? proveedorDelChat
        guard let id,
              let proveedor = proveedores.first(where: { $0.id == id })
        else {
            return nil
        }
        return costo(
            uso: uso,
            precioEntrada: proveedor.precioEntradaPorMillon,
            precioSalida: proveedor.precioSalidaPorMillon
        )
    }

    /// Costo con el que un mensaje aporta al total: su sello si lo tiene y, si
    /// no, su valoracion por proveedor propio.
    ///
    /// El sello es inmutable (se escribio al cerrar la generacion). El respaldo
    /// por proveedor existe solo para los legados que todavia no pasaron por
    /// COST.3; si su proveedor no se puede resolver devuelve nil, porque un
    /// costo desconocido no se rellena con el proveedor activo.
    public static func costoSellado(
        de mensaje: ChatMessage,
        proveedores: [ProviderConfig],
        proveedorDelChat: UUID?
    ) -> Double? {
        if let sellado = mensaje.costoSelladoUSD { return sellado }
        return costo(
            de: mensaje,
            proveedores: proveedores,
            proveedorDelChat: proveedorDelChat
        )
    }

    /// Costo acumulado del chat leyendo los SELLOS de cada mensaje.
    ///
    /// Es el lector unico del que salen `costoAcumuladoDelChat`, el pie de cada
    /// respuesta, la franja de tope y la pastilla de la lista. Devuelve nil si
    /// no hay consumo medido o si algun mensaje con uso no se puede valorar: un
    /// total parcial seria una cifra inventada.
    public static func acumuladoSellado(
        mensajes: [ChatMessage],
        proveedores: [ProviderConfig],
        proveedorDelChat: UUID?
    ) -> Double? {
        var total = 0.0
        var hayUso = false

        for mensaje in mensajes {
            guard mensaje.uso != nil else { continue }
            hayUso = true
            guard let parcial = costoSellado(
                de: mensaje,
                proveedores: proveedores,
                proveedorDelChat: proveedorDelChat
            ) else {
                return nil
            }
            total += parcial
        }
        return hayUso ? total : nil
    }

    /// Suma dos costos opcionales sin inventar.
    ///
    /// nil significa "no se pudo valorar" y contamina la suma: es la forma de
    /// que un tramo desconocido no se confunda con un tramo de cero dolares.
    public static func sumar(_ izquierda: Double?, _ derecha: Double?) -> Double? {
        guard let izquierda, let derecha else { return nil }
        return izquierda + derecha
    }
}
