import Foundation

/// Version vigente del formato de respaldo total (BACK.1).
///
/// Se declara a nivel de archivo para que el manifiesto y el respaldo la lean
/// sin depender del orden en el que estan escritos los dos tipos.
public let respaldoFormatoActual = 2

/// Cuenta por seccion de un respaldo total (BACK.1).
///
/// POR QUE nombre y valor: el resumen que se ensena antes de reemplazar todo
/// tiene que ser legible, y un diccionario perderia el orden con el que el
/// dueno lee las secciones.
public struct ConteoSeccion: Identifiable, Equatable {
    public let id: String
    public let valor: Int

    public init(id: String, valor: Int) {
        self.id = id
        self.valor = valor
    }
}

/// Manifiesto del respaldo: version del formato y conteos por seccion.
///
/// POR QUE existe: al importar hay que poder decir que trae el archivo y,
/// despues de aplicarlo, comprobar que lo restaurado cuadra con lo anunciado.
/// Sin este contrato, un archivo a medias se aplicaria como si fuera completo.
public struct ManifiestoRespaldo: Codable, Equatable {
    /// Version del formato que describe este manifiesto.
    public var versionFormato: Int
    public var conversaciones: Int
    public var tareas: Int
    public var memoria: Int
    public var skills: Int
    public var proveedores: Int
    public var ventanas: Int
    public var diasDeGasto: Int
    public var mesesDeGasto: Int

    public init(
        versionFormato: Int = respaldoFormatoActual,
        conversaciones: Int = 0,
        tareas: Int = 0,
        memoria: Int = 0,
        skills: Int = 0,
        proveedores: Int = 0,
        ventanas: Int = 0,
        diasDeGasto: Int = 0,
        mesesDeGasto: Int = 0
    ) {
        self.versionFormato = versionFormato
        self.conversaciones = conversaciones
        self.tareas = tareas
        self.memoria = memoria
        self.skills = skills
        self.proveedores = proveedores
        self.ventanas = ventanas
        self.diasDeGasto = diasDeGasto
        self.mesesDeGasto = mesesDeGasto
    }

    /// Secciones legibles para el resumen previo al reemplazo.
    public var secciones: [ConteoSeccion] {
        [
            ConteoSeccion(id: "Conversaciones", valor: conversaciones),
            ConteoSeccion(id: "Tareas", valor: tareas),
            ConteoSeccion(id: "Entradas de Memoria", valor: memoria),
            ConteoSeccion(id: "Skills", valor: skills),
            ConteoSeccion(id: "Proveedores", valor: proveedores),
            ConteoSeccion(id: "Ventanas", valor: ventanas),
            ConteoSeccion(id: "Días de gasto", valor: diasDeGasto),
            ConteoSeccion(id: "Meses de gasto", valor: mesesDeGasto)
        ]
    }

    /// True si cada conteo coincide con el contenido real del respaldo.
    ///
    /// Se compara contra `RespaldoConfiguracion.conteos`, que se calcula del
    /// contenido y no de este manifiesto: asi un archivo manipulado se detecta.
    public func cuadraCon(_ respaldo: RespaldoConfiguracion) -> Bool {
        let real = respaldo.conteos
        return conversaciones == real.conversaciones
            && tareas == real.tareas
            && memoria == real.memoria
            && skills == real.skills
            && proveedores == real.proveedores
            && ventanas == real.ventanas
            && diasDeGasto == real.diasDeGasto
            && mesesDeGasto == real.mesesDeGasto
    }
}

/// El servidor MCP dentro del respaldo, SIN su token.
///
/// El token vive en el llavero (`ServerConfig.tokenKeychain`) y nunca entra al
/// archivo. Este struct guarda solo la fontaneria visible: nombre, URL y si
/// estaba activo. `desde(_:)` devuelve nil cuando no hay servidor configurado,
/// de modo que el campo MCP del respaldo queda vacio.
public struct RespaldoMCP: Codable, Equatable {
    public var nombre: String
    public var url: String
    public var activo: Bool

