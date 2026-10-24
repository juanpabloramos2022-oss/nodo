import Foundation

/// Categoria no sensible de una entrada de Memoria (B2.1).
///
/// POR QUE un enum y no texto libre: la categoria la decide el contrato de la
/// herramienta y el ejecutor la valida antes de tocar el registro. Con un
/// `String` libre, una categoria sensible podria colarse por la via de guardado
/// directo, que es justo lo que la spec prohibe.
public enum CategoriaMemoria: String, Codable, Equatable, CaseIterable, Hashable {
    case durableFact = "durable_fact"
    case preference
    case commitment
    /// Marca una correccion sobre una entrada existente. No se usa como alta.
    case correction

    /// Categorias que `save_memory` puede escribir. `correction` no se guarda
    /// como entrada nueva: solo describe una actualizacion.
    public static let paraGuardar: [CategoriaMemoria] = [
        .durableFact, .preference, .commitment
    ]

    /// Categorias que `update_memory` puede declarar: una correccion o la
    /// categoria no sensible de la entrada que se corrige.
    public static let paraActualizar: [CategoriaMemoria] = [
        .correction, .durableFact, .preference, .commitment
    ]
}

/// Categoria de una escritura sensible propuesta (B2.4).
///
/// `save_memory` no tiene campo para estas categorias: clasificar algo sensible
/// por la via de guardado directo es estructuralmente imposible. Su unico
/// camino es `propose_sensitive_memory` y la hoja de aprobacion.
public enum CategoriaSensibleMemoria: String, Codable, Equatable, CaseIterable, Hashable {
    case health
    case finances
    case documentsIdentifiers = "documents_identifiers"
    case intimate
}

/// Una entrada de la Memoria viva.
///
/// POR QUE una lista y no un texto: la Memoria deja de ser un bloque unico que
/// solo se reescribe a mano y pasa a tener entradas con identidad propia. El id
/// es lo que permite que una herramienta actualice o borre UNA entrada sin
/// tocar las demas; la fecha deja constancia de cuando se guardo; la categoria
/// es la que impide que una escritura sensible entre por la via no sensible.
public struct EntradaMemoria: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var texto: String
    public var fecha: Date
    public var categoria: CategoriaMemoria

    public init(
        id: UUID = UUID(),
        texto: String,
        fecha: Date = Date(),
        categoria: CategoriaMemoria = .durableFact
    ) {
        self.id = id
        self.texto = texto
        self.fecha = fecha
        self.categoria = categoria
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case texto
        case fecha
        case categoria
    }

    /// Las entradas guardadas antes de B2.1 no traen categoria. Se leen como
    /// `durable_fact` para no perder ni trocear ninguna entrada existente.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decode(UUID.self, forKey: .id)
        texto = try contenedor.decode(String.self, forKey: .texto)
        fecha = try contenedor.decode(Date.self, forKey: .fecha)
        categoria = try contenedor.decodeIfPresent(
            CategoriaMemoria.self,
            forKey: .categoria
        ) ?? .durableFact
    }
}

/// Accion que el modelo pidio ejecutar sobre la Memoria.
///
/// Se conserva para el Modo Tarea (`proponer_memoria`), que sigue con su
/// esquema y su hoja de aprobacion sin cambios. La via de Chat usa
/// `OperacionMemoriaTipada`.
public enum AccionMemoria: Equatable {
    case guardar(texto: String)
    case actualizar(id: UUID, texto: String)
    case borrar(id: UUID)
}

/// Operacion tipada de las herramientas de memoria de Chat (B2.1).
///
/// Es el unico conjunto de escritura que acepta el ejecutor local. Las
/// categorias sensibles viven en un caso aparte que nunca persiste.
public enum OperacionMemoriaTipada: Equatable {
    case guardar(
        contenido: String,
        categoria: CategoriaMemoria,
        confianza: Double?
    )
    case actualizar(
        id: UUID,
        contenido: String,
        categoria: CategoriaMemoria,
        confianza: Double?
    )
    case proponerSensible(
        contenido: String,
        categoria: CategoriaSensibleMemoria,
        confianza: Double?
    )
    case borrar(id: UUID)

