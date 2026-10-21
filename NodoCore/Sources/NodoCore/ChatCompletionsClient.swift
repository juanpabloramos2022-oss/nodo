import Foundation

/// Cliente para el dialecto de chat completions, que es el que hablan casi
/// todos los proveedores del mercado ademas del original.
public final class ChatCompletionsClient: ChatEngine {
    private let transporte: HTTPStreaming
    private let config: ProviderConfig
    private let clave: String

    public init(transporte: HTTPStreaming, config: ProviderConfig, clave: String) {
        self.transporte = transporte
        self.config = config
        self.clave = clave
    }

    public func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)? = nil
    ) async throws -> RespuestaModelo {
        let peticion = try construirPeticion(mensajes: mensajes, herramientas: herramientas)
        let stream = try await transporte.abrirStream(peticion)

        var parser = SSEParser()
        var texto = ""
        var acumuladores: [Int: AcumuladorToolCall] = [:]

        for try await trozo in stream {
            for evento in parser.consumir(trozo) {
                if let resultado = procesar(evento: evento, texto: &texto, acumuladores: &acumuladores, alRecibirTexto: alRecibirTexto) {
                    return resultado
                }
            }
        }

        for evento in parser.terminar() {
            if let resultado = procesar(evento: evento, texto: &texto, acumuladores: &acumuladores, alRecibirTexto: alRecibirTexto) {
                return resultado
            }
        }

        return RespuestaModelo(texto: texto, toolCalls: cerrar(acumuladores))
    }

    // MARK: - Peticion

    func construirPeticion(mensajes: [ChatMessage], herramientas: [ToolDefinition]) throws -> HTTPRequest {
        let endpoint = try config.endpointChat()

        var cuerpo: [String: Any] = [
            "model": config.modelo,
            "messages": mensajes.map(Self.diccionarioMensaje),
            "stream": true
        ]

        if !herramientas.isEmpty {
            cuerpo["tools"] = herramientas.map { herramienta -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": herramienta.nombre,
                        "description": herramienta.descripcion,
                        "parameters": EsquemaJSON.diccionario(herramienta.parametros)
                    ]
                ]
            }
        }

        let datos = try JSONSerialization.data(withJSONObject: cuerpo)

        return HTTPRequest(
            url: endpoint,
            metodo: "POST",
            cabeceras: [
                "Authorization": "Bearer \(clave)",
                "Content-Type": "application/json",
                "Accept": "text/event-stream"
            ],
            cuerpo: datos
        )
    }

    static func diccionarioMensaje(_ mensaje: ChatMessage) -> [String: Any] {
        switch mensaje.rol {
        case .sistema:
            return ["role": "system", "content": mensaje.texto]

        case .usuario:
            return ["role": "user", "content": mensaje.texto]

        case .asistente:
            var diccionario: [String: Any] = ["role": "assistant", "content": mensaje.texto]
            if !mensaje.toolCalls.isEmpty {
                diccionario["tool_calls"] = mensaje.toolCalls.map { llamada -> [String: Any] in
                    [
                        "id": llamada.id,
                        "type": "function",
                        "function": [
                            "name": llamada.nombre,
                            "arguments": llamada.argumentos
                        ]
                    ]
                }
            }
            return diccionario

        case .herramienta:
            return [
                "role": "tool",
                "tool_call_id": mensaje.toolCallId ?? "",
                "content": mensaje.texto
            ]
        }
    }

    // MARK: - Respuesta

    struct AcumuladorToolCall {
        var id: String = ""
        var nombre: String = ""
        var argumentos: String = ""
    }

    private func procesar(
        evento: SSEEvent,
        texto: inout String,
        acumuladores: inout [Int: AcumuladorToolCall],
        alRecibirTexto: ((String) -> Void)?
    ) -> RespuestaModelo? {
        let datos = evento.datos.trimmingCharacters(in: .whitespacesAndNewlines)
        if datos.isEmpty { return nil }
        if datos == "[DONE]" {
            return RespuestaModelo(texto: texto, toolCalls: cerrar(acumuladores))
        }

        guard let objeto = Self.objetoJSON(datos),
              let opciones = objeto["choices"] as? [[String: Any]],
              let primera = opciones.first
        else {
            // Un trozo ilegible no rompe el stream: se ignora. Pasa con
            // latidos y con servidores que mandan lineas de mas.
            return nil
        }

        if let delta = primera["delta"] as? [String: Any] {
            if let contenido = delta["content"] as? String, !contenido.isEmpty {
                texto += contenido
                alRecibirTexto?(contenido)
            }

            if let llamadas = delta["tool_calls"] as? [[String: Any]] {
                for llamada in llamadas {
                    let indice = (llamada["index"] as? NSNumber)?.intValue ?? 0
                    var acumulador = acumuladores[indice] ?? AcumuladorToolCall()
                    if let id = llamada["id"] as? String, !id.isEmpty {
                        acumulador.id = id
                    }
                    if let funcion = llamada["function"] as? [String: Any] {
                        if let nombre = funcion["name"] as? String, !nombre.isEmpty {
                            acumulador.nombre += nombre
                        }
                        if let argumentos = funcion["arguments"] as? String {
                            acumulador.argumentos += argumentos
                        }
                    }
                    acumuladores[indice] = acumulador
                }
            }
        }

        return nil
    }

    private func cerrar(_ acumuladores: [Int: AcumuladorToolCall]) -> [ToolCall] {
        acumuladores.keys.sorted().compactMap { indice in
            guard let acumulador = acumuladores[indice], !acumulador.nombre.isEmpty else {
                return nil
            }
            let id = acumulador.id.isEmpty ? "llamada-\(indice)" : acumulador.id
            let argumentos = acumulador.argumentos.isEmpty ? "{}" : acumulador.argumentos
            return ToolCall(id: id, nombre: acumulador.nombre, argumentos: argumentos)
        }
    }

    static func objetoJSON(_ texto: String) -> [String: Any]? {
        guard let datos = texto.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any]
    }
}
