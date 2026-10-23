import Foundation

/// Una entrada de la Memoria viva.
///
/// POR QUE una lista y no un texto: la Memoria deja de ser un bloque unico que
/// solo se reescribe a mano y pasa a tener entradas con identidad propia. El id
/// es lo que permite que una herramienta actualice o borre UNA entrada sin
/// tocar las demas; la fecha deja constancia de cuando se guardo.
public struct EntradaMemoria: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var texto: String
    public var fecha: Date

    public init(id: UUID = UUID(), texto: String, fecha: Date = Date()) {
        self.id = id
        self.texto = texto
        self.fecha = fecha
    }
}

/// Reglas de la Memoria viva compartidas por el almacenamiento y el payload.
public enum Memoria {
    /// Cabecera unica del bloque de sistema.
    ///
    /// Una sola constante evita que la app y las pruebas se desincronicen al
    /// rotular el mismo contexto.
    public static let cabeceraBloque = "[Memoria del usuario]"

    /// Nombre de la herramienta del turno de Chat (HP1: escribe directo).
    public static let nombreHerramientaChat = "memoria_chat"

    /// Nombre reservado para el Modo Tarea (partida TASK).
    ///
    /// Politica de nombres y contexto, para que TASK la conecte sin inventar
    /// otra:
    /// - Chat: `memoria_chat`, escribe directo porque el dueno lo pidio en el
    ///   propio turno.
    /// - Tarea: `proponer_memoria`, NO escribe: propone el cambio y espera la
    ///   aprobacion del dueno. No se crea aqui; TASK la conecta.
    /// - `proponer_memoria` no debe ofrecerse nunca en un chat normal, y
    ///   `memoria_chat` no se ofrece en chats sin memoria.
    public static let nombreHerramientaTarea = "proponer_memoria"

    /// Convierte el texto legado en UNA sola entrada.
    ///
    /// POR QUE una sola: la migracion no puede trocear ni perder nada de lo que
    /// el dueno ya tenia escrito. Si el texto esta vacio no hay entrada.
    public static func entradasDesdeTextoLegado(_ texto: String) -> [EntradaMemoria] {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return [] }
        return [EntradaMemoria(texto: texto)]
    }

    /// Texto plano de la Memoria, solo para la interfaz que todavia edita como
    /// bloque. El payload NO usa esto: usa `bloqueSistema(entradas:)`.
    public static func textoPlano(_ entradas: [EntradaMemoria]) -> String {
        entradas.map(\.texto).joined(separator: "\n\n")
    }

    /// Bloque de sistema que declara la capacidad y lista las entradas.
    ///
    /// Se manda SOLO en chats con memoria. La capacidad se limita a una orden
    /// explicita del dueno: sin esa frontera el modelo podria "recordar" por su
    /// cuenta y ensuciar la Memoria sin que nadie se lo pida.
    public static func bloqueSistema(entradas: [EntradaMemoria]) -> String {
        var lineas: [String] = [
            cabeceraBloque,
            "Puedes guardar, actualizar o borrar entradas de esta memoria SOLO cuando el dueno te lo ordene de forma explicita. No lo hagas por iniciativa propia ni en silencio.",
            "Usa la herramienta \(nombreHerramientaChat): accion guardar (texto nuevo), actualizar (id + texto) o borrar (id)."
        ]

        if entradas.isEmpty {
            lineas.append("Entradas actuales: ninguna.")
        } else {
            lineas.append("Entradas actuales:")
            for entrada in entradas {
                lineas.append("- id: \(entrada.id.uuidString) · texto: \(entrada.texto)")
            }
        }
        return lineas.joined(separator: "\n")
    }

    /// Esquema de `memoria_chat`.
    ///
    /// `texto` e `id` son opcionales en el esquema porque dependen de la accion:
    /// guardar necesita texto; actualizar necesita id y texto; borrar necesita
    /// id. La descripcion lo explica para que el modelo no mande campos de mas.
    public static let herramientaChat = ToolDefinition(
        nombre: nombreHerramientaChat,
        descripcion: "Guarda, actualiza o borra una entrada de la Memoria del usuario. Solo debe usarse cuando el dueno lo ordene explicitamente.",
        parametros: JSONSchema(
            propiedades: [
                "accion": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "guardar, actualizar o borrar"
                ),
                "texto": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "Texto de la entrada. Obligatorio al guardar y al actualizar."
                ),
                "id": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "Id de la entrada que se actualiza o se borra."
                )
            ],
            requeridos: ["accion"]
        )
    )
}

/// Herramienta de Memoria del turno de Chat.
///
/// MEM.2 solo la OFRECE en el payload: el modelo ya ve su esquema y el bloque
/// que explica cuando usarla. La ejecucion real (escribir la entrada en la
/// configuracion) llega en MEM.3. Hasta entonces, si el modelo la llama, el
/// bucle devuelve un error de texto en vez de romper el turno.
public struct HerramientaMemoriaChat: Herramienta {
    public init() {}

    public var definicion: ToolDefinition {
        Memoria.herramientaChat
    }

    public func ejecutar(argumentos: String) async throws -> String {
        throw ErrorHerramienta.noPermitida(
            "la ejecucion de \(Memoria.nombreHerramientaChat) llega en MEM.3"
        )
    }
}
