import Foundation

/// Informacion que devuelve un servidor MCP al saludar.
public struct InfoServidor: Equatable {
    public var nombre: String
    public var version: String
    public var protocolo: String

    public init(nombre: String, version: String, protocolo: String) {
        self.nombre = nombre
        self.version = version
        self.protocolo = protocolo
    }
}

/// Errores propios del protocolo MCP.
public enum ErrorMCP: Error, Equatable, LocalizedError {
    case servidorNoConfigurado
    case respuestaSinResultado(String)
    case errorDelServidor(String)
    case sesionRechazada

    public var errorDescription: String? {
        switch self {
        case .servidorNoConfigurado:
            return "No hay ningun servidor configurado."
        case let .respuestaSinResultado(detalle):
            return "El servidor no devolvio resultado: \(detalle)"
        case let .errorDelServidor(detalle):
            return "El servidor devolvio un error: \(detalle)"
        case .sesionRechazada:
            return "El servidor rechazo la sesion."
        }
    }
}

/// Cliente de MCP sobre HTTP.
///
/// Se habla con cualquier servidor que cumpla el protocolo, no solo con uno
/// concreto: la app no sabe nada de que herramientas hay al otro lado hasta que
/// se las cuenta el servidor. Asi, cambiar de servidor es cambiar una URL.
public final class MCPClient {
    private let transporte: HTTPUnary
    private let url: URL
    private let token: String?
    private var sesion: String?
    private var siguienteId = 1
    private let versionProtocolo = "2025-06-18"

    public init(transporte: HTTPUnary, config: ServerConfig, token: String?) throws {
        guard config.estaConfigurado || !config.url.isEmpty else {
            throw ErrorMCP.servidorNoConfigurado
        }
        self.transporte = transporte
        self.url = try config.validarURL()
        self.token = token
    }

    /// Saluda al servidor y devuelve con quien estamos hablando.
    public func inicializar() async throws -> InfoServidor {
        let resultado = try await enviarRPC(
            metodo: "initialize",
            parametros: [
                "protocolVersion": versionProtocolo,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "Nodo",
                    "version": NodoVersion.version
                ]
            ]
        )

        // La notificacion de que ya estamos listos no espera respuesta; si
        // falla no es grave, muchos servidores la ignoran.
        await notificar(metodo: "notifications/initialized", parametros: [:])

