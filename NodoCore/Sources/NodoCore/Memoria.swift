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

/// Accion que el modelo pidio ejecutar sobre la Memoria.
///
/// Se modela aparte del JSON crudo para que la validacion de argumentos viva
/// en un solo sitio y la aplicacion sobre la lista sea una funcion pura.
public enum AccionMemoria: Equatable {
    case guardar(texto: String)
    case actualizar(id: UUID, texto: String)
    case borrar(id: UUID)
}

/// Resultado de aplicar una accion sobre la lista de entradas.
public enum ResultadoAccionMemoria: Equatable {
    case aplicada(CambioMemoria)
    /// La accion era valida pero no se pudo aplicar (por ejemplo, un id que ya
    /// no existe). La lista no se toca y el motivo vuelve al modelo.
    case rechazada(String)
}

/// Cambio ya aplicado, con lo justo para deshacerlo EXACTAMENTE.
///
/// POR QUE guarda el estado anterior: deshacer no puede adivinar. Una
/// actualizacion necesita el texto viejo y un borrado necesita la entrada
/// completa y su posicion, o el Deshacer de la tarjeta no devolveria el estado
/// que habia antes de la orden.
public enum CambioMemoria: Equatable {
    case guardada(EntradaMemoria)
    case actualizada(id: UUID, anterior: String, nueva: String)
    case borrada(EntradaMemoria, indice: Int)

    /// Texto de la tarjeta de evento que se pinta en la conversacion.
    public var textoDeTarjeta: String {
        switch self {
        case .guardada(let entrada):
            return "Guarde en Memoria: \(entrada.texto)"
        case .actualizada(_, _, let nueva):
            return "Actualice en Memoria: \(nueva)"
        case .borrada(let entrada, _):
            return "Borre de Memoria: \(entrada.texto)"
        }
    }

