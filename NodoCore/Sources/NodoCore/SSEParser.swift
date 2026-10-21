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
///
/// Trabaja sobre bytes y no sobre caracteres a proposito: Swift considera que
/// "\r\n" es **un solo caracter**, asi que buscar "\n" en una cadena no
/// encuentra los finales de linea de Windows. Un servidor que use CRLF dejaria
/// el parser en blanco. Sobre bytes, un retorno de carro y un salto de linea son
/// dos valores distintos y no hay ambiguedad.
public struct SSEParser {
    private static let saltoDeLinea: UInt8 = 0x0A
    private static let retornoDeCarro: UInt8 = 0x0D

    private var buffer: [UInt8] = []
    private var eventoActual: String?
    private var lineasDeDatos: [String] = []

    public init() {}

    /// Anade un trozo recibido en crudo y devuelve los eventos completos.
    ///
    /// Se reciben bytes y no texto a proposito: un trozo de red puede cortar un
    /// acento o un emoji por la mitad, y decodificarlo entonces devolveria nil,
    /// perdiendo el trozo entero. Aqui solo se decodifica cuando ya hay una
    /// linea completa, que siempre termina en un limite valido de UTF-8.
    public mutating func consumir(_ datos: Data) -> [SSEEvent] {
        buffer.append(contentsOf: datos)
        return extraerEventos()
    }

    /// Comodidad para las pruebas y para quien ya tenga texto.
    public mutating func consumir(_ trozo: String) -> [SSEEvent] {
        consumir(Data(trozo.utf8))
    }

    private mutating func extraerEventos() -> [SSEEvent] {
        var salida: [SSEEvent] = []

        while let indice = buffer.firstIndex(where: {
            $0 == Self.saltoDeLinea || $0 == Self.retornoDeCarro
        }) {
            let esRetorno = buffer[indice] == Self.retornoDeCarro
            var fin = indice + 1

            if esRetorno {
                if fin < buffer.count, buffer[fin] == Self.saltoDeLinea {
                    // Es un final de linea de Windows completo: se consumen los
                    // dos bytes como un solo terminador.
                    fin += 1
                } else if fin == buffer.count {
                    // El retorno de carro esta justo en el borde del trozo: no
                    // se sabe todavia si le sigue un salto de linea. Se espera
                    // al siguiente trozo para no partir el terminador.
                    break
                }
            }

            let linea = String(decoding: buffer[..<indice], as: UTF8.self)
            buffer.removeSubrange(0..<fin)

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
            var restante = String(decoding: buffer, as: UTF8.self)
            buffer = []
            if restante.hasSuffix("\r") { restante.removeLast() }
            if let evento = procesar(restante) {
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