    public init(nombre: String = "Servidor", url: String = "", activo: Bool = false) {
        self.nombre = nombre
        self.url = url
        self.activo = activo
    }

    /// Solo se exporta si hay una URL escrita: un servidor sin direccion no
    /// esta configurado y su campo viaja vacio.
    public static func desde(_ servidor: ServerConfig) -> RespaldoMCP? {
        let limpia = servidor.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpia.isEmpty else { return nil }
        return RespaldoMCP(
            nombre: servidor.nombre,
            url: limpia,
            activo: servidor.activo
        )
    }

    /// Reconstruye la configuracion del servidor para restaurarla.
    public var servidor: ServerConfig {
        ServerConfig(nombre: nombre, url: url, activo: activo)
    }
}

/// Errores de validacion de un respaldo, con mensajes listos para mostrar.
public enum ErrorRespaldo: Error, Equatable, LocalizedError {
    case versionNoSoportada
    case manifiestoIncoherente
    case sinManifiesto
    case idsDuplicados
    case verificacionFallida

    public var errorDescription: String? {
        switch self {
        case .versionNoSoportada:
            return "El respaldo es de una versión que esta app no sabe leer."
        case .manifiestoIncoherente:
            return "El manifiesto del respaldo no cuadra con su contenido. No se cambió nada."
        case .sinManifiesto:
            return "El respaldo no trae manifiesto; no se puede reemplazar todo."
        case .idsDuplicados:
            return "El respaldo trae identificadores repetidos. No se cambió nada."
        case .verificacionFallida:
            return "El respaldo se aplicó, pero los conteos finales no cuadran. Revisa el estado."
        }
    }
}

/// Respaldo completo de Nodo (BACK.1), formato v2.
///
/// Incluye las conversaciones con sus mensajes (resumen compactado y sellos de
/// costo incluidos), las tareas con su libro de pasos, las entradas de Memoria,
/// las skills (tambien las de fabrica), los proveedores con sus precios, las
/// ventanas de contexto, el tope, los contadores y el libro de gasto, y el
/// campo MCP. NO incluye claves de API: `ProviderConfig` solo guarda el nombre
/// con el que la credencial vive en el llavero y `ServerConfig` guarda su token
/// fuera de la configuracion, asi que ningun valor de clave puede acabar en el
/// JSON.
///
/// El manifiesto viaja dentro del archivo y permite comprobar que lo anunciado
/// coincide con lo guardado; `validar()` lo exige cuando esta presente.
public struct RespaldoConfiguracion: Codable, Equatable {
    /// Version de este formato. La 2 suma el total: conversaciones, tareas,
    /// libro de gasto y MCP; la 1 solo guardaba la configuracion.
    public static let formatoActual = respaldoFormatoActual

    /// Entradas de la Memoria viva (MEM.1/D5).
    ///
    /// El respaldo viaja con la lista completa, no con un texto unico: los ids
    /// y las fechas tambien forman parte de lo que el dueno guardo.
    public var memoria: [EntradaMemoria]
    /// Biblioteca de skills locales, con las de fabrica del PACK incluidas.
    public var skills: [SkillLocal]
    /// Ventana de contexto por modelo, en tokens.
    public var ventanas: [String: Int]
    /// Proveedores con sus precios; sin claves.
    public var proveedores: [ProviderConfig]
    /// Tope global de aviso, en dolares.
    public var topeGlobalUSD: Double
    /// Version de este formato de respaldo, para poder migrarlo despues.
    public var versionFormato: Int

    /// Conversaciones completas: mensajes, resumen de /compact y sellos.
    public var conversaciones: [Conversation]
    /// Tareas con su plan y su libro de pasos.
    public var tareas: [Tarea]
    /// Proveedor activo, para que la restauracion deje el mismo seleccionado.
    public var proveedorActivo: UUID?
    /// Herramientas exentas de aprobacion en Modo Tarea.
    public var herramientasSinAprobacion: [String]?
    /// Version del pack de fabrica ya sembrada; evita resiembras al restaurar.
    public var packSkillsVersion: Int
    /// Contadores globales de gasto.
    public var gasto: ContadoresGasto
    /// Libro de gasto por dia y por mes (COST.2).
    public var usoApp: UsoApp
    /// Servidor MCP sin secretos; nil y por tanto vacio si no hay servidor.
    public var mcp: RespaldoMCP?
    /// Manifiesto con version y conteos. nil en los respaldos antiguos.
    public var manifiesto: ManifiestoRespaldo?