    /// Texto que vuelve al modelo como resultado de la herramienta.
    ///
    /// Lleva el id para que pueda confirmar en su respuesta cual entrada toco,
    /// y para que una orden posterior pueda referirse a ella sin ambiguedad.
    public var resultadoHerramienta: String {
        switch self {
        case .guardada(let entrada):
            return "Guarde en Memoria la entrada \(entrada.id.uuidString)."
        case .actualizada(let id, _, _):
            return "Actualice en Memoria la entrada \(id.uuidString)."
        case .borrada(let entrada, _):
            return "Borre de Memoria la entrada \(entrada.id.uuidString)."
        }
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
    ///   aprobacion del dueno (TASK.4 la conecta con la hoja).
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

    /// Lee los argumentos de `memoria_chat` y devuelve la accion ya validada.
    ///
    /// La validacion ocurre antes de tocar la lista: un JSON roto, una accion
    /// desconocida o un campo obligatorio vacio se convierten en error de
    /// herramienta y la Memoria queda intacta.
    public static func accion(desdeArgumentos texto: String) throws -> AccionMemoria {
        let argumentos = try Argumentos.diccionario(texto)
        let accion = (Argumentos.texto(argumentos, clave: "accion") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !accion.isEmpty else {
            throw ErrorHerramienta.argumentosInvalidos(
                "falta la accion: guardar, actualizar o borrar"
            )
        }

        switch accion {
        case "guardar":
            return .guardar(texto: try textoObligatorio(argumentos, accion: accion))
        case "actualizar":
            return .actualizar(
                id: try idObligatorio(argumentos, accion: accion),
                texto: try textoObligatorio(argumentos, accion: accion)
            )
        case "borrar":
            return .borrar(id: try idObligatorio(argumentos, accion: accion))
        default:
            throw ErrorHerramienta.argumentosInvalidos(
                "accion no valida: \(accion). Usa guardar, actualizar o borrar."
            )
        }
    }

    /// Aplica una accion sobre la lista y devuelve el cambio exacto.
    ///
    /// Es pura a proposito: el llamador decide donde vive la lista y cuando se
    /// persiste, y las pruebas pueden comprobar la operacion sin red ni estado
    /// global.
    public static func aplicar(
        _ accion: AccionMemoria,
        en entradas: inout [EntradaMemoria],
        fecha: Date = Date(),
        id: UUID = UUID()
    ) -> ResultadoAccionMemoria {
        switch accion {
        case .guardar(let texto):
            let entrada = EntradaMemoria(id: id, texto: texto, fecha: fecha)
            entradas.append(entrada)
            return .aplicada(.guardada(entrada))

        case .actualizar(let id, let texto):
            guard let indice = entradas.firstIndex(where: { $0.id == id }) else {
                return .rechazada(
                    "no existe ninguna entrada de Memoria con id \(id.uuidString)."
                )
            }
            let anterior = entradas[indice].texto
            entradas[indice].texto = texto
            return .aplicada(
                .actualizada(id: id, anterior: anterior, nueva: texto)
            )

        case .borrar(let id):
            guard let indice = entradas.firstIndex(where: { $0.id == id }) else {
                return .rechazada(
                    "no existe ninguna entrada de Memoria con id \(id.uuidString)."
                )
            }
            let entrada = entradas.remove(at: indice)
            return .aplicada(.borrada(entrada, indice: indice))
        }
    }

    /// Revierte un cambio ya aplicado.
    ///
    /// Si la entrada objetivo ya no existe (por ejemplo, se borro a mano
    /// despues), la operacion no inventa nada: no hay estado anterior que
    /// restaurar. El borrado se reinserta en su posicion original para que el
    /// Deshacer devuelva la lista tal como estaba.
    public static func deshacer(_ cambio: CambioMemoria, en entradas: inout [EntradaMemoria]) {
        switch cambio {
        case .guardada(let entrada):
            entradas.removeAll { $0.id == entrada.id }

        case .actualizada(let id, let anterior, _):
            guard let indice = entradas.firstIndex(where: { $0.id == id }) else {
                return
            }
            entradas[indice].texto = anterior

        case .borrada(let entrada, let indice):
            // Si otra operacion ya reintrodujo esa entrada, no se duplica.
            guard !entradas.contains(where: { $0.id == entrada.id }) else {
                return
            }
            let destino = min(max(0, indice), entradas.count)
            entradas.insert(entrada, at: destino)
        }
    }

    private static func textoObligatorio(
        _ argumentos: [String: Any],
        accion: String
    ) throws -> String {
        guard let texto = Argumentos.texto(argumentos, clave: "texto")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !texto.isEmpty
        else {
            throw ErrorHerramienta.argumentosInvalidos(
                "la accion \(accion) necesita un texto."
            )
        }
        return texto
    }

    private static func idObligatorio(
        _ argumentos: [String: Any],
        accion: String
    ) throws -> UUID {
        guard let crudo = Argumentos.texto(argumentos, clave: "id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !crudo.isEmpty
        else {
            throw ErrorHerramienta.argumentosInvalidos(
                "la accion \(accion) necesita un id."
            )
        }
        guard let id = UUID(uuidString: crudo) else {
            throw ErrorHerramienta.argumentosInvalidos(
                "el id no es un UUID valido: \(crudo)"
            )
        }
        return id
    }

    /// Texto plano de la Memoria, solo para medir peso y costo estimado en la
    /// interfaz. El payload NO usa esto: usa `bloqueSistema(entradas:)`.
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

    /// Esquema de `proponer_memoria` (Modo Tarea).
    ///
    /// Misma forma que la de Chat porque la accion es la misma; lo que cambia
    /// es el contrato: en Tarea NADA se escribe hasta que el dueno aprueba. El
    /// nombre distinto es la frontera HP1: la app decide por contexto y
    /// herramienta, nunca por el texto del mensaje.
    public static let herramientaTarea = ToolDefinition(
        nombre: nombreHerramientaTarea,
        descripcion: "Propone guardar, actualizar o borrar una entrada de la Memoria del usuario. La app pedira aprobacion al dueno y solo escribira si la concede.",
        parametros: herramientaChat.parametros
    )
}

/// Herramienta de Memoria del turno de Chat.
///
/// MEM.3 la ejecuta de verdad: el modelo pide guardar, actualizar o borrar y la
/// app escribe la lista. En Chat no hay hoja de aprobacion (HP1): la orden
/// explicita del dueno es el propio mensaje que provoco la llamada, y el bloque
/// de sistema ya limita la herramienta a esa orden. La distincion es por
/// contexto y herramienta, nunca por heuristica sobre el texto del mensaje.
///
/// El ejecutor se inyecta porque la lista vive en la configuracion de la app:
/// el nucleo valida y aplica, y la capa app decide donde se guarda y como se
/// pinta la tarjeta del cambio.
public struct HerramientaMemoriaChat: Herramienta {
    public typealias Ejecutor = (AccionMemoria) async -> ResultadoAccionMemoria

    private let ejecutor: Ejecutor

    public init(ejecutor: @escaping Ejecutor) {
        self.ejecutor = ejecutor
    }

    public var definicion: ToolDefinition {
        Memoria.herramientaChat
    }

    public func ejecutar(argumentos: String) async throws -> String {
        let accion = try Memoria.accion(desdeArgumentos: argumentos)
        switch await ejecutor(accion) {
        case .aplicada(let cambio):
            return cambio.resultadoHerramienta
        case .rechazada(let motivo):
            return "Error: \(motivo)"
        }
    }
}

/// Herramienta de Memoria del Modo Tarea (HP1).
///
/// Se llama `proponer_memoria` y NUNCA escribe por su cuenta: el ToolLoop la
/// clasifica siempre como herramienta con aprobacion, la hoja del dueno decide
/// y solo si aprueba se llega a `ejecutar`. La aplicacion real la hace la capa
/// app con `Memoria.aplicar` (MEM), igual que en Chat, para no duplicar reglas.
public struct HerramientaProponerMemoria: Herramienta {
    public typealias Ejecutor = (AccionMemoria) async -> ResultadoAccionMemoria

    private let ejecutor: Ejecutor

    public init(ejecutor: @escaping Ejecutor) {
        self.ejecutor = ejecutor
    }

    public var definicion: ToolDefinition {
        Memoria.herramientaTarea
    }

    public func ejecutar(argumentos: String) async throws -> String {
        let accion = try Memoria.accion(desdeArgumentos: argumentos)
        switch await ejecutor(accion) {
        case .aplicada(let cambio):
            // La tarjeta/registro del libro es el texto del cambio aplicado.
            return cambio.textoDeTarjeta
        case .rechazada(let motivo):
            return "Error: \(motivo)"
        }
    }
}
