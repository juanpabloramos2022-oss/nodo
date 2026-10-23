import Foundation

/// Una llamada a herramienta que el modelo pide ejecutar.
///
/// Los argumentos se guardan como texto JSON crudo, tal como los envia el
/// modelo, y se validan al ejecutarlos. Guardarlos ya parseados obligaria a
/// rechazar la respuesta entera por un argumento mal formado, y es mejor
/// devolverle el error al modelo para que lo corrija.
public struct ToolCall: Codable, Equatable {
    public var id: String
    public var nombre: String
    public var argumentos: String

    public init(id: String, nombre: String, argumentos: String) {
        self.id = id
        self.nombre = nombre
        self.argumentos = argumentos
    }
}

/// Un mensaje de la conversacion.
public struct ChatMessage: Codable, Identifiable, Equatable {
    public enum Rol: String, Codable, CaseIterable {
        case usuario
        case asistente
        case sistema
        case herramienta
    }

    public var id: UUID
    public var rol: Rol
    public var texto: String
    public var fecha: Date
    /// Llamadas que pidio el modelo en este mensaje. Solo en mensajes de asistente.
    public var toolCalls: [ToolCall]
    /// Identificador de la llamada a la que responde este mensaje. Solo en
    /// mensajes de herramienta.
    public var toolCallId: String?
    /// Tokens de entrada que reporto la API para este mensaje. nil en los
    /// mensajes guardados antes de existir el consumo.
    public var tokensEntrada: Int?
    /// Tokens de salida que reporto la API para este mensaje.
    public var tokensSalida: Int?

    public init(
        id: UUID = UUID(),
        rol: Rol,
        texto: String,
        fecha: Date = Date(),
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil,
        tokensEntrada: Int? = nil,
        tokensSalida: Int? = nil
    ) {
        self.id = id
        self.rol = rol
        self.texto = texto
        self.fecha = fecha
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.tokensEntrada = tokensEntrada
        self.tokensSalida = tokensSalida
    }

    /// Consumo del mensaje, si lo tiene. Los mensajes viejos devuelven nil.
    public var uso: UsoTokens? {
        guard tokensEntrada != nil || tokensSalida != nil else { return nil }
        return UsoTokens(entrada: tokensEntrada ?? 0, salida: tokensSalida ?? 0)
    }

    /// Un mensaje de herramienta necesita saber a que llamada responde; sin eso
    /// la API lo rechaza.
    public var esValido: Bool {
        if rol == .herramienta { return toolCallId != nil }
        return true
    }
}

/// Una conversacion completa.
public struct Conversation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var titulo: String
    public var mensajes: [ChatMessage]
    public var creada: Date
    public var actualizada: Date
    /// Si esta fijada, sale en el grupo "Fijados" de la lista del Historial.
    public var fijada: Bool
    /// Si esta archivada, no sale en la lista principal del Historial.
    public var archivada: Bool
    /// Si ya se aviso en este chat que el acumulado paso el tope. Se guarda
    /// para no repetir el aviso en cada turno.
    public var avisoCostoMostrado: Bool

    public init(
        id: UUID = UUID(),
        titulo: String = "Conversacion",
        mensajes: [ChatMessage] = [],
        creada: Date = Date(),
        actualizada: Date = Date(),
        fijada: Bool = false,
        archivada: Bool = false,
        avisoCostoMostrado: Bool = false
    ) {
        self.id = id
        self.titulo = titulo
        self.mensajes = mensajes
        self.creada = creada
        self.actualizada = actualizada
        self.fijada = fijada
        self.archivada = archivada
        self.avisoCostoMostrado = avisoCostoMostrado
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case titulo
        case mensajes
        case creada
        case actualizada
        case fijada
        case archivada
        case avisoCostoMostrado
    }

    /// Decodificacion tolerante con los archivos de v0.1.0.
    ///
    /// Las conversaciones guardadas antes de existir fijar, archivar o el aviso
    /// de costo no traen esas claves. El Decodable sintetizado las exigiria y
    /// dejaria de abrir el historial entero, asi que se leen como opcionales con
    /// valor por defecto.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decode(UUID.self, forKey: .id)
        titulo = try contenedor.decode(String.self, forKey: .titulo)
        mensajes = try contenedor.decode([ChatMessage].self, forKey: .mensajes)
        creada = try contenedor.decode(Date.self, forKey: .creada)
        actualizada = try contenedor.decode(Date.self, forKey: .actualizada)
        fijada = try contenedor.decodeIfPresent(Bool.self, forKey: .fijada) ?? false
        archivada = try contenedor.decodeIfPresent(Bool.self, forKey: .archivada) ?? false
        avisoCostoMostrado = try contenedor.decodeIfPresent(Bool.self, forKey: .avisoCostoMostrado) ?? false
    }

    /// Titulo derivado del primer mensaje del usuario, recortado a una linea.
    ///
    /// Se calcula y no se guarda para que renombrar a mano siga siendo posible
    /// sin que el siguiente mensaje lo pise.
    public var tituloSugerido: String {
        guard let primero = mensajes.first(where: { $0.rol == .usuario }) else {
            return "Conversacion"
        }
        let limpio = primero.texto
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty { return "Conversacion" }
        if limpio.count <= 48 { return limpio }
        return String(limpio.prefix(48)) + "..."
    }

    /// Descarta lo que haya despues del ultimo mensaje del usuario y devuelve
    /// ese turno descartado, para poder restaurarlo si la regeneracion falla.
    ///
    /// El turno puede traer mensajes de asistente y de herramienta mezclados:
    /// todo lo posterior al ultimo mensaje del usuario forma parte de la
    /// respuesta que se esta regenerando. Si no hay nada que descartar (sin
    /// usuario o sin respuesta todavia) el historial queda intacto.
    @discardableResult
    public mutating func descartarUltimoTurno() -> [ChatMessage] {
        guard let indice = mensajes.lastIndex(where: { $0.rol == .usuario }),
              indice + 1 < mensajes.count
        else {
            return []
        }

        let descartados = Array(mensajes.suffix(from: indice + 1))
        mensajes.removeLast(descartados.count)
        return descartados
    }
}