    public init(
        memoria: [EntradaMemoria] = [],
        skills: [SkillLocal] = [],
        ventanas: [String: Int] = [:],
        proveedores: [ProviderConfig] = [],
        topeGlobalUSD: Double,
        versionFormato: Int = respaldoFormatoActual,
        conversaciones: [Conversation] = [],
        tareas: [Tarea] = [],
        proveedorActivo: UUID? = nil,
        herramientasSinAprobacion: [String]? = nil,
        packSkillsVersion: Int = 0,
        gasto: ContadoresGasto = ContadoresGasto(),
        usoApp: UsoApp = UsoApp(),
        mcp: RespaldoMCP? = nil,
        manifiesto: ManifiestoRespaldo? = nil
    ) {
        self.memoria = memoria
        self.skills = skills
        self.ventanas = ventanas
        self.proveedores = proveedores
        self.topeGlobalUSD = topeGlobalUSD
        self.versionFormato = versionFormato
        self.conversaciones = conversaciones
        self.tareas = tareas
        self.proveedorActivo = proveedorActivo
        self.herramientasSinAprobacion = herramientasSinAprobacion
        self.packSkillsVersion = packSkillsVersion
        self.gasto = gasto
        self.usoApp = usoApp
        self.mcp = mcp
        self.manifiesto = manifiesto
    }

    private enum CodingKeys: String, CodingKey {
        case memoria
        case skills
        case ventanas
        case proveedores
        case topeGlobalUSD
        case versionFormato
        case conversaciones
        case tareas
        case proveedorActivo
        case herramientasSinAprobacion
        case packSkillsVersion
        case gasto
        case usoApp
        case mcp
        case manifiesto
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

        // Secciones del formato total: un respaldo de la version 1 no las trae
        // y se leen vacias, sin romper la importacion de la configuracion.
        conversaciones = try contenedor.decodeIfPresent(
            [Conversation].self,
            forKey: .conversaciones
        ) ?? []
        tareas = try contenedor.decodeIfPresent([Tarea].self, forKey: .tareas) ?? []
        proveedorActivo = try contenedor.decodeIfPresent(UUID.self, forKey: .proveedorActivo)
        herramientasSinAprobacion = try contenedor.decodeIfPresent(
            [String].self,
            forKey: .herramientasSinAprobacion
        )
        packSkillsVersion = try contenedor.decodeIfPresent(
            Int.self,
            forKey: .packSkillsVersion
        ) ?? 0
        gasto = try contenedor.decodeIfPresent(ContadoresGasto.self, forKey: .gasto)
            ?? ContadoresGasto()
        usoApp = try contenedor.decodeIfPresent(UsoApp.self, forKey: .usoApp) ?? UsoApp()
        mcp = try contenedor.decodeIfPresent(RespaldoMCP.self, forKey: .mcp)
        manifiesto = try contenedor.decodeIfPresent(
            ManifiestoRespaldo.self,
            forKey: .manifiesto
        )
    }

    /// Conteos calculados del contenido real, no del manifiesto guardado.
    public var conteos: ManifiestoRespaldo {
        ManifiestoRespaldo(
            versionFormato: versionFormato,
            conversaciones: conversaciones.count,
            tareas: tareas.count,
            memoria: memoria.count,
            skills: skills.count,
            proveedores: proveedores.count,
            ventanas: ventanas.count,
            diasDeGasto: usoApp.dias.count,
            mesesDeGasto: usoApp.meses.count
        )
    }

