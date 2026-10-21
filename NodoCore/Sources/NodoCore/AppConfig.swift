import Foundation

/// Configuracion de un servidor remoto que expone herramientas por MCP.
///
/// Existe desde la primera version aunque no se use todavia: cuando haya un
/// servidor, apuntar a el es pegar una URL, sin recompilar la app.
public struct ServerConfig: Codable, Equatable {
    public var nombre: String
    public var url: String
    public var activo: Bool

    public init(nombre: String = "Servidor", url: String = "", activo: Bool = false) {
        self.nombre = nombre
        self.url = url
        self.activo = activo
    }

    /// Clave del token en el Keychain. Es fija porque hay un solo servidor.
    public static let tokenKeychain = "servidor-mcp-token"

    /// Valida la direccion del servidor.
    ///
    /// Aqui no hay excepcion para http: el token viaja en una cabecera y el
    /// servidor esta fuera de la red local, asi que exigir https no es un lujo.
    public func validarURL() throws -> URL {
        let limpio = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { throw ErrorConfig.urlInvalida }
        guard let u = URL(string: limpio), let esquema = u.scheme?.lowercased(), esquema == "https" else {
            throw ErrorConfig.urlNoSegura
        }
        guard let host = u.host, !host.isEmpty else { throw ErrorConfig.urlInvalida }
        return u
    }

    public var estaConfigurado: Bool {
        activo && (try? validarURL()) != nil
    }
}

/// Configuracion completa de la app, exportable a JSON.
///
/// El JSON exportado **no contiene claves**: solo proveedores, modelo, prompt y
/// servidor. Importarlo en otro telefono deja las credenciales por introducir,
/// que es justo lo que se quiere al mover una configuracion entre dispositivos.
public struct AppConfig: Codable, Equatable {
    /// Version del formato, para poder migrar sin romper.
    public var version: Int
    public var proveedores: [ProviderConfig]
    public var proveedorActivo: UUID?
    public var systemPrompt: String
    public var servidor: ServerConfig

    public init(
        version: Int = 1,
        proveedores: [ProviderConfig] = [],
        proveedorActivo: UUID? = nil,
        systemPrompt: String = AppConfig.promptPorDefecto,
        servidor: ServerConfig = ServerConfig()
    ) {
        self.version = version
        self.proveedores = proveedores
        self.proveedorActivo = proveedorActivo
        self.systemPrompt = systemPrompt
        self.servidor = servidor
    }

    public static let promptPorDefecto = """
    Eres un asistente util y directo. Respondes en el idioma en que te hablan. \
    Cuando no sabes algo, lo dices en vez de inventarlo.
    """

    /// Configuracion inicial: un proveedor de ejemplo sin clave.
    public static func inicial() -> AppConfig {
        let proveedor = ProveedoresDeEjemplo.chatCompletions
        return AppConfig(
            proveedores: [proveedor],
            proveedorActivo: proveedor.id
        )
    }

    /// El proveedor seleccionado, si sigue existiendo.
    public var proveedorSeleccionado: ProviderConfig? {
        guard let id = proveedorActivo else { return proveedores.first }
        return proveedores.first { $0.id == id } ?? proveedores.first
    }

    public func json() throws -> Data {
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try codificador.encode(self)
    }

    public static func desde(json: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: json)
    }
}