/// Las tres secciones de la lista del Historial, ya ordenadas y filtradas.
public struct SeccionesHistorial: Equatable {
    /// Conversaciones fijadas y no archivadas, primero en la lista principal.
    public let fijadas: [Conversation]
    /// Conversaciones no fijadas y no archivadas, por actividad reciente.
    public let recientes: [Conversation]
    /// Conversaciones archivadas, fuera de la lista principal.
    public let archivadas: [Conversation]

    public init(
        fijadas: [Conversation] = [],
        recientes: [Conversation] = [],
        archivadas: [Conversation] = []
    ) {
        self.fijadas = fijadas
        self.recientes = recientes
        self.archivadas = archivadas
    }

    /// La lista principal: primero las fijadas y despues el resto.
    public var principales: [Conversation] {
        fijadas + recientes
    }

    /// True si no hay nada que ensenar (por ejemplo, una busqueda sin resultados).
    public var vacia: Bool {
        fijadas.isEmpty && recientes.isEmpty && archivadas.isEmpty
    }
}

/// Reglas puras de orden y filtrado de la lista del Historial.
///
/// Viven en NodoCore, y no en la vista, para poder probarlas con `swift test`.
public enum HistorialConversaciones {
    /// Reparte las conversaciones en fijadas, recientes y archivadas.
    ///
    /// Los fijados van primero; dentro de cada grupo manda la actividad mas
    /// reciente. Las archivadas nunca salen en la lista principal, pero se
    /// pueden buscar en su propia seccion. La busqueda mira el titulo y el texto
    /// de todos los mensajes.
    public static func secciones(
        de conversaciones: [Conversation],
        busqueda: String = ""
    ) -> SeccionesHistorial {
        let ordenadas = conversaciones
            .filter { coincide($0, con: busqueda) }
            .sorted { $0.actualizada > $1.actualizada }

        return SeccionesHistorial(
            fijadas: ordenadas.filter { $0.fijada && !$0.archivada },
            recientes: ordenadas.filter { !$0.fijada && !$0.archivada },
            archivadas: ordenadas.filter(\.archivada)
        )
    }

    /// True si la conversacion encaja con el texto de busqueda.
    ///
    /// Una busqueda vacia encaja con todo. Se ignoran mayusculas y acentos, y
    /// se busca tanto en el titulo como en el texto de los mensajes.
    public static func coincide(_ conversacion: Conversation, con busqueda: String) -> Bool {
        let consulta = busqueda.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consulta.isEmpty else { return true }

        let opciones: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if conversacion.titulo.range(of: consulta, options: opciones) != nil {
            return true
        }
        return conversacion.mensajes.contains { mensaje in
            mensaje.texto.range(of: consulta, options: opciones) != nil
        }
    }
}
