import Foundation

/// Respaldo exportable de la configuracion (§4.8).
///
/// Incluye Memoria, skills, tabla de ventanas, proveedores con sus precios y el
/// tope global. NO incluye claves de API: `ProviderConfig` solo guarda el
/// nombre con el que la credencial vive en el llavero y `ServerConfig` guarda su
/// token fuera de la configuracion (`ServerConfig.tokenKeychain`), asi que
/// ninguno de esos valores puede acabar en el JSON.
///
/// Las ventanas viajan dentro del respaldo, pero al restaurar se devuelven
/// aparte porque la app las guarda en su propio `UserDefaults`, no en
/// `AppConfig`.
public struct RespaldoConfiguracion: Codable, Equatable {
    /// Entradas de la Memoria viva (MEM.1/D5).
    ///
    /// El respaldo viaja con la lista completa, no con un texto unico: los ids
    /// y las fechas tambien forman parte de lo que el dueno guardo.
    public var memoria: [EntradaMemoria]
    /// Biblioteca de skills locales.
    public var skills: [SkillLocal]
    /// Ventana de contexto por modelo, en tokens.
    public var ventanas: [String: Int]
    /// Proveedores con sus precios; sin claves.
    public var proveedores: [ProviderConfig]
    /// Tope global de aviso, en dolares.
    public var topeGlobalUSD: Double
    /// Version de este formato de respaldo, para poder migrarlo despues.
    ///
    /// La 2 guarda la Memoria como entradas; la 1 la guardaba como texto plano.
    public var versionFormato: Int

    public init(
        memoria: [EntradaMemoria] = [],
        skills: [SkillLocal] = [],
        ventanas: [String: Int] = [:],
        proveedores: [ProviderConfig] = [],
        topeGlobalUSD: Double,
        versionFormato: Int = 2
    ) {
        self.memoria = memoria
        self.skills = skills
        self.ventanas = ventanas
        self.proveedores = proveedores
        self.topeGlobalUSD = topeGlobalUSD
        self.versionFormato = versionFormato
    }

    private enum CodingKeys: String, CodingKey {
        case memoria
        case skills
        case ventanas
        case proveedores
        case topeGlobalUSD
        case versionFormato
    }

    /// Decodificacion tolerante con los respaldos anteriores a MEM.1.
    ///
    /// Un respaldo viejo guardaba `memoria` como texto plano. Al importarlo se
    /// convierte en UNA sola entrada con el texto completo, igual que la
    /// migracion de la configuracion: un respaldo no puede perder lo que el
    /// dueno tenia escrito. Un respaldo sin `versionFormato` se asume de la 1.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        if let entradas = try? contenedor.decode([EntradaMemoria].self, forKey: .memoria) {
            memoria = entradas
        } else if let texto = try? contenedor.decode(String.self, forKey: .memoria) {
            memoria = Memoria.entradasDesdeTextoLegado(texto)
        } else {
            memoria = []
        }
        skills = try contenedor.decode([SkillLocal].self, forKey: .skills)
        ventanas = try contenedor.decode([String: Int].self, forKey: .ventanas)
        proveedores = try contenedor.decode([ProviderConfig].self, forKey: .proveedores)
        topeGlobalUSD = try contenedor.decode(Double.self, forKey: .topeGlobalUSD)
        versionFormato = try contenedor.decodeIfPresent(Int.self, forKey: .versionFormato) ?? 1
    }

    /// Construye el respaldo a partir de la configuracion y la tabla de ventanas.
    ///
    /// El tope guardado puede ser nil (nunca se fijo): se exporta el efectivo,
    /// que es el mismo que la app aplica y muestra.
    public static func hacerRespaldo(
        config: AppConfig,
        ventanas: [String: Int]
    ) -> RespaldoConfiguracion {
        RespaldoConfiguracion(
            memoria: config.memoria,
            skills: config.skills,
            ventanas: ventanas,
            proveedores: config.proveedores,
            topeGlobalUSD: config.topeAvisoCostoEfectivo
        )
    }

    /// Aplica el respaldo sobre una configuracion y devuelve la resultante.
    ///
    /// Restaura Memoria, skills, proveedores y tope. El resto de la
    /// configuracion (servidor, proveedor activo, herramientas exentas) se
    /// conserva tal como estaba, salvo que el proveedor activo ya no exista en
    /// el respaldo: en ese caso cae al primero disponible.
    ///
    /// Las ventanas no entran en `AppConfig`; se leen del respaldo con
    /// `ventanas(de:)` o se piden junto con la configuracion usando
    /// `aplicarConVentanas(_:sobre:)`.
    public static func aplicar(
        _ respaldo: RespaldoConfiguracion,
        sobre config: AppConfig
    ) -> AppConfig {
        var nueva = config
        nueva.memoria = respaldo.memoria
        nueva.skills = respaldo.skills
        nueva.proveedores = respaldo.proveedores
        nueva.topeAvisoCosto = respaldo.topeGlobalUSD

        if let activo = nueva.proveedorActivo,
           !nueva.proveedores.contains(where: { $0.id == activo }) {
            nueva.proveedorActivo = nueva.proveedores.first?.id
        }

        return nueva
    }

    /// Aplica el respaldo y devuelve tambien las ventanas para que la app las
    /// escriba en su `UserDefaults`.
    public static func aplicarConVentanas(
        _ respaldo: RespaldoConfiguracion,
        sobre config: AppConfig
    ) -> (config: AppConfig, ventanas: [String: Int]) {
        (aplicar(respaldo, sobre: config), respaldo.ventanas)
    }

    /// Ventanas del respaldo, separadas de la configuracion.
    public static func ventanas(de respaldo: RespaldoConfiguracion) -> [String: Int] {
        respaldo.ventanas
    }

    /// Serializa el respaldo con el mismo estilo que `AppConfig.json()`.
    public func json() throws -> Data {
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try codificador.encode(self)
    }

    /// Lee un respaldo exportado.
    public static func desde(json: Data) throws -> RespaldoConfiguracion {
        try JSONDecoder().decode(RespaldoConfiguracion.self, from: json)
    }
}
