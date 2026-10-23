import Foundation

/// Una llamada a herramienta que el modelo pide ejecutar.
///
/// Los argumentos se guardan como texto JSON crudo, tal como los envia el
/// modelo, y se validan al ejecutarlos. Guardarlos ya parseados obligaria a
/// rechazar la respuesta entera por un argumento mal formado, y es mejor
/// devolverle el error al modelo para que lo corrija.
public struct ToolCall: Codable, Equatable {
    public var id: String
    public var nombre: String
    public var argumentos: String

    public init(id: String, nombre: String, argumentos: String) {
        self.id = id
        self.nombre = nombre
        self.argumentos = argumentos
    }
}

/// Un mensaje de la conversacion.
public struct ChatMessage: Codable, Identifiable, Equatable {
    public enum Rol: String, Codable, CaseIterable {
        case usuario
        case asistente
        case sistema
        case herramienta
    }

    public var id: UUID
    public var rol: Rol
    public var texto: String
    public var fecha: Date
    /// Llamadas que pidio el modelo en este mensaje. Solo en mensajes de asistente.
    public var toolCalls: [ToolCall]
    /// Identificador de la llamada a la que responde este mensaje. Solo en
    /// mensajes de herramienta.
    public var toolCallId: String?

    public init(
        id: UUID = UUID(),
        rol: Rol,
        texto: String,
        fecha: Date = Date(),
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil
    ) {
        self.id = id
        self.rol = rol
        self.texto = texto
        self.fecha = fecha
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// Un mensaje de herramienta necesita saber a que llamada responde; sin eso
    /// la API lo rechaza.
    public var esValido: Bool {
        if rol == .herramienta { return toolCallId != nil }
        return true
    }
}

/// Una conversacion completa.
public struct Conversation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var titulo: String
    public var mensajes: [ChatMessage]
    public var creada: Date
    public var actualizada: Date

    public init(
        id: UUID = UUID(),
        titulo: String = "Conversacion",
        mensajes: [ChatMessage] = [],
        creada: Date = Date(),
        actualizada: Date = Date()
    ) {
        self.id = id
        self.titulo = titulo
        self.mensajes = mensajes
        self.creada = creada
        self.actualizada = actualizada
    }

    /// Titulo derivado del primer mensaje del usuario, recortado a una linea.
    ///
    /// Se calcula y no se guarda para que renombrar a mano siga siendo posible
    /// sin que el siguiente mensaje lo pise.
    public var tituloSugerido: String {
        guard let primero = mensajes.first(where: { $0.rol == .usuario }) else {
            return "Conversacion"
        }
        let limpio = primero.texto
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty { return "Conversacion" }
        if limpio.count <= 48 { return limpio }
        return String(limpio.prefix(48)) + "..."
    }

    /// Descarta lo que haya despues del ultimo mensaje del usuario y devuelve
    /// ese turno descartado, para poder restaurarlo si la regeneracion falla.
    ///
    /// El turno puede traer mensajes de asistente y de herramienta mezclados:
    /// todo lo posterior al ultimo mensaje del usuario forma parte de la
    /// respuesta que se esta regenerando. Si no hay nada que descartar (sin
    /// usuario o sin respuesta todavia) el historial queda intacto.
    @discardableResult
    public mutating func descartarUltimoTurno() -> [ChatMessage] {
        guard let indice = mensajes.lastIndex(where: { $0.rol == .usuario }),
              indice + 1 < mensajes.count
        else {
            return []
        }

        let descartados = Array(mensajes.suffix(from: indice + 1))
        mensajes.removeLast(descartados.count)
        return descartados
    }
}
