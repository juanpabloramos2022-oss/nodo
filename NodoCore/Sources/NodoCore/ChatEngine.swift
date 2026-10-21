import Foundation

/// Lo que devuelve el modelo en un turno.
public struct RespuestaModelo: Equatable {
    public var texto: String
    public var toolCalls: [ToolCall]

    public init(texto: String, toolCalls: [ToolCall] = []) {
        self.texto = texto
        self.toolCalls = toolCalls
    }

    public var pideHerramientas: Bool { !toolCalls.isEmpty }
}

/// Un motor de chat: recibe el historial y devuelve el siguiente turno del
/// modelo.
///
/// Existe como protocolo para que el bucle de herramientas se pueda probar con
/// un motor falso, sin red y sin gastar cuota.
public protocol ChatEngine {
    /// Pide un turno.
    ///
    /// - Parameter alRecibirTexto: se llama con cada trozo de texto segun llega,
    ///   para que la interfaz pueda pintarlo en vivo. Al terminar, el texto
    ///   completo se devuelve igualmente en `RespuestaModelo`.
    func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)?
    ) async throws -> RespuestaModelo
}

/// Convierte un esquema tipado al diccionario que esperan las APIs.
enum EsquemaJSON {
    static func diccionario(_ esquema: JSONSchema) -> [String: Any] {
        var propiedades: [String: Any] = [:]
        for (nombre, propiedad) in esquema.propiedades {
            propiedades[nombre] = [
                "type": propiedad.tipo,
                "description": propiedad.descripcion
            ]
        }
        return [
            "type": esquema.tipo,
            "properties": propiedades,
            "required": esquema.requeridos
        ]
    }
}
