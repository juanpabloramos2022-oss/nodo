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
/// El JSON exportado **no contiene claves**: solo proveedores, modelo, prompt,
/// servidor, el tope de aviso, la lista de herramientas exentas, las skills y
/// los contadores de gasto. Importarlo en otro telefono deja las credenciales
/// por introducir, que es justo lo que se quiere al mover una configuracion
/// entre dispositivos.
public struct AppConfig: Codable, Equatable {
    /// Version del formato, para poder migrar sin romper.
    public var version: Int
    public var proveedores: [ProviderConfig]
    public var proveedorActivo: UUID?
    public var systemPrompt: String
    public var servidor: ServerConfig
    /// Tope de aviso por chat, en dolares estimados. nil usa el valor por
    /// defecto; 0 o negativo desactiva el aviso.
    public var topeAvisoCosto: Double?
    /// Herramientas que no piden aprobacion en modo Tarea, aunque tengan
    /// consecuencias. nil equivale a la lista vacia, que es el valor por
    /// defecto que manda la SPEC (§4.3).
    public var herramientasSinAprobacion: [String]?
    /// Biblioteca de skills locales (§4.4). Las configuraciones de la v0.2.0 no
    /// traen este campo y se leen como lista vacia.
    public var skills: [SkillLocal]
    /// Contadores globales de gasto (§3.5). Viven en la configuracion para
    /// sobrevivir al borrado de chats; las configuraciones viejas arrancan a
    /// cero.
    public var gasto: ContadoresGasto
    /// Libro de gasto por dia y por mes (COST.2). Las configuraciones
    /// guardadas antes de existir el libro se leen con el libro vacio.
    public var usoApp: UsoApp

    public init(
        version: Int = 1,
        proveedores: [ProviderConfig] = [],
        proveedorActivo: UUID? = nil,
        systemPrompt: String = AppConfig.promptPorDefecto,
        servidor: ServerConfig = ServerConfig(),
        topeAvisoCosto: Double? = nil,
        herramientasSinAprobacion: [String]? = nil,
        skills: [SkillLocal] = [],
        gasto: ContadoresGasto = ContadoresGasto(),
        usoApp: UsoApp = UsoApp()
    ) {
        self.version = version
        self.proveedores = proveedores
        self.proveedorActivo = proveedorActivo
        self.systemPrompt = systemPrompt
        self.servidor = servidor
        self.topeAvisoCosto = topeAvisoCosto
        self.herramientasSinAprobacion = herramientasSinAprobacion
        self.skills = skills
        self.gasto = gasto
        self.usoApp = usoApp
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case proveedores
        case proveedorActivo
        case systemPrompt
        case servidor
        case topeAvisoCosto
        case herramientasSinAprobacion
        case skills
        case gasto
        case usoApp
    }