    /// Comprueba que el respaldo es coherente y se puede aplicar.
    ///
    /// No toca ningun estado: solo mira el archivo. Si trae manifiesto, tiene
    /// que cuadrar con el contenido; ademas no se admiten ids ni slugs
    /// repetidos, que romperian las listas y la idempotencia de la siembra.
    public func validar() throws {
        guard versionFormato >= 1, versionFormato <= Self.formatoActual else {
            throw ErrorRespaldo.versionNoSoportada
        }

        let idsProveedores = Set(proveedores.map(\.id))
        let idsSkills = Set(skills.map(\.id))
        let idsConversaciones = Set(conversaciones.map(\.id))
        let idsTareas = Set(tareas.map(\.id))
        let slugs = Set(skills.map { $0.slug.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard idsProveedores.count == proveedores.count,
              idsSkills.count == skills.count,
              idsConversaciones.count == conversaciones.count,
              idsTareas.count == tareas.count,
              slugs.count == skills.count,
              !slugs.contains("")
        else {
            throw ErrorRespaldo.idsDuplicados
        }

        if let manifiesto {
            guard manifiesto.versionFormato == versionFormato,
                  manifiesto.cuadraCon(self)
            else {
                throw ErrorRespaldo.manifiestoIncoherente
            }
        }
    }

    /// Construye el respaldo a partir de la configuracion y la tabla de ventanas.
    ///
    /// El tope guardado puede ser nil (nunca se fijo): se exporta el efectivo,
    /// que es el mismo que la app aplica y muestra. Las conversaciones y tareas
    /// se estrenan vacias; la app usa la sobrecarga total para llenarlas.
    public static func hacerRespaldo(
        config: AppConfig,
        ventanas: [String: Int]
    ) -> RespaldoConfiguracion {
        hacerRespaldo(
            config: config,
            ventanas: ventanas,
            conversaciones: [],
            tareas: []
        )
    }

    /// Construye el respaldo TOTAL (BACK.1) con conversaciones y tareas.
    ///
    /// El manifiesto se calcula del contenido recien armado. Las claves no se
    /// pasan porque no existen en estos modelos: viven en el llavero.
    public static func hacerRespaldo(
        config: AppConfig,
        ventanas: [String: Int],
        conversaciones: [Conversation],
        tareas: [Tarea]
    ) -> RespaldoConfiguracion {
        var respaldo = RespaldoConfiguracion(
            memoria: config.memoria,
            skills: config.skills,
            ventanas: ventanas,
            proveedores: config.proveedores,
            topeGlobalUSD: config.topeAvisoCostoEfectivo,
            versionFormato: formatoActual,
            conversaciones: conversaciones,
            tareas: tareas,
            proveedorActivo: config.proveedorActivo,
            herramientasSinAprobacion: config.herramientasSinAprobacion,
            packSkillsVersion: config.packSkillsVersion,
            gasto: config.gasto,
            usoApp: config.usoApp,
            mcp: RespaldoMCP.desde(config.servidor)
        )
        respaldo.manifiesto = respaldo.conteos
        return respaldo
    }

    /// Aplica el respaldo sobre una configuracion y devuelve la resultante.
    ///
    /// Restaura Memoria, skills, proveedores y tope. Un respaldo total (con
    /// manifiesto) restaura ademas proveedor activo, herramientas exentas,
    /// pack de fabrica, contadores, libro de gasto y MCP. Un respaldo viejo,
    /// sin manifiesto, conserva lo que no traia.
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

        if respaldo.manifiesto != nil {
            if let activo = respaldo.proveedorActivo {
                nueva.proveedorActivo = activo
            }
            nueva.herramientasSinAprobacion = respaldo.herramientasSinAprobacion
            nueva.packSkillsVersion = respaldo.packSkillsVersion
            nueva.gasto = respaldo.gasto
            nueva.usoApp = respaldo.usoApp
            // El campo MCP vacio (nil) significa que el respaldo no tenia
            // servidor: el reemplazo total tambien limpia el del destino.
            nueva.servidor = respaldo.mcp?.servidor ?? ServerConfig()
        }

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