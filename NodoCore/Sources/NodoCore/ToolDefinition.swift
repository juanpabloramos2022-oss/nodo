import Foundation

/// Esquema de los argumentos de una herramienta.
///
/// Se modela solo lo que hace falta: objetos con propiedades planas de tipo
/// texto, numero o booleano. Un esquema mas rico no aporta nada aqui y obliga a
/// mantener un serializador propio.
public struct JSONSchema: Codable, Equatable {
    public struct Propiedad: Codable, Equatable {
        public var tipo: String
        public var descripcion: String
        /// Valores admitidos cuando el campo es una enumeracion cerrada.
        ///
        /// B2.1: las categorias de memoria son enums tipados y el esquema tiene
        /// que declararlos. Un `String` libre dejaria la puerta abierta a que el
        /// modelo inventara una categoria sensible por esta via.
        public var valoresPermitidos: [String]?

        public init(
            tipo: String,
            descripcion: String,
            valoresPermitidos: [String]? = nil
        ) {
            self.tipo = tipo
            self.descripcion = descripcion
            self.valoresPermitidos = valoresPermitidos
        }

        private enum CodingKeys: String, CodingKey {
            case tipo
            case descripcion
            case valoresPermitidos = "enum"
        }
    }

    public var tipo: String
    public var propiedades: [String: Propiedad]
    public var requeridos: [String]

    public init(
        propiedades: [String: Propiedad] = [:],
        requeridos: [String] = []
    ) {
        self.tipo = "object"
        self.propiedades = propiedades
        self.requeridos = requeridos
    }

    private enum CodingKeys: String, CodingKey {
        case tipo = "type"
        case propiedades = "properties"
        case requeridos = "required"
    }

    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        tipo = try contenedor.decodeIfPresent(String.self, forKey: .tipo) ?? "object"
        propiedades = try contenedor.decodeIfPresent([String: Propiedad].self, forKey: .propiedades) ?? [:]
        requeridos = try contenedor.decodeIfPresent([String].self, forKey: .requeridos) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var contenedor = encoder.container(keyedBy: CodingKeys.self)
        try contenedor.encode(tipo, forKey: .tipo)
        try contenedor.encode(propiedades, forKey: .propiedades)
        try contenedor.encode(requeridos, forKey: .requeridos)
    }
}

/// Definicion de una herramienta tal como se le presenta al modelo.
public struct ToolDefinition: Codable, Equatable {
    public var nombre: String
    public var descripcion: String
    public var parametros: JSONSchema

    public init(nombre: String, descripcion: String, parametros: JSONSchema) {
        self.nombre = nombre
        self.descripcion = descripcion
        self.parametros = parametros
    }
}

/// Una herramienta que la app puede ejecutar.
///
/// Devuelve siempre texto: es lo que se le vuelve a pasar al modelo. Si falla,
/// el error se convierte en texto y se le entrega igualmente, para que pueda
/// corregir el tiro en vez de romper el turno.
public protocol Herramienta {
    var definicion: ToolDefinition { get }
    func ejecutar(argumentos: String) async throws -> String
}

/// Errores de ejecucion de una herramienta.
public enum ErrorHerramienta: Error, Equatable, LocalizedError {
    case argumentosInvalidos(String)
    case noPermitida(String)
    case demasiadoGrande(Int)
    case tiempoAgotado

    public var errorDescription: String? {
        switch self {
        case let .argumentosInvalidos(detalle):
            return "Argumentos invalidos: \(detalle)"
        case let .noPermitida(detalle):
            return "Operacion no permitida: \(detalle)"
        case let .demasiadoGrande(bytes):
            return "La respuesta es demasiado grande (\(bytes) bytes)."
        case .tiempoAgotado:
            return "La operacion tardo demasiado."
        }
    }
}

/// Lee un argumento de texto de un JSON de argumentos.
///
/// Los modelos a veces envuelven los argumentos en un objeto con una sola clave,
/// o mandan numeros donde se espera texto, asi que se acepta lo razonable sin
/// ser laxos con lo que importa.
public enum Argumentos {
    public static func diccionario(_ texto: String) throws -> [String: Any] {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty { return [:] }
        guard let datos = limpio.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else {
            throw ErrorHerramienta.argumentosInvalidos("no es un objeto JSON")
        }
        return objeto
    }

    public static func texto(_ diccionario: [String: Any], clave: String) -> String? {
        if let valor = diccionario[clave] as? String { return valor }
        if let valor = diccionario[clave] as? NSNumber { return valor.stringValue }
        return nil
    }
}
