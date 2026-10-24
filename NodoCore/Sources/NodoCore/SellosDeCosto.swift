import Foundation

/// Escritura del sello de costo de un mensaje (COST.1 y COST.3).
///
/// POR QUE un sello y no un recalculo: los precios de un proveedor cambian con
/// el tiempo. El dolar que se pago al cerrar la generacion de un mensaje se
/// escribe UNA vez y no se vuelve a tocar; recalcularlo despues con los precios
/// de hoy inventaria un gasto que no ocurrio.
///
/// La lectura de esos sellos vive en `CostoEstimado.costoSellado` y
/// `CostoEstimado.acumuladoSellado`, el lector unico que comparten el
/// acumulado del chat, el pie de cada respuesta, la franja de tope y la
/// pastilla de la lista.
public enum SellosDeCosto {
    /// Sella un mensaje recien generado con los precios del proveedor que lo
    /// genero EN ESTE MOMENTO.
    ///
    /// Solo escribe si el mensaje trae consumo y aun no tiene sello: un sello
    /// no se reescribe nunca, ni al regenerar ni al reintentar. Si el
    /// proveedor no tiene precios, el mensaje queda sin sello (costo
    /// desconocido) en vez de inventar una cifra.
    @discardableResult
    public static func sellar(
        _ mensaje: inout ChatMessage,
        proveedor: ProviderConfig
    ) -> Double? {
        guard mensaje.costoSelladoUSD == nil, let uso = mensaje.uso else {
            return mensaje.costoSelladoUSD
        }
        guard let costo = CostoEstimado.costo(
            uso: uso,
            precioEntrada: proveedor.precioEntradaPorMillon,
            precioSalida: proveedor.precioSalidaPorMillon
        ) else {
            return nil
        }
        mensaje.costoSelladoUSD = costo
        // Un sello escrito al cerrar la generacion es el costo real, no una
        // estimacion de legado.
        mensaje.costoEsEstimacion = false
        return costo
    }

    /// Sella los mensajes legados de un hilo al cargarlo (COST.3).
    ///
    /// Cada mensaje con uso y sin sello se valora con los precios ACTUALES del
    /// proveedor que lo genero (el anotado en el mensaje o, en los mas viejos,
    /// el registrado del chat), jamas con el proveedor activo. El sello queda
    /// marcado como estimacion para que la interfaz lo advierta. Si el
    /// proveedor no se puede resolver, el mensaje se queda sin sello: un costo
    /// desconocido no se rellena con otro proveedor.
    ///
    /// Devuelve cuantos mensajes se sellaron, para que quien llama sepa si hay
    /// algo que volver a guardar.
    @discardableResult
    public static func sellarLegados(
        en mensajes: inout [ChatMessage],
        proveedores: [ProviderConfig],
        proveedorDelChat: UUID?
    ) -> Int {
        var cambios = 0

        for indice in mensajes.indices {
            guard mensajes[indice].costoSelladoUSD == nil,
                  let uso = mensajes[indice].uso
            else {
                continue
            }

            let id = mensajes[indice].proveedorID ?? proveedorDelChat
            guard let id,
                  let proveedor = proveedores.first(where: { $0.id == id }),
                  let costo = CostoEstimado.costo(
                      uso: uso,
                      precioEntrada: proveedor.precioEntradaPorMillon,
                      precioSalida: proveedor.precioSalidaPorMillon
                  )
            else {
                continue
            }

            mensajes[indice].costoSelladoUSD = costo
            mensajes[indice].costoEsEstimacion = true
            cambios += 1
        }

        return cambios
    }

    /// Version de `sellarLegados` para una conversacion completa.
    @discardableResult
    public static func sellarLegados(
        en conversacion: inout Conversation,
        proveedores: [ProviderConfig]
    ) -> Int {
        // Se lee el proveedor del chat antes de prestar `mensajes` como inout:
        // tocar las dos propiedades a la vez romperia la exclusividad.
        let delChat = conversacion.proveedorID
        return sellarLegados(
            en: &conversacion.mensajes,
            proveedores: proveedores,
            proveedorDelChat: delChat
        )
    }
}