    /// Nombre tecnico de la herramienta que produce la operacion.
    public var nombreHerramienta: String {
        switch self {
        case .guardar: return Memoria.nombreGuardar
        case .actualizar: return Memoria.nombreActualizar
        case .proponerSensible: return Memoria.nombreProponerSensible
        case .borrar: return Memoria.nombreBorrar
        }
    }
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
/// actualizacion necesita el texto viejo y la categoria vieja, y un borrado
/// necesita la entrada completa y su posicion, o el Deshacer de la linea no
/// devolveria el estado que habia antes de la orden.
public enum CambioMemoria: Equatable {
    case guardada(EntradaMemoria)
    case actualizada(
        id: UUID,
        anterior: String,
        nueva: String,
        categoriaAnterior: CategoriaMemoria
    )
    case borrada(EntradaMemoria, indice: Int)

    /// Texto de la linea unica de Memoria que se pinta en la conversacion.
    ///
    /// B1.2: centrado en el hecho y en presente de registro, sin el id de la
    /// entrada. El texto completo vive en Mi Contexto; la linea solo lo
    /// anuncia. La accion [Deshacer] y su separador los anade el componente
    /// `LineaMemoria`, no esta cadena.
    public var textoDeLinea: String {
        switch self {
        case .guardada(let entrada):
            return "Guardado en memoria: \(entrada.texto)"
        case .actualizada(_, _, let nueva, _):
            return "Memoria actualizada: \(nueva)"
        case .borrada(let entrada, _):
            return "Memoria: entrada borrada · \(entrada.texto)"
        }
    }

    /// Texto que devuelve `proponer_memoria` al modelo en Modo Tarea.
    ///
    /// Es un resultado interno (viaja en el payload), no una linea visible:
    /// conserva el formato en pasado de la propuesta y no lleva id. La linea
    /// visible de Chat es `textoDeLinea`.
    public var resultadoPropuesta: String {
        switch self {
        case .guardada(let entrada):
            return "Guarde en Memoria: \(entrada.texto)"
        case .actualizada(_, _, let nueva, _):
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
        case .actualizada(let id, _, _, _):
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

    // MARK: - Herramientas tipadas de Chat (B2.1)

    /// `save_memory`: crea una entrada no sensible.
    public static let nombreGuardar = "save_memory"
    /// `update_memory`: corrige una entrada existente por su `entry_id`.
    public static let nombreActualizar = "update_memory"
    /// `propose_sensitive_memory`: propone un dato sensible. NUNCA persiste.
    public static let nombreProponerSensible = "propose_sensitive_memory"
    /// `delete_memory`: borra una entrada existente por su `entry_id`.
    public static let nombreBorrar = "delete_memory"

    /// Nombre reservado para el Modo Tarea (partida TASK).
    ///
    /// Politica de nombres y contexto, para que TASK la conecte sin inventar
    /// otra:
    /// - Chat: herramientas tipadas de B2.1, que validan antes de escribir.
    /// - Tarea: `proponer_memoria`, NO escribe: propone el cambio y espera la
    ///   aprobacion del dueno (TASK.4 la conecta con la hoja).
    /// - `proponer_memoria` no debe ofrecerse nunca en un chat normal, y las
    ///   herramientas tipadas no se ofrecen en Modo Tarea.
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

    /// Lee los argumentos de `proponer_memoria` (Modo Tarea).
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
                id: try idObligatorio(argumentos, clave: "id", accion: accion),
                texto: try textoObligatorio(argumentos, accion: accion)
            )
        case "borrar":
            return .borrar(
                id: try idObligatorio(argumentos, clave: "id", accion: accion)
            )
        default:
            throw ErrorHerramienta.argumentosInvalidos(
                "accion no valida: \(accion). Usa guardar, actualizar o borrar."
            )
        }
    }

