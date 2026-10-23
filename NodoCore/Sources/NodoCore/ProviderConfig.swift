import Foundation

/// Errores de configuracion, con mensajes pensados para mostrarse tal cual.
public enum ErrorConfig: Error, Equatable, LocalizedError {
    case urlInvalida
    case urlNoSegura
    case modeloVacio
    case claveVacia
    case nombreVacio

    public var errorDescription: String? {
        switch self {
        case .urlInvalida:
            return "La direccion no es valida."
        case .urlNoSegura:
            return "La direccion debe empezar por https."
        case .modeloVacio:
            return "Falta el nombre del modelo."
        case .claveVacia:
            return "Falta la clave de API."
        case .nombreVacio:
            return "Falta el nombre del proveedor."
        }
    }
}

/// Que dialecto habla el proveedor.
///
/// Solo hay dos porque son los dos que existen de verdad en el mercado: el
/// formato de chat completions, que copiaron casi todos, y el de Anthropic.
public enum ProtocoloProveedor: String, Codable, CaseIterable, Identifiable {
    case chatCompletions
    case anthropic

    public var id: String { rawValue }

    public var etiqueta: String {
        switch self {
        case .chatCompletions: return "Compatible (chat completions)"
        case .anthropic: return "Anthropic"
        }
    }
}

/// Configuracion de un proveedor de modelos.
///
/// No contiene la clave: solo el nombre con el que vive en el Keychain. Asi un
/// volcado de la configuracion, un registro o un archivo exportado no filtran
/// nunca una credencial.
public struct ProviderConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var nombre: String
    public var protocolo: ProtocoloProveedor
    public var baseURL: String
    public var modelo: String
    /// Precio-tope de entrada por millon de tokens. nil = sin precio
    /// configurado, y entonces no se estima costo.
    public var precioEntradaPorMillon: Double?
    /// Precio-tope de salida por millon de tokens.
    public var precioSalidaPorMillon: Double?

    public init(
        id: UUID = UUID(),
        nombre: String,
        protocolo: ProtocoloProveedor = .chatCompletions,
        baseURL: String,
        modelo: String,
        precioEntradaPorMillon: Double? = nil,
        precioSalidaPorMillon: Double? = nil
    ) {
        self.id = id
        self.nombre = nombre
        self.protocolo = protocolo
        self.baseURL = baseURL
        self.modelo = modelo
        self.precioEntradaPorMillon = precioEntradaPorMillon
        self.precioSalidaPorMillon = precioSalidaPorMillon
    }

    /// Clave con la que la credencial vive en el Keychain.
    public var claveKeychain: String {
        "proveedor-\(id.uuidString)"
    }

    /// Comprueba que la configuracion se puede usar y devuelve la URL ya
    /// normalizada.
    ///
    /// Se permite http solo para direcciones locales, que es el caso de un
    /// servidor de modelos corriendo en la misma red; para todo lo demas se
    /// exige https porque la clave viaja en una cabecera.
    public func validarURL() throws -> URL {
        let limpio = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { throw ErrorConfig.urlInvalida }
        guard let url = URL(string: limpio), let esquema = url.scheme?.lowercased() else {
            throw ErrorConfig.urlInvalida
        }
        guard let host = url.host, !host.isEmpty else { throw ErrorConfig.urlInvalida }

        let esLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        if esquema == "http" && !esLocal { throw ErrorConfig.urlNoSegura }
        if esquema != "http" && esquema != "https" { throw ErrorConfig.urlInvalida }

        return url
    }

    /// Valida la configuracion completa. La clave se comprueba aparte porque no
    /// vive en este struct.
    public func validar() throws {
        if nombre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ErrorConfig.nombreVacio
        }
        if modelo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ErrorConfig.modeloVacio
        }
        _ = try validarURL()
    }

    /// Ruta del endpoint de chat, unida a la base sin duplicar barras.
    public func endpointChat() throws -> URL {
        let base = try validarURL()
        let sufijo: String
        switch protocolo {
        case .chatCompletions: sufijo = "chat/completions"
        case .anthropic: sufijo = "v1/messages"
        }
        var texto = base.absoluteString
        while texto.hasSuffix("/") { texto.removeLast() }
        guard let final = URL(string: texto + "/" + sufijo) else {
            throw ErrorConfig.urlInvalida
        }
        return final
    }
}

/// Un proveedor de ejemplo para que la app no arranque vacia.
public enum ProveedoresDeEjemplo {
    public static let chatCompletions = ProviderConfig(
        nombre: "Compatible",
        protocolo: .chatCompletions,
        baseURL: "https://api.deepseek.com/v1",
        modelo: "deepseek-chat"
    )

    public static let anthropic = ProviderConfig(
        nombre: "Anthropic",
        protocolo: .anthropic,
        baseURL: "https://api.anthropic.com",
        modelo: "claude-sonnet-4-5"
    )
}
