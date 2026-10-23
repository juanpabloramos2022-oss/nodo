import Foundation

/// Estado del ciclo de vida de una Tarea.
///
/// El orden de los casos no es el orden de la interfaz: `borrador` es una tarea
/// que aun no tiene plan, `esperandoInicio` ya lo tiene y espera la autorizacion
/// explicita del dueno, y `enCurso` es la ejecucion autorizada. En iOS no hay
/// procesos en segundo plano, asi que `interrumpida` es la frontera honesta
/// cuando la app se cierra con una tarea en curso.
public enum EstadoTarea: String, Codable, CaseIterable, Identifiable {
    case borrador
    case esperandoInicio
    case enCurso
    case detenida
    case interrumpida
    case completada
    case fallida

    public var id: String { rawValue }

    /// Texto visible en la lista y en la pantalla de la tarea.
    public var titulo: String {
        switch self {
        case .borrador: return "Borrador"
        case .esperandoInicio: return "Esperando inicio"
        case .enCurso: return "En curso"
        case .detenida: return "Detenida"
        case .interrumpida: return "Interrumpida"
        case .completada: return "Completada"
        case .fallida: return "Fallida"
        }
    }

    /// Solo un borrador o un plan esperando inicio admiten edicion.
    ///
    /// Una vez autorizada la ejecucion, cambiar la instruccion o el plan
    /// dejaria el libro de pasos describiendo otra cosa: se bloquea.
    public var admiteEdicion: Bool {
        self == .borrador || self == .esperandoInicio
    }

    /// Estados en los que ya no se va a ejecutar nada mas.
    public var esFinal: Bool {
        switch self {
        case .completada, .fallida, .interrumpida:
            return true
        case .borrador, .esperandoInicio, .enCurso, .detenida:
            return false
        }
    }
}

/// Estado de un paso del LIBRO de ejecucion.
///
/// TASK.1/TASK.2 reservan el tipo y el campo `Tarea.pasos`; la estructura
/// completa del libro (herramienta, resultado, aprobacion) llega en TASK.3.
/// Este minimo permite que la fila de la lista calcule el progreso sin fingir
/// pasos que todavia no existen.
public enum EstadoPaso: String, Codable, CaseIterable, Identifiable {
    case pendiente
    case enCurso
    case terminado
    case fallido

    public var id: String { rawValue }

    public var titulo: String {
        switch self {
        case .pendiente: return "Pendiente"
        case .enCurso: return "En curso"
        case .terminado: return "Terminado"
        case .fallido: return "Fallido"
        }
    }
}

/// Un paso del libro de ejecucion.
///
/// Decision de TASK.1: el campo existe desde ahora para que el progreso de la
/// lista tenga una forma estable, pero se deja vacio y con lo minimo. TASK.3
/// anade herramienta, resultado y aprobacion sobre este mismo tipo sin migrar
/// los archivos: la decodificacion tolerante de abajo rellena lo que falte.
public struct Paso: Codable, Identifiable, Equatable {
    public var id: UUID
    public var descripcion: String
    public var estado: EstadoPaso

    public init(
        id: UUID = UUID(),
        descripcion: String = "",
        estado: EstadoPaso = .pendiente
    ) {
        self.id = id
        self.descripcion = descripcion
        self.estado = estado
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case descripcion
        case estado
    }

    /// Decodificacion tolerante con los pasos escritos por una version
    /// intermedia: un archivo sin estado se lee como pendiente.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        descripcion = try contenedor.decodeIfPresent(String.self, forKey: .descripcion) ?? ""
        estado = try contenedor.decodeIfPresent(EstadoPaso.self, forKey: .estado) ?? .pendiente
    }
}

/// Un paso del PLAN que el modelo propone antes de ejecutar nada.
///
/// Es distinto de `Paso` a proposito: el plan es texto visible y editable por
/// el dueno; el libro es lo que de verdad ocurrio. TASK.2 guarda el plan en la
/// tarea y deja el libro vacio hasta que TASK.3 conecte la ejecucion.
public struct PasoPlan: Codable, Identifiable, Equatable {
    public var id: UUID
    /// Numero visible, empezando en 1.
    public var orden: Int
    public var texto: String

    public init(id: UUID = UUID(), orden: Int, texto: String) {
        self.id = id
        self.orden = orden
        self.texto = texto
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case orden
        case texto
    }

    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        orden = try contenedor.decodeIfPresent(Int.self, forKey: .orden) ?? 1
        texto = try contenedor.decodeIfPresent(String.self, forKey: .texto) ?? ""
    }
}

/// Plan por pasos propuesto por el modelo.
///
/// Se guarda completo en la tarea: el texto crudo sirve para auditar lo que
/// respondio el modelo y `pasos` es la lista ya normalizada que pinta la vista.
public struct PlanTarea: Codable, Equatable {
    public var pasos: [PasoPlan]
    public var texto: String
    public var fecha: Date
    public var proveedorID: UUID?