    /// Decodificacion tolerante con las configuraciones anteriores a la Fase 4.
    ///
    /// La v0.2.0 no tenia skills ni contadores de gasto. El Decodable
    /// sintetizado exigiria esas claves y dejaria de abrir la configuracion
    /// entera, asi que se leen como opcionales con su valor por defecto.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        version = try contenedor.decode(Int.self, forKey: .version)
        proveedores = try contenedor.decode([ProviderConfig].self, forKey: .proveedores)
        proveedorActivo = try contenedor.decodeIfPresent(UUID.self, forKey: .proveedorActivo)
        systemPrompt = try contenedor.decode(String.self, forKey: .systemPrompt)
        servidor = try contenedor.decode(ServerConfig.self, forKey: .servidor)
        topeAvisoCosto = try contenedor.decodeIfPresent(Double.self, forKey: .topeAvisoCosto)
        herramientasSinAprobacion = try contenedor.decodeIfPresent(
            [String].self,
            forKey: .herramientasSinAprobacion
        )
        skills = try contenedor.decodeIfPresent([SkillLocal].self, forKey: .skills) ?? []
        gasto = try contenedor.decodeIfPresent(ContadoresGasto.self, forKey: .gasto)
            ?? ContadoresGasto()
        usoApp = try contenedor.decodeIfPresent(UsoApp.self, forKey: .usoApp)
            ?? UsoApp()
    }

    /// Tope que se aplica de verdad: el guardado o un dolar si nunca se fijo.
    public var topeAvisoCostoEfectivo: Double {
        topeAvisoCosto ?? 1.00
    }

    public static let promptPorDefecto = """
    Eres un asistente util y directo. Respondes en el idioma en que te hablan. \
    Cuando no sabes algo, lo dices en vez de inventarlo.
    """

    /// Configuracion inicial: el preset de fabrica de InferHub, sin clave.
    ///
    /// Es una decision cerrada de la SPEC (§3.6): en una instalacion limpia
    /// pablo solo pega su clave y ya, sin reescribir proveedor, URL ni modelos.
    /// Los ids son literales fijos para que el estado inicial sea determinista
    /// en tests y capturas. La clave no vive aqui: ProviderConfig solo guarda el
    /// nombre con el que la credencial vive en el Keychain, asi que el preset
    /// nace sin claves por construccion.
    public static func inicial() -> AppConfig {
        let nombre = "InferHub"
        let baseURL = "https://api.inferhub.dev/v1"

        let deepseek = ProviderConfig(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            nombre: nombre,
            protocolo: .chatCompletions,
            baseURL: baseURL,
            modelo: "combo/deepseek-v4-1-flash",
            precioEntradaPorMillon: 0.03,
            precioSalidaPorMillon: 0.12
        )
        let glm = ProviderConfig(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            nombre: nombre,
            protocolo: .chatCompletions,
            baseURL: baseURL,
            modelo: "combo/glm-5-3-flash",
            precioEntradaPorMillon: 0.03,
            precioSalidaPorMillon: 0.10
        )
        let sol = ProviderConfig(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            nombre: nombre,
            protocolo: .chatCompletions,
            baseURL: baseURL,
            modelo: "combo/gpt-6-1-sol",
            precioEntradaPorMillon: 0.6,
            precioSalidaPorMillon: 3
        )
        let astra = ProviderConfig(
            id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            nombre: nombre,
            protocolo: .chatCompletions,
            baseURL: baseURL,
            modelo: "combo/gpt-6-astra",
            precioEntradaPorMillon: 3,
            precioSalidaPorMillon: 15
        )

        return AppConfig(
            proveedores: [deepseek, glm, sol, astra],
            proveedorActivo: deepseek.id
        )
    }

    /// El proveedor seleccionado, si sigue existiendo.
    public var proveedorSeleccionado: ProviderConfig? {
        guard let id = proveedorActivo else { return proveedores.first }
        return proveedores.first { $0.id == id } ?? proveedores.first
    }

    /// Los otros registros que comparten host con el proveedor dado.
    ///
    /// Es la regla pura de la clave compartida (§3.7): el mismo dominio sirve
    /// para todos sus combos, aunque cambie la ruta o el puerto. La app la usara
    /// al guardar una clave para propagarla solo a los companeros que no tengan
    /// una propia; aqui solo se decide quien empareja. Una URL sin host valido
    /// no empareja con nada, ni siquiera consigo misma.
    public func companerosDeHost(de proveedor: ProviderConfig) -> [ProviderConfig] {
        guard let host = AppConfig.hostNormalizado(proveedor.baseURL) else { return [] }
        return proveedores.filter { otro in
            otro.id != proveedor.id && AppConfig.hostNormalizado(otro.baseURL) == host
        }
    }

    /// Host comparable: sin mayusculas y sin puerto (URL.host ya lo excluye).
    private static func hostNormalizado(_ baseURL: String) -> String? {
        let limpio = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty,
              let url = URL(string: limpio),
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return host.lowercased()
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
