import Foundation

/// Metricas de la ventana de contexto del chat (§4.1).
///
/// Se mantienen separadas del consumo acumulado a proposito: la ocupacion mira
/// SOLO la ultima respuesta y puede bajar tras compactar; el acumulado
/// (`CostoEstimado.usoAcumulado`) suma todo el historial y nunca baja.
public enum MetricasChat {
    /// Ocupacion de la ventana: el uso del ultimo mensaje que lo traiga.
    ///
    /// Ese uso es el `total_tokens` de la ultima llamada (entrada + salida). Los
    /// mensajes posteriores sin cifras no lo borran, y si ninguno trae uso no
    /// hay nada que medir.
    public static func ocupacionVentana(de mensajes: [ChatMessage]) -> UsoTokens? {
        for mensaje in mensajes.reversed() {
            if let uso = mensaje.uso { return uso }
        }
        return nil
    }

    /// Ocupacion de la ventana de una conversacion, con el respaldo de /compact.
    ///
    /// Manda el uso del ultimo mensaje que lo traiga. Si ningun mensaje tiene
    /// cifras, se usa el consumo de la llamada de resumen (`usoTrasCompactar`),
    /// que es lo que hace bajar el medidor tras compactar sin tocar el
    /// acumulado facturable. `mensaje` solo se rellena en ese respaldo, para
    /// que la vista pueda explicar de donde sale la cifra.
    public static func ocupacionVentana(
        de conversacion: Conversation
    ) -> (tokens: Int, mensaje: String?) {
        for mensaje in conversacion.mensajes.reversed() {
            if let uso = mensaje.uso { return (uso.total, nil) }
        }
        if let uso = conversacion.usoTrasCompactar {
            return (uso.total, "Ocupación medida tras compactar")
        }
        return (0, nil)
    }

    /// Fraccion de la ventana ocupada, o nil si no hay ventana definida.
    ///
    /// No se recorta a 1.0: pasarse de la ventana es informacion que la vista
    /// necesita ensenar, no un error que esconder.
    public static func porcentaje(ocupacion: Int, ventana: Int?) -> Double? {
        guard let ventana, ventana > 0 else { return nil }
        return Double(ocupacion) / Double(ventana)
    }
}
