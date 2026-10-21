import Foundation

/// Cliente para la API de mensajes de Anthropic.
///
/// Diferencias que obligan a un cliente aparte: la clave va en otra cabecera,
/// hace falta una version de API, el prompt de sistema no es un mensaje mas y
/// los resultados de herramientas se devuelven como bloques dentro de un
/// mensaje de usuario.
public final class AnthropicClient: ChatEngine {
    private let transporte: HTTPStreaming
    private let config: ProviderConfig
    private let clave: String
    private let maxTokens: Int

    public init(
        transporte: HTTPStreaming,
        config: ProviderConfig,
        clave: String,
        maxTokens: Int = 4096
    ) {
        self.transporte = transporte
        self.config = config
        self.clave = clave
        self.maxTokens = maxTokens
    }

    public func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)? = nil
    ) async throws -> RespuestaModelo {
        let peticion = try construirPeticion(mensajes: mensajes, herramientas: herramientas)

        let stream = try await Reintento.conEspera {
            try await self.transporte.abrirStream(peticion)
        }

        var parser = SSEParser()
        var texto = ""
        var bloques: [Int: BloqueHerramienta] = [:]

        for try await trozo in stream {
            for evento in parser.consumir(trozo) {
                if procesar(evento: evento, texto: &texto, bloques: &bloques, alRecibirTexto: alRecibirTexto) {
                    return RespuestaModelo(texto: texto, toolCalls: cerrar(bloques))
                }
            }
        }

        for evento in parser.terminar() {
            if procesar(evento: evento, texto: &texto, bloques: &bloques, alRecibirTexto: alRecibirTexto) {
                return RespuestaModelo(texto: texto, toolCalls: cerrar(bloques))
            }
        }

        return RespuestaModelo(texto: texto, toolCalls: cerrar(bloques))
    }

    // MARK: - Peticion

    func construirPeticion(mensajes: [ChatMessage], herramientas: [ToolDefinition]) throws -> HTTPRequest {
        let endpoint = try config.endpointChat()
        let (sistema, mensajesAPI) = Self.traducir(mensajes)

        var cuerpo: [String: Any] = [
            "model": config.modelo,
            "max_tokens": maxTokens,
            "messages": mensajesAPI,
            "stream": true
        ]

        if let sistema, !sistema.isEmpty {
            cuerpo["system"] = sistema
        }

        if !herramientas.isEmpty {
            cuerpo["tools"] = herramientas.map { herramienta -> [String: Any] in
                [
                    "name": herramienta.nombre,
                    "description": herramienta.descripcion,
                    "input_schema": EsquemaJSON.diccionario(herramienta.parametros)
                ]
            }
        }

        let datos = try JSONSerialization.data(withJSONObject: cuerpo)

        return HTTPRequest(
            url: endpoint,
            metodo: "POST",
            cabeceras: [
                "x-api-key": clave,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
                "Accept": "text/event-stream"
            ],
            cuerpo: datos
        )
    }

    /// Traduce el historial al formato de Anthropic.
    ///
    /// Los resultados de herramientas se agrupan en un solo mensaje de usuario:
    /// si se mandan sueltos, la API rechaza dos mensajes de usuario seguidos.
    static func traducir(_ mensajes: [ChatMessage]) -> (sistema: String?, mensajes: [[String: Any]]) {
        var sistema: [String] = []
        var salida: [[String: Any]] = []
        var resultadosPendientes: [[String: Any]] = []

        func volcarResultados() {
            guard !resultadosPendientes.isEmpty else { return }
            salida.append(["role": "user", "content": resultadosPendientes])
            resultadosPendientes = []
        }

        for mensaje in mensajes {
            switch mensaje.rol {
            case .sistema:
                volcarResultados()
                sistema.append(mensaje.texto)

            case .usuario:
                volcarResultados()
                salida.append(["role": "user", "content": mensaje.texto])

            case .asistente:
                volcarResultados()
                var bloques: [[String: Any]] = []
                if !mensaje.texto.isEmpty {
                    bloques.append(["type": "text", "text": mensaje.texto])
                }
                for llamada in mensaje.toolCalls {
                    let entrada = (try? JSONSerialization.jsonObject(
                        with: Data(llamada.argumentos.utf8)
                    )) as? [String: Any] ?? [:]
                    bloques.append([
                        "type": "tool_use",
                        "id": llamada.id,
                        "name": llamada.nombre,
                        "input": entrada
                    ])
                }
                if bloques.isEmpty {
                    bloques.append(["type": "text", "text": ""])
                }
                salida.append(["role": "assistant", "content": bloques])

            case .herramienta:
                resultadosPendientes.append([
                    "type": "tool_result",
                    "tool_use_id": mensaje.toolCallId ?? "",
                    "content": mensaje.texto
                ])
            }
        }

        volcarResultados()

        let texto = sistema.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (texto.isEmpty ? nil : texto, salida)
    }

    // MARK: - Respuesta

    struct BloqueHerramienta {
        var id: String = ""
        var nombre: String = ""
        var json: String = ""
    }

    private func procesar(
        evento: SSEEvent,
        texto: inout String,
        bloques: inout [Int: BloqueHerramienta],
        alRecibirTexto: ((String) -> Void)?
    ) -> Bool {
        let datos = evento.datos.trimmingCharacters(in: .whitespacesAndNewlines)
        if datos.isEmpty { return false }

        guard let objeto = ChatCompletionsClient.objetoJSON(datos) else { return false }
        let tipo = (objeto["type"] as? String) ?? evento.evento ?? ""

        switch tipo {
        case "content_block_start":
            let indice = (objeto["index"] as? NSNumber)?.intValue ?? 0
            if let bloque = objeto["content_block"] as? [String: Any],
               (bloque["type"] as? String) == "tool_use" {
                bloques[indice] = BloqueHerramienta(
                    id: bloque["id"] as? String ?? "",
                    nombre: bloque["name"] as? String ?? "",
                    json: ""
                )
            }
            return false

        case "content_block_delta":
            let indice = (objeto["index"] as? NSNumber)?.intValue ?? 0
            guard let delta = objeto["delta"] as? [String: Any] else { return false }
            let tipoDelta = delta["type"] as? String

            if tipoDelta == "text_delta", let fragmento = delta["text"] as? String {
                texto += fragmento
                alRecibirTexto?(fragmento)
            } else if tipoDelta == "input_json_delta", let parcial = delta["partial_json"] as? String {
                var bloque = bloques[indice] ?? BloqueHerramienta()
                bloque.json += parcial
                bloques[indice] = bloque
            }
            return false

        case "message_stop":
            return true

        default:
            return false
        }
    }

    private func cerrar(_ bloques: [Int: BloqueHerramienta]) -> [ToolCall] {
        bloques.keys.sorted().compactMap { indice in
            guard let bloque = bloques[indice], !bloque.nombre.isEmpty else { return nil }
            let argumentos = bloque.json.isEmpty ? "{}" : bloque.json
            return ToolCall(id: bloque.id, nombre: bloque.nombre, argumentos: argumentos)
        }
    }
}