    public init(
        pasos: [PasoPlan] = [],
        texto: String = "",
        fecha: Date = Date(),
        proveedorID: UUID? = nil
    ) {
        self.pasos = pasos
        self.texto = texto
        self.fecha = fecha
        self.proveedorID = proveedorID
    }

    public var estaVacio: Bool { pasos.isEmpty }

    /// Texto que se deja como mensaje en un chat cuando se usa /plan.
    public var textoParaChat: String {
        let lineas = pasos.map { "\($0.orden). \($0.texto)" }
        let cuerpo = lineas.isEmpty ? texto : lineas.joined(separator: "\n")
        return "Plan propuesto (sin ejecutar):\n\n\(cuerpo)"
    }

    /// Instrucciones del unico turno que genera un plan.
    ///
    /// POR QUE se pide "sin herramientas" en el texto y ademas se llama al
    /// motor con `herramientas: []`: el texto es la intencion para el modelo y
    /// el arreglo vacio es la garantia del payload. Aunque haya servidor MCP
    /// configurado, el plan se genera en modo solo-texto.
    public static let instrucciones = """
    Eres un planificador. Devuelve SOLO un plan por pasos numerados para la instrucción del usuario, en español, uno por línea. No ejecutes ninguna herramienta, no llames a herramientas y no incluyas llamadas ni resultados de herramientas. Cada paso debe ser una acción concreta y verificable. No añadas texto antes ni después del plan.
    """

    /// Mensajes del turno de planificacion. Se construyen en el nucleo para que
    /// la tarea y /plan usen exactamente el mismo mecanismo.
    public static func mensajesParaSolicitar(instruccion: String) -> [ChatMessage] {
        [
            ChatMessage(rol: .sistema, texto: instrucciones),
            ChatMessage(
                rol: .usuario,
                texto: instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ]
    }

    /// Convierte la respuesta del modelo en una lista de pasos.
    ///
    /// Acepta listas numeradas ("1.", "1)"), viñetas ("-", "*", "•") y el
    /// formato "Paso 1:". Si el modelo devuelve prosa sin lista, se conserva
    /// como un unico paso en vez de perder la respuesta. La normalizacion vive
    /// en el nucleo para poder probarla sin red.
    public static func desde(
        texto: String,
        proveedorID: UUID? = nil,
        fecha: Date = Date()
    ) -> PlanTarea {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else {
            return PlanTarea(texto: "", fecha: fecha, proveedorID: proveedorID)
        }

        var textos: [String] = []
        for linea in limpio.components(separatedBy: .newlines) {
            let recortada = linea.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recortada.isEmpty else { continue }

            if let sinPrefijo = sinPrefijoDeLista(recortada) {
                textos.append(sinPrefijo)
                continue
            }

            // Una cabecera suelta ("Plan:", "## Plan") no es un paso. Solo se
            // descarta mientras aun no ha empezado la lista; si aparece despues,
            // forma parte del texto del paso anterior y se conserva.
            if textos.isEmpty, esCabecera(recortada) {
                continue
            }

            textos.append(recortada)
        }

        let pasos = textos.enumerated().map { indice, contenido in
            PasoPlan(orden: indice + 1, texto: contenido)
        }
        return PlanTarea(
            pasos: pasos,
            texto: limpio,
            fecha: fecha,
            proveedorID: proveedorID
        )
    }

    /// Devuelve el texto de una linea de lista, o nil si la linea no lleva
    /// prefijo reconocible.
    private static func sinPrefijoDeLista(_ linea: String) -> String? {
        guard let primero = linea.first else { return nil }

        if "-*•".contains(primero) {
            let resto = String(linea.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return resto.isEmpty ? nil : resto
        }

        // "1. texto" o "1) texto".
        var indice = linea.startIndex
        while indice < linea.endIndex, linea[indice].isNumber {
            indice = linea.index(after: indice)
        }
        if indice > linea.startIndex,
           indice < linea.endIndex,
           linea[indice] == "." || linea[indice] == ")" {
            let resto = String(linea[linea.index(after: indice)...])
                .trimmingCharacters(in: .whitespaces)
            return resto.isEmpty ? nil : resto
        }

        // "Paso 1: texto".
        let minusculas = linea.lowercased()
        guard minusculas.hasPrefix("paso ") else { return nil }
        let trasPaso = String(linea.dropFirst(5))
            .trimmingCharacters(in: .whitespaces)
        var cursor = trasPaso.startIndex
        while cursor < trasPaso.endIndex, trasPaso[cursor].isNumber {
            cursor = trasPaso.index(after: cursor)
        }
        guard cursor > trasPaso.startIndex,
              cursor < trasPaso.endIndex,
              trasPaso[cursor] == ":" || trasPaso[cursor] == "." || trasPaso[cursor] == "-"
        else {
            return nil
        }
        let resto = String(trasPaso[trasPaso.index(after: cursor)...])
            .trimmingCharacters(in: .whitespaces)
        return resto.isEmpty ? nil : resto
    }

    private static func esCabecera(_ linea: String) -> Bool {
        if linea.hasPrefix("#") { return true }
        let minusculas = linea.lowercased()
        return minusculas == "plan" || minusculas == "plan:" || minusculas == "plan por pasos:"
    }

    private enum CodingKeys: String, CodingKey {
        case pasos
        case texto
        case fecha
        case proveedorID
    }

    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        pasos = try contenedor.decodeIfPresent([PasoPlan].self, forKey: .pasos) ?? []
        texto = try contenedor.decodeIfPresent(String.self, forKey: .texto) ?? ""
        fecha = try contenedor.decodeIfPresent(Date.self, forKey: .fecha) ?? Date()
        proveedorID = try contenedor.decodeIfPresent(UUID.self, forKey: .proveedorID)
    }
}

/// Una Tarea: instruccion del dueno, estado, plan y libro de ejecucion.
///
/// Es un modelo de NodoCore (Foundation puro) para que la app y `swift test`
/// compartan las mismas reglas. La persistencia vive en `TareaStore`, con un
/// archivo JSON por tarea, igual que las conversaciones.
public struct Tarea: Codable, Identifiable, Equatable {
    public var id: UUID
    public var instruccion: String
    public var estado: EstadoTarea
    /// Libro de ejecucion. Vacio en TASK.1/TASK.2: la ejecucion llega en TASK.3.
    public var pasos: [Paso]
    /// Plan por pasos que el dueno revisa antes de pulsar Empezar.
    public var plan: PlanTarea?
    /// Conversacion asociada, si la tarea nace desde un chat o se conecta a uno.
    /// En TASK.1/TASK.2 normalmente es nil: la tarea es un espacio propio.
    public var conversacionID: UUID?
    /// Proveedor con el que se genera el plan y, en TASK.3, se ejecutara.
    /// nil cae al proveedor activo de la app.
    public var proveedorID: UUID?
    public var fechaCreacion: Date
    public var fechaActualizacion: Date

