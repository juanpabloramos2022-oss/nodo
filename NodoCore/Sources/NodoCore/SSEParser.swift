import Foundation

/// Un evento del protocolo de envio por partes (server-sent events).
public struct SSEEvent: Equatable {
    public var evento: String?
    public var datos: String

    public init(evento: String? = nil, datos: String) {
        self.evento = evento
        self.datos = datos
    }
}

/// Parser incremental de server-sent events.
///
/// Es incremental porque la red no entrega las lineas completas: un trozo puede
/// cortar una linea por la mitad, y un parser que asuma lineas completas pierde
/// texto justo cuando el modelo va mas rapido.
public struct SSEParser {
    private var buffer = ""
    private var eventoActual: String?
    private var lineasDeDatos: [String] = []

    public init() {}

    /// Anade un trozo recibido y devuelve los eventos que quedaron completos.
    public mutating func consumir(_ trozo: String) -> [SSEEvent] {
        buffer += trozo
        var salida: [SSEEvent] = []

        while let salto = buffer.firstIndex(of: "\n") {
            var linea = String(buffer[buffer.startIndex..<salto])
            buffer.removeSubrange(buffer.startIndex...salto)
            if linea.hasSuffix("\r") { linea.removeLast() }
            if let evento = procesar(linea) {
                salida.append(evento)
            }
        }

        return salida
    }

    /// Cierra el stream y devuelve lo que quede pendiente.
    ///
    /// Algunos servidores no terminan con linea en blanco; sin esto se perderia
    /// el ultimo evento.
    public mutating func terminar() -> [SSEEvent] {
        var salida: [SSEEvent] = []

        if !buffer.isEmpty {
            var linea = buffer
            buffer = ""
            if linea.hasSuffix("\r") { linea.removeLast() }
            if let evento = procesar(linea) {
                salida.append(evento)
            }
        }

        if let evento = despachar() {
            salida.append(evento)
        }

        return salida
    }

    private mutating func procesar(_ linea: String) -> SSEEvent? {
        // Linea en blanco: el evento esta completo.
        if linea.isEmpty { return despachar() }

        // Los comentarios empiezan por dos puntos y se ignoran. Los servidores
        // los usan como latido para que la conexion no se cierre.
        if linea.hasPrefix(":") { return nil }

        guard let dosPuntos = linea.firstIndex(of: ":") else {
            // Campo sin valor: no aporta nada aqui.
            return nil
        }

        let campo = String(linea[linea.startIndex..<dosPuntos])
        var valor = String(linea[linea.index(after: dosPuntos)...])
        if valor.hasPrefix(" ") { valor.removeFirst() }

        switch campo {
        case "event":
            eventoActual = valor
        case "data":
            lineasDeDatos.append(valor)
        default:
            break
        }

        return nil
    }

    private mutating func despachar() -> SSEEvent? {
        guard !lineasDeDatos.isEmpty || eventoActual != nil else { return nil }
        let evento = SSEEvent(
            evento: eventoActual,
            datos: lineasDeDatos.joined(separator: "\n")
        )
        eventoActual = nil
        lineasDeDatos = []
        return evento
    }
}