        let info = resultado["serverInfo"] as? [String: Any] ?? [:]
        return InfoServidor(
            nombre: info["name"] as? String ?? "servidor",
            version: info["version"] as? String ?? "",
            protocolo: resultado["protocolVersion"] as? String ?? versionProtocolo
        )
    }

    /// Las herramientas que ofrece el servidor, ya traducidas al formato de la
    /// app.
    public func listarHerramientas() async throws -> [ToolDefinition] {
        let resultado = try await enviarRPC(metodo: "tools/list", parametros: [:])
        let lista = resultado["tools"] as? [[String: Any]] ?? []

        return lista.compactMap { herramienta in
            guard let nombre = herramienta["name"] as? String else { return nil }
            let descripcion = herramienta["description"] as? String ?? ""
            let esquema = herramienta["inputSchema"] as? [String: Any]
            return ToolDefinition(
                nombre: nombre,
                descripcion: descripcion,
                parametros: Self.esquema(desde: esquema)
            )
        }
    }

    /// Ejecuta una herramienta del servidor y devuelve su texto.
    public func llamar(nombre: String, argumentos: String) async throws -> String {
        let valores = (try? Argumentos.diccionario(argumentos)) ?? [:]

        let resultado = try await enviarRPC(
            metodo: "tools/call",
            parametros: [
                "name": nombre,
                "arguments": valores
            ]
        )

        // Un fallo de la herramienta viene marcado; se devuelve como texto para
        // que el modelo lo lea y decida.
        let esError = (resultado["isError"] as? Bool) ?? false

        let bloques = resultado["content"] as? [[String: Any]] ?? []
        let textos = bloques.compactMap { $0["text"] as? String }
        let cuerpo = textos.isEmpty ? "La herramienta no devolvio texto." : textos.joined(separator: "\n")

        return esError ? "Error de la herramienta: \(cuerpo)" : cuerpo
    }

    /// Prueba de conexion completa: saluda y lista herramientas.
    public func probar() async throws -> (info: InfoServidor, herramientas: [ToolDefinition]) {
        let info = try await inicializar()
        let herramientas = try await listarHerramientas()
        return (info, herramientas)
    }

    // MARK: - Transporte

    private func enviarRPC(metodo: String, parametros: [String: Any]) async throws -> [String: Any] {
        var cuerpo: [String: Any] = [
            "jsonrpc": "2.0",
            "id": siguienteId,
            "method": metodo,
            "params": parametros
        ]
        siguienteId += 1

        let respuesta = try await enviar(cuerpo)

        if let error = ErrorAPI.desdeEstado(respuesta.estado, cuerpo: respuesta.texto) {
            throw error
        }

        let objeto = Self.objetoJSON(respuesta)

        if let error = objeto["error"] as? [String: Any] {
            let mensaje = error["message"] as? String ?? "error sin mensaje"
            throw ErrorMCP.errorDelServidor(mensaje)
        }

        guard let resultado = objeto["result"] as? [String: Any] else {
            throw ErrorMCP.respuestaSinResultado(respuesta.texto.prefix(200).description)
        }

        return resultado
    }

    private func notificar(metodo: String, parametros: [String: Any]) async {
        let cuerpo: [String: Any] = [
            "jsonrpc": "2.0",
            "method": metodo,
            "params": parametros
        ]
        _ = try? await enviar(cuerpo)
    }

    private func enviar(_ cuerpo: [String: Any]) async throws -> HTTPRespuesta {
        var cabeceras: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream"
        ]

        if let token, !token.isEmpty {
            cabeceras["Authorization"] = "Bearer \(token)"
        }
        if let sesion {
            cabeceras["Mcp-Session-Id"] = sesion
        }

        let datos = try JSONSerialization.data(withJSONObject: cuerpo)
        let respuesta = try await transporte.enviar(
            HTTPRequest(url: url, metodo: "POST", cabeceras: cabeceras, cuerpo: datos)
        )

        // El servidor puede asignar sesion en la primera respuesta y exigirla
        // despues. Se guarda en cuanto aparece.
        if let nueva = respuesta.cabecera("Mcp-Session-Id"), !nueva.isEmpty {
            sesion = nueva
        }

        return respuesta
    }

    // MARK: - Ayudas

    /// Extrae el objeto JSON de una respuesta, venga como JSON plano o como
    /// evento SSE (que es lo que devuelven muchos servidores).
    static func objetoJSON(_ respuesta: HTTPRespuesta) -> [String: Any] {
        let tipo = (respuesta.cabecera("Content-Type") ?? "").lowercased()
        let texto = respuesta.texto

        if tipo.contains("text/event-stream") || texto.hasPrefix("event:") || texto.hasPrefix("data:") {
            var parser = SSEParser()
            var eventos = parser.consumir(texto)
            eventos += parser.terminar()
            for evento in eventos.reversed() {
                if let objeto = ChatCompletionsClient.objetoJSON(evento.datos) {
                    return objeto
                }
            }
        }

        return ChatCompletionsClient.objetoJSON(texto) ?? [:]
    }

    static func esquema(desde diccionario: [String: Any]?) -> JSONSchema {
        guard let diccionario else { return JSONSchema() }

        var propiedades: [String: JSONSchema.Propiedad] = [:]
        if let crudas = diccionario["properties"] as? [String: Any] {
            for (nombre, valor) in crudas {
                guard let detalle = valor as? [String: Any] else { continue }
                propiedades[nombre] = JSONSchema.Propiedad(
                    tipo: detalle["type"] as? String ?? "string",
                    descripcion: detalle["description"] as? String ?? ""
                )
            }
        }

        return JSONSchema(
            propiedades: propiedades,
            requeridos: diccionario["required"] as? [String] ?? []
        )
    }
}

/// Adapta una herramienta remota al protocolo que usa el bucle.
public final class HerramientaMCP: Herramienta {
    private let cliente: MCPClient
    private let base: ToolDefinition

    public init(cliente: MCPClient, definicion: ToolDefinition) {
        self.cliente = cliente
        self.base = definicion
    }

    public var definicion: ToolDefinition { base }

    public func ejecutar(argumentos: String) async throws -> String {
        try await cliente.llamar(nombre: base.nombre, argumentos: argumentos)
    }
}