    /// Lee los argumentos de una herramienta tipada y devuelve la operacion.
    ///
    /// Es la puerta unica de parseo: nombre de herramienta, campos
    /// obligatorios, categorias permitidas y rango de confianza. La existencia
    /// del `entry_id` la valida el ejecutor contra el snapshot del turno, porque
    /// aqui no hay lista.
    public static func operacion(
        herramienta: String,
        argumentos texto: String
    ) throws -> OperacionMemoriaTipada {
        let argumentos = try Argumentos.diccionario(texto)

        switch herramienta {
        case nombreGuardar:
            return .guardar(
                contenido: try contenidoObligatorio(argumentos, herramienta: herramienta),
                categoria: try categoriaObligatoria(
                    argumentos,
                    clave: "category",
                    permitidas: CategoriaMemoria.paraGuardar
                ),
                confianza: try confianzaOpcional(argumentos)
            )

        case nombreActualizar:
            return .actualizar(
                id: try idObligatorio(
                    argumentos,
                    clave: "entry_id",
                    accion: herramienta
                ),
                contenido: try contenidoObligatorio(argumentos, herramienta: herramienta),
                categoria: try categoriaObligatoria(
                    argumentos,
                    clave: "category",
                    permitidas: CategoriaMemoria.paraActualizar
                ),
                confianza: try confianzaOpcional(argumentos)
            )

        case nombreProponerSensible:
            return .proponerSensible(
                contenido: try contenidoObligatorio(argumentos, herramienta: herramienta),
                categoria: try categoriaSensibleObligatoria(argumentos),
                confianza: try confianzaOpcional(argumentos)
            )

        case nombreBorrar:
            return .borrar(
                id: try idObligatorio(
                    argumentos,
                    clave: "entry_id",
                    accion: herramienta
                )
            )

        default:
            throw ErrorHerramienta.noPermitida(
                "herramienta de memoria desconocida: \(herramienta)"
            )
        }
    }