    public init(
        id: UUID = UUID(),
        instruccion: String = "",
        estado: EstadoTarea = .borrador,
        pasos: [Paso] = [],
        plan: PlanTarea? = nil,
        conversacionID: UUID? = nil,
        proveedorID: UUID? = nil,
        fechaCreacion: Date = Date(),
        fechaActualizacion: Date = Date()
    ) {
        self.id = id
        self.instruccion = instruccion
        self.estado = estado
        self.pasos = pasos
        self.plan = plan
        self.conversacionID = conversacionID
        self.proveedorID = proveedorID
        self.fechaCreacion = fechaCreacion
        self.fechaActualizacion = fechaActualizacion
    }

    /// Titulo de una linea para la lista, derivado de la instruccion.
    public var titulo: String {
        let limpio = instruccion
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return "Tarea sin instrucción" }
        if limpio.count <= 60 { return limpio }
        return String(limpio.prefix(60)) + "..."
    }

    /// Pasos terminados sobre el total del LIBRO, o nil si aun no hay libro.
    ///
    /// nil no es cero: la vista no debe ensenar "0/0" como si hubiera ejecucion
    /// cuando lo unico que existe es el plan.
    public var progreso: (terminados: Int, total: Int)? {
        guard !pasos.isEmpty else { return nil }
        let terminados = pasos.filter { $0.estado == .terminado }.count
        return (terminados, pasos.count)
    }

    public var admiteEdicion: Bool { estado.admiteEdicion }

    private enum CodingKeys: String, CodingKey {
        case id
        case instruccion
        case estado
        case pasos
        case plan
        case conversacionID
        case proveedorID
        case fechaCreacion
        case fechaActualizacion
    }

    /// Decodificacion tolerante: una tarea escrita por una version anterior de
    /// la partida puede no traer plan, libro, proveedor o conversacion. Se leen
    /// como vacios en vez de impedir que arranque toda la lista.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decode(UUID.self, forKey: .id)
        instruccion = try contenedor.decodeIfPresent(String.self, forKey: .instruccion) ?? ""
        estado = try contenedor.decodeIfPresent(EstadoTarea.self, forKey: .estado) ?? .borrador
        pasos = try contenedor.decodeIfPresent([Paso].self, forKey: .pasos) ?? []
        plan = try contenedor.decodeIfPresent(PlanTarea.self, forKey: .plan)
        conversacionID = try contenedor.decodeIfPresent(UUID.self, forKey: .conversacionID)
        proveedorID = try contenedor.decodeIfPresent(UUID.self, forKey: .proveedorID)
        let creada = try contenedor.decodeIfPresent(Date.self, forKey: .fechaCreacion) ?? Date()
        fechaCreacion = creada
        fechaActualizacion = try contenedor.decodeIfPresent(
            Date.self,
            forKey: .fechaActualizacion
        ) ?? creada
    }
}
