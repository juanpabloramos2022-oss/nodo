import Foundation

/// Una peticion HTTP ya montada, independiente de la libreria de red.
///
/// Se abstrae la red para poder probar la logica sin conexion y, sobre todo,
/// para poder compilar y ejecutar las pruebas en Windows, donde no existe el
/// mismo URLSession que en iOS.
public struct HTTPRequest: Equatable {
    public var url: URL
    public var metodo: String
    public var cabeceras: [String: String]
    public var cuerpo: Data?

    public init(url: URL, metodo: String = "POST", cabeceras: [String: String] = [:], cuerpo: Data? = nil) {
        self.url = url
        self.metodo = metodo
        self.cabeceras = cabeceras
        self.cuerpo = cuerpo
    }
}

/// Respuesta completa, sin streaming.
public struct HTTPRespuesta: Equatable {
    public var estado: Int
    public var cabeceras: [String: String]
    public var cuerpo: Data

    public init(estado: Int, cabeceras: [String: String] = [:], cuerpo: Data = Data()) {
        self.estado = estado
        self.cabeceras = cabeceras
        self.cuerpo = cuerpo
    }

    /// Cabecera por nombre, sin distinguir mayusculas.
    public func cabecera(_ nombre: String) -> String? {
        for (clave, valor) in cabeceras where clave.lowercased() == nombre.lowercased() {
            return valor
        }
        return nil
    }

    public var texto: String {
        String(data: cuerpo, encoding: .utf8) ?? ""
    }
}

/// Transporte que entrega la respuesta por trozos.
public protocol HTTPStreaming {
    /// Devuelve los trozos de la respuesta tal como llegan.
    ///
    /// Si el servidor responde con un error, lanza antes de devolver el stream,
    /// para no tener que comprobar el estado dentro del bucle.
    func abrirStream(_ peticion: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error>
}

/// Transporte de peticion y respuesta completas.
public protocol HTTPUnary {
    func enviar(_ peticion: HTTPRequest) async throws -> HTTPRespuesta
}

/// Errores de red y de la API, con mensajes que se pueden mostrar tal cual.
public enum ErrorAPI: Error, Equatable, LocalizedError {
    case noAutorizado(Int, String)
    case limiteDeTasa(Int, String)
    case servidorSaturado(Int, String)
    case errorDelServidor(Int, String)
    case respuestaInvalida(String)
    case red(String)
    case cancelado

    public var errorDescription: String? {
        switch self {
        case let .noAutorizado(codigo, detalle):
            return "La clave no es valida o ha caducado (\(codigo)). \(detalle)"
        case let .limiteDeTasa(codigo, detalle):
            return "Demasiadas peticiones (\(codigo)). Espera un momento. \(detalle)"
        case let .servidorSaturado(codigo, detalle):
            return "El servidor esta saturado (\(codigo)). \(detalle)"
        case let .errorDelServidor(codigo, detalle):
            return "El servidor respondio \(codigo). \(detalle)"
        case let .respuestaInvalida(detalle):
            return "Respuesta inesperada: \(detalle)"
        case let .red(detalle):
            return "Fallo de red: \(detalle)"
        case .cancelado:
            return "Cancelado."
        }
    }

    /// Traduce un codigo de estado HTTP al error correspondiente.
    ///
    /// Se centraliza para que los dos clientes clasifiquen igual y la interfaz
    /// pueda decidir si merece la pena reintentar.
    public static func desdeEstado(_ estado: Int, cuerpo: String) -> ErrorAPI? {
        let detalle = Self.mensajeDeError(cuerpo)
        switch estado {
        case 200..<300:
            return nil
        case 401, 403:
            return .noAutorizado(estado, detalle)
        case 429:
            return .limiteDeTasa(estado, detalle)
        case 529, 503, 502:
            return .servidorSaturado(estado, detalle)
        default:
            return .errorDelServidor(estado, detalle)
        }
    }

    /// Saca el mensaje util de un cuerpo de error, que puede venir en varios
    /// formatos segun el proveedor.
    public static func mensajeDeError(_ cuerpo: String) -> String {
        let recortado = cuerpo.trimmingCharacters(in: .whitespacesAndNewlines)
        if recortado.isEmpty { return "" }

        if let datos = recortado.data(using: .utf8),
           let objeto = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] {
            if let error = objeto["error"] as? [String: Any],
               let mensaje = error["message"] as? String {
                return mensaje
            }
            if let mensaje = objeto["message"] as? String {
                return mensaje
            }
            if let error = objeto["error"] as? String {
                return error
            }
        }

        return String(recortado.prefix(300))
    }
}

/// Reintenta una operacion con espera creciente.
///
/// Solo se usa para saturacion del servidor, que es el unico error donde
/// reintentar sirve de algo. Reintentar un 401 solo gasta cuota.
public enum Reintento {
    public static func conEspera<T>(
        intentos: Int = 3,
        esperaInicial: Duration = .milliseconds(500),
        operacion: () async throws -> T
    ) async throws -> T {
        var espera = esperaInicial
        var ultimoError: Error?

        for intento in 0..<max(1, intentos) {
            do {
                return try await operacion()
            } catch let error as ErrorAPI {
                switch error {
                case .servidorSaturado:
                    ultimoError = error
                    if intento < intentos - 1 {
                        try? await Task.sleep(for: espera)
                        espera = espera * 2
                    }
                default:
                    throw error
                }
            }
        }

        throw ultimoError ?? ErrorAPI.respuestaInvalida("sin respuesta")
    }
}