    /// Aplica una accion del Modo Tarea sobre la lista y devuelve el cambio.
    ///
    /// Es pura a proposito: el llamador decide donde vive la lista y cuando se
    /// persiste, y las pruebas pueden comprobar la operacion sin red ni estado
    /// global. La via de Chat usa `aplicarTipada`.
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
            let categoriaAnterior = entradas[indice].categoria
            entradas[indice].texto = texto
            return .aplicada(
                .actualizada(
                    id: id,
                    anterior: anterior,
                    nueva: texto,
                    categoriaAnterior: categoriaAnterior
                )
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

    /// Aplica una operacion tipada sobre la lista y devuelve el cambio exacto.
    ///
    /// `propose_sensitive_memory` nunca llega a mutar: se rechaza aqui tambien
    /// como segunda barrera, aunque el ejecutor ya la corta antes.
    public static func aplicarTipada(
        _ operacion: OperacionMemoriaTipada,
        en entradas: inout [EntradaMemoria],
        fecha: Date = Date(),
        id: UUID = UUID()
    ) -> ResultadoAccionMemoria {
        switch operacion {
        case .guardar(let contenido, let categoria, _):
            let entrada = EntradaMemoria(
                id: id,
                texto: contenido,
                fecha: fecha,
                categoria: categoria
            )
            entradas.append(entrada)
            return .aplicada(.guardada(entrada))

        case .actualizar(let id, let contenido, let categoria, _):
            guard let indice = entradas.firstIndex(where: { $0.id == id }) else {
                return .rechazada(
                    "no existe ninguna entrada de Memoria con ese entry_id."
                )
            }
            let anterior = entradas[indice].texto
            let categoriaAnterior = entradas[indice].categoria
            entradas[indice].texto = contenido
            entradas[indice].categoria = categoria
            return .aplicada(
                .actualizada(
                    id: id,
                    anterior: anterior,
                    nueva: contenido,
                    categoriaAnterior: categoriaAnterior
                )
            )

        case .proponerSensible:
            return .rechazada(
                "la memoria sensible requiere aprobacion del dueno y no se persiste."
            )

        case .borrar(let id):
            guard let indice = entradas.firstIndex(where: { $0.id == id }) else {
                return .rechazada(
                    "no existe ninguna entrada de Memoria con ese entry_id."
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
    public static func deshacer(
        _ cambio: CambioMemoria,
        en entradas: inout [EntradaMemoria]
    ) {
        switch cambio {
        case .guardada(let entrada):
            entradas.removeAll { $0.id == entrada.id }

        case .actualizada(let id, let anterior, _, let categoriaAnterior):
            guard let indice = entradas.firstIndex(where: { $0.id == id }) else {
                return
            }
            entradas[indice].texto = anterior
            entradas[indice].categoria = categoriaAnterior

        case .borrada(let entrada, let indice):
            // Si otra operacion ya reintrodujo esa entrada, no se duplica.
            guard !entradas.contains(where: { $0.id == entrada.id }) else {
                return
            }
            let destino = min(max(0, indice), entradas.count)
            entradas.insert(entrada, at: destino)
        }
    }

    private static func contenidoObligatorio(
        _ argumentos: [String: Any],
        herramienta: String
    ) throws -> String {
        guard let texto = Argumentos.texto(argumentos, clave: "content")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !texto.isEmpty
        else {
            throw ErrorHerramienta.argumentosInvalidos(
                "\(herramienta) necesita un content."
            )
        }
        return texto
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
        clave: String,
        accion: String
    ) throws -> UUID {
        guard let crudo = Argumentos.texto(argumentos, clave: clave)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !crudo.isEmpty
        else {
            throw ErrorHerramienta.argumentosInvalidos(
                "la accion \(accion) necesita \(clave)."
            )
        }
        guard let id = UUID(uuidString: crudo) else {
            throw ErrorHerramienta.argumentosInvalidos(
                "\(clave) no es un UUID valido: \(crudo)"
            )
        }
        return id
    }

    private static func categoriaObligatoria(
        _ argumentos: [String: Any],
        clave: String,
        permitidas: [CategoriaMemoria]
    ) throws -> CategoriaMemoria {
        guard let crudo = Argumentos.texto(argumentos, clave: clave)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !crudo.isEmpty
        else {
            throw ErrorHerramienta.argumentosInvalidos("falta \(clave).")
        }
        guard let categoria = CategoriaMemoria(rawValue: crudo),
              permitidas.contains(categoria)
        else {
            let validas = permitidas.map(\.rawValue).joined(separator: ", ")
            throw ErrorHerramienta.argumentosInvalidos(
                "\(clave) no valida: \(crudo). Usa: \(validas)."
            )
        }
        return categoria
    }

    private static func categoriaSensibleObligatoria(
        _ argumentos: [String: Any]
    ) throws -> CategoriaSensibleMemoria {
        guard let crudo = Argumentos.texto(argumentos, clave: "sensitive_category")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !crudo.isEmpty
        else {
            throw ErrorHerramienta.argumentosInvalidos(
                "falta sensitive_category."
            )
        }
        guard let categoria = CategoriaSensibleMemoria(rawValue: crudo) else {
            let validas = CategoriaSensibleMemoria.allCases
                .map(\.rawValue)
                .joined(separator: ", ")
            throw ErrorHerramienta.argumentosInvalidos(
                "sensitive_category no valida: \(crudo). Usa: \(validas)."
            )
        }
        return categoria
    }

    private static func confianzaOpcional(
        _ argumentos: [String: Any]
    ) throws -> Double? {
        guard let valor = argumentos["confidence_score"], !(valor is NSNull) else {
            return nil
        }

        let numero: Double
        if let valorNumerico = valor as? NSNumber {
            numero = valorNumerico.doubleValue
        } else if let texto = valor as? String, let valorNumerico = Double(texto) {
            numero = valorNumerico
        } else {
            throw ErrorHerramienta.argumentosInvalidos(
                "confidence_score debe ser un numero entre 0 y 1."
            )
        }

        guard numero.isFinite, numero >= 0, numero <= 1 else {
            throw ErrorHerramienta.argumentosInvalidos(
                "confidence_score fuera de rango: \(numero). Debe estar entre 0 y 1."
            )
        }
        return numero
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
    /// cuenta y ensuciar la Memoria sin que nadie se lo pida. B2.1 inyecta cada
    /// entrada con su id, su categoria y su texto, y deja el candado de borrado
    /// (PDE-A1) siempre en «solo ante orden explicita del dueno en ese turno».
    public static func bloqueSistema(entradas: [EntradaMemoria]) -> String {
        var lineas: [String] = [
            cabeceraBloque,
            "Puedes guardar, actualizar o borrar entradas de esta memoria SOLO cuando el dueno te lo ordene de forma explicita. No lo hagas por iniciativa propia ni en silencio.",
            "Usa las herramientas tipadas de memoria: save_memory (content + category), update_memory (entry_id + content + category) y delete_memory (entry_id). Ninguna de ellas admite una categoria sensible: no existe via para guardar salud, finanzas, documentos de identidad ni datos intimos.",
            "",
            "Comunicacion de memoria:",
            "1. Si en este turno no ejecutas la herramienta de memoria, responde solo al contenido de la conversacion: no menciones la memoria, ni que no guardaste nada, ni bajo que reglas guardas o dejas de guardar.",
            "2. Nunca afirmes haber guardado, anotado o recordado algo que no hayas ejecutado con la herramienta en este turno. Prohibido «anotado mentalmente» y cualquier equivalente.",
            "3. Si ejecutas la herramienta, la app ya lo avisa en su linea: tu acuse en palabras es opcional y, si lo haces, es maximo 1 frase simple de 20 palabras o menos, tras lo cual sigues con la respuesta normal.",
            "4. Explica la politica de memoria unicamente si el dueno pregunta literalmente como funciona la memoria.",
            "",
            "Candado de borrado: delete_memory solo ante orden explicita del dueno en ese turno; nunca por iniciativa propia del modelo, ni siquiera con la memoria inteligente activada.",
            ""
        ]

        if entradas.isEmpty {
            lineas.append("Entradas actuales: ninguna.")
        } else {
            lineas.append("Entradas actuales:")
            for entrada in entradas {
                lineas.append(
                    "- id: \(entrada.id.uuidString) · categoria: "
                        + "\(entrada.categoria.rawValue) · texto: \(entrada.texto)"
                )
            }
        }
        return lineas.joined(separator: "\n")
    }

    // MARK: - Esquemas

    /// Esquema de `save_memory`.
    ///
    /// No existe ningun campo de categoria sensible: clasificar algo sensible
    /// por esta via es estructuralmente imposible.
    public static let herramientaGuardar = ToolDefinition(
        nombre: nombreGuardar,
        descripcion: "Guarda una entrada nueva en la Memoria del usuario. Solo debe usarse cuando el dueno lo ordene explicitamente.",
        parametros: JSONSchema(
            propiedades: [
                "content": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "Texto de la entrada nueva."
                ),
                "category": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "durable_fact, preference o commitment.",
                    valoresPermitidos: CategoriaMemoria.paraGuardar.map(\.rawValue)
                ),
                "confidence_score": JSONSchema.Propiedad(
                    tipo: "number",
                    descripcion: "Confianza de 0 a 1. Opcional."
                )
            ],
            requeridos: ["content", "category"]
        )
    )

    /// Esquema de `update_memory`.
    public static let herramientaActualizar = ToolDefinition(
        nombre: nombreActualizar,
        descripcion: "Corrige una entrada existente de la Memoria del usuario. Solo debe usarse cuando el dueno lo ordene explicitamente.",
        parametros: JSONSchema(
            propiedades: [
                "entry_id": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "UUID de la entrada que se corrige."
                ),
                "content": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "Texto nuevo de la entrada."
                ),
                "category": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "correction o la categoria no sensible de la entrada corregida.",
                    valoresPermitidos: CategoriaMemoria.paraActualizar.map(\.rawValue)
                ),
                "confidence_score": JSONSchema.Propiedad(
                    tipo: "number",
                    descripcion: "Confianza de 0 a 1. Opcional."
                )
            ],
            requeridos: ["entry_id", "content", "category"]
        )
    )

    /// Esquema de `propose_sensitive_memory`.
    ///
    /// B2.1 la define, la valida y la prueba, pero NO la ofrece en Chat: su
    /// cableado a la hoja de aprobacion es B2.4.
    public static let herramientaProponerSensible = ToolDefinition(
        nombre: nombreProponerSensible,
        descripcion: "Propone guardar un dato sensible en la Memoria del usuario. La app pedira aprobacion y no se persiste nada sin ella.",
        parametros: JSONSchema(
            propiedades: [
                "content": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "Texto del dato sensible que se propone guardar."
                ),
                "sensitive_category": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "health, finances, documents_identifiers o intimate.",
                    valoresPermitidos: CategoriaSensibleMemoria.allCases.map(\.rawValue)
                ),
                "confidence_score": JSONSchema.Propiedad(
                    tipo: "number",
                    descripcion: "Confianza de 0 a 1. Opcional."
                )
            ],
            requeridos: ["content", "sensitive_category"]
        )
    )

    /// Esquema de `delete_memory`: solo el id, sin categoria.
    public static let herramientaBorrar = ToolDefinition(
        nombre: nombreBorrar,
        descripcion: "Borra una entrada existente de la Memoria del usuario. Solo ante orden explicita del dueno en ese turno.",
        parametros: JSONSchema(
            propiedades: [
                "entry_id": JSONSchema.Propiedad(
                    tipo: "string",
                    descripcion: "UUID de la entrada que se borra."
                )
            ],
            requeridos: ["entry_id"]
        )
    )

    /// Esquema de `proponer_memoria` (Modo Tarea).
    ///
    /// Misma forma que la vieja herramienta de Chat porque la accion es la
    /// misma; lo que cambia es el contrato: en Tarea NADA se escribe hasta que
    /// el dueno aprueba. El nombre distinto es la frontera HP1: la app decide
    /// por contexto y herramienta, nunca por el texto del mensaje.
    public static let herramientaTarea = ToolDefinition(
        nombre: nombreHerramientaTarea,
        descripcion: "Propone guardar, actualizar o borrar una entrada de la Memoria del usuario. La app pedira aprobacion al dueno y solo escribira si la concede.",
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

/// Herramienta tipada de Memoria del turno de Chat (B2.1).
///
/// El ejecutor se inyecta porque la lista, el contador 1/turno y el snapshot de
/// ids viven en la capa app: el nucleo valida los argumentos y aplica, y la
/// app decide donde se guarda y como se pinta la linea.
public struct HerramientaMemoriaTipada: Herramienta {
    public let definicion: ToolDefinition
    private let ejecutarArgumentos: (String) async throws -> String

    public init(
        definicion: ToolDefinition,
        ejecutar: @escaping (String) async throws -> String
    ) {
        self.definicion = definicion
        self.ejecutarArgumentos = ejecutar
    }

    public func ejecutar(argumentos: String) async throws -> String {
        try await ejecutarArgumentos(argumentos)
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
            // Resultado interno de la propuesta: describe el cambio al modelo
            // sin introducir un id en la conversacion.
            return cambio.resultadoPropuesta
        case .rechazada(let motivo):
            return "Error: \(motivo)"
        }
    }
}
