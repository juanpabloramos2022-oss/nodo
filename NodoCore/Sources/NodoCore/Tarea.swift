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
/// TASK.3 lo usa como el diario real de la tarea: cada evento del ToolLoop
/// nace como pendiente/en curso y termina como terminado, fallido o denegado.
public enum EstadoPaso: String, Codable, CaseIterable, Identifiable, Equatable {
    case pendiente
    case enCurso
    case terminado
    case fallido
    /// El dueno rechazo la escritura propuesta. El paso queda en el libro como
    /// constancia y la herramienta NO se ejecuto.
    case denegado

    public var id: String { rawValue }

    public var titulo: String {
        switch self {
        case .pendiente: return "Pendiente"
        case .enCurso: return "En curso"
        case .terminado: return "Terminado"
        case .fallido: return "Fallido"
        case .denegado: return "Denegado"
        }
    }

    /// True cuando el paso ya no puede cambiar por si solo: es historia.
    public var estaResuelto: Bool {
        self == .terminado || self == .fallido || self == .denegado
    }
}

/// Resultado de la hoja de aprobacion para un paso concreto.
///
/// Se guarda aparte de `EstadoPaso` porque un paso puede estar pendiente de
/// aprobacion sin estar todavia en ejecucion, y una denegacion es un estado del
/// paso distinto de un fallo tecnico.
public enum EstadoAprobacion: String, Codable, CaseIterable, Equatable {
    case pendiente
    case aprobada
    case denegada

    public var titulo: String {
        switch self {
        case .pendiente: return "Esperando aprobación"
        case .aprobada: return "Aprobada"
        case .denegada: return "Denegada"
        }
    }
}

/// Un paso del libro de ejecucion.
///
/// TASK.3 lo completa: cada evento real del ToolLoop crea o actualiza un paso y
/// lo persiste en el acto. Los campos nuevos tienen decodificacion tolerante
/// para que un archivo escrito por TASK.1/TASK.2 siga abriendo sin migrarlo.
public struct Paso: Codable, Identifiable, Equatable {
    public var id: UUID
    public var descripcion: String
    public var estado: EstadoPaso
    /// Nombre de la herramienta que se ejecuto (nil en pasos de error final).
    public var herramienta: String?
    /// Argumentos JSON crudos que pidio el modelo. Se guardan para poder
    /// reanudar sin repetir la llamada y para mostrar el detalle en la hoja.
    public var argumentos: String?
    /// Resultado que recibio el modelo. Es la prueba de lo que paso.
    public var resultado: String?
    /// Id de la llamada del modelo. Es lo que enlaza el evento del ToolLoop con
    /// su paso aunque el orden de la lista cambie.
    public var llamadaID: String?
    /// URL cuando la herramienta fue `traer_url`; el panel de enlaces la usa.
    public var url: String?
    /// Estado de la hoja de aprobacion, o nil si la herramienta no la pidio.
    public var aprobacion: EstadoAprobacion?
    /// Fase de la tuberia /boost a la que pertenece el paso.
    ///
    /// nil es un paso de una tarea normal. Se guarda en el paso, y no en un
    /// arreglo aparte, para que el libro siga siendo la unica fuente de verdad:
    /// una fase es un paso visible mas, con su estado y su costo.
    public var fase: FaseBoost?
    /// Numero visible del angulo (1-based) cuando `fase == .angulo`.
    public var numeroAngulo: Int?
    /// Proveedor que genero este paso. Sin el no se puede auditar que angulo
    /// corrio con cada combo ni sellar su costo con los precios correctos.
    public var proveedorID: UUID?
    /// Nombre visible del proveedor en el momento de la llamada.
    ///
    /// Se copia, no se resuelve al pintar: si el dueno renombra o borra el
    /// proveedor despues, el libro tiene que seguir contando con que combo se
    /// hizo cada fase.
    public var proveedorNombre: String?
    /// Costo sellado de ESTA fase (COST). nil = no valorable, que no es cero.
    public var costoUSD: Double?
    public var fechaInicio: Date?
    public var fechaFin: Date?

    public init(
        id: UUID = UUID(),
        descripcion: String = "",
        estado: EstadoPaso = .pendiente,
        herramienta: String? = nil,
        argumentos: String? = nil,
        resultado: String? = nil,
        llamadaID: String? = nil,
        url: String? = nil,
        aprobacion: EstadoAprobacion? = nil,
        fase: FaseBoost? = nil,
        numeroAngulo: Int? = nil,
        proveedorID: UUID? = nil,
        proveedorNombre: String? = nil,
        costoUSD: Double? = nil,
        fechaInicio: Date? = nil,
        fechaFin: Date? = nil
    ) {
        self.id = id
        self.descripcion = descripcion
        self.estado = estado
        self.herramienta = herramienta
        self.argumentos = argumentos
        self.resultado = resultado
        self.llamadaID = llamadaID
        self.url = url
        self.aprobacion = aprobacion
        self.fase = fase
        self.numeroAngulo = numeroAngulo
        self.proveedorID = proveedorID
        self.proveedorNombre = proveedorNombre
        self.costoUSD = costoUSD
        self.fechaInicio = fechaInicio
        self.fechaFin = fechaFin
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case descripcion
        case estado
        case herramienta
        case argumentos
        case resultado
        case llamadaID
        case url
        case aprobacion
        case fase
        case numeroAngulo
        case proveedorID
        case proveedorNombre
        case costoUSD
        case fechaInicio
        case fechaFin
    }

    /// Decodificacion tolerante con los pasos escritos por una version
    /// intermedia: un archivo sin estado se lee como pendiente y los campos
    /// nuevos se leen como vacios.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        descripcion = try contenedor.decodeIfPresent(String.self, forKey: .descripcion) ?? ""
        estado = try contenedor.decodeIfPresent(EstadoPaso.self, forKey: .estado) ?? .pendiente
        herramienta = try contenedor.decodeIfPresent(String.self, forKey: .herramienta)
        argumentos = try contenedor.decodeIfPresent(String.self, forKey: .argumentos)
        resultado = try contenedor.decodeIfPresent(String.self, forKey: .resultado)
        llamadaID = try contenedor.decodeIfPresent(String.self, forKey: .llamadaID)
        url = try contenedor.decodeIfPresent(String.self, forKey: .url)
        aprobacion = try contenedor.decodeIfPresent(EstadoAprobacion.self, forKey: .aprobacion)
        fase = try contenedor.decodeIfPresent(FaseBoost.self, forKey: .fase)
        numeroAngulo = try contenedor.decodeIfPresent(Int.self, forKey: .numeroAngulo)
        proveedorID = try contenedor.decodeIfPresent(UUID.self, forKey: .proveedorID)
        proveedorNombre = try contenedor.decodeIfPresent(String.self, forKey: .proveedorNombre)
        costoUSD = try contenedor.decodeIfPresent(Double.self, forKey: .costoUSD)
        fechaInicio = try contenedor.decodeIfPresent(Date.self, forKey: .fechaInicio)
        fechaFin = try contenedor.decodeIfPresent(Date.self, forKey: .fechaFin)
    }

    /// Etiqueta de fase para el libro: "Orquestación", "Ángulo 2", "Síntesis".
    ///
    /// Vive en el nucleo, no en la vista, para que la app y los tests nombren
    /// las fases igual y una tarea normal (sin fase) no pinte nada.
    public var etiquetaDeFase: String? {
        guard let fase else { return nil }
        if fase == .angulo, let numeroAngulo {
            return "Ángulo \(numeroAngulo)"
        }
        return fase.titulo
    }

    /// Resumen corto del resultado para el panel. El libro conserva el texto
    /// completo; la vista no necesita pintar una pagina entera.
    public func resultadoResumido(limite: Int = 240) -> String? {
        guard let resultado else { return nil }
        let limpio = resultado
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return nil }
        if limpio.count <= limite { return limpio }
        return String(limpio.prefix(limite)) + "…"
    }
}

/// Un paso del PLAN que el modelo propone antes de ejecutar nada.
///
/// Es distinto de `Paso` a proposito: el plan es texto visible y editable por
/// el dueno; el libro es lo que de verdad ocurrio. TASK.2 guarda el plan en la
/// tarea y TASK.3 lo ejecuta y llena el libro.
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
    /// Libro de ejecucion: lo que de verdad ocurrio, persistido paso a paso.
    public var pasos: [Paso]
    /// Plan por pasos que el dueno revisa antes de pulsar Empezar.
    public var plan: PlanTarea?
    /// Conversacion asociada, si la tarea nace desde un chat o se conecta a uno.
    /// En TASK.1/TASK.2 normalmente es nil: la tarea es un espacio propio.
    public var conversacionID: UUID?
    /// Proveedor con el que se genera el plan y, en TASK.3, se ejecutara.
    /// nil cae al proveedor activo de la app.
    public var proveedorID: UUID?
    /// Costo sellado de las llamadas al modelo hechas DENTRO de la tarea.
    ///
    /// Se acumula llamada a llamada con el mecanismo COST (precios del
    /// proveedor en el momento de la respuesta). nil significa que aun no hay
    /// consumo valorable; no se escribe cero porque un costo desconocido no es
    /// un costo gratis.
    public var costoAcumuladoUSD: Double?
    /// Respuesta final de la tarea.
    ///
    /// TASK no la guardaba porque el ToolLoop escribia en el chat; la tuberia
    /// /boost no tiene chat, asi que su unica salida visible es esta. Se guarda
    /// tambien en tareas normales para que el libro no sea la unica memoria.
    public var resultado: String?
    /// True SOLO si la sintesis de la tuberia /boost corrio y cerro.
    ///
    /// Frontera honesta: significa que la respuesta final paso por contraste
    /// cruzado entre modelos, no que se hayan ejecutado pruebas. Sin sintesis
    /// (detenida por tope, fallo o Detener) se queda en false.
    public var verificadoPorCruce: Bool
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
        costoAcumuladoUSD: Double? = nil,
        resultado: String? = nil,
        verificadoPorCruce: Bool = false,
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
        self.costoAcumuladoUSD = costoAcumuladoUSD
        self.resultado = resultado
        self.verificadoPorCruce = verificadoPorCruce
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

    /// True cuando la instruccion arranca con /boost.
    ///
    /// El disparo se deriva SIEMPRE del texto guardado y no de una bandera
    /// aparte: una tarea escrita antes de existir /boost no puede quedar
    /// marcada por accidente, y editar la instruccion cambia el modo sin
    /// migrar el archivo.
    public var esDeBoost: Bool {
        AnalizadorComandos.instruccionDeBoost(instruccion) != nil
    }

    /// Instruccion sin el prefijo /boost: el problema real que se resuelve.
    ///
    /// El prefijo es el disparo, no parte del encargo. Se quita antes de pedir
    /// el plan y antes de orquestar para que el modelo no reciba una palabra
    /// que no significa nada para el.
    public var instruccionEfectiva: String {
        let limpia = instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resto = AnalizadorComandos.instruccionDeBoost(limpia) else {
            return limpia
        }
        return resto
    }

    /// Costo total de la tuberia /boost: la suma de los sellos de fase.
    ///
    /// nil si no hay ninguna fase sellada o si alguna quedo sin valorar: una
    /// suma parcial seria una cifra inventada, igual que en COST.
    public var costoBoostUSD: Double? {
        let fases = pasos.filter { $0.fase != nil }
        guard !fases.isEmpty else { return nil }
        var total = 0.0
        for fase in fases {
            guard let costo = fase.costoUSD else { return nil }
            total += costo
        }
        return total
    }

    /// Instruccion de sistema del turno de EJECUCION de una tarea.
    ///
    /// El plan ya esta aprobado: el modelo no vuelve a planificar, ejecuta. Se
    /// le dice que el libro manda y que no repita lo ya terminado para que una
    /// reanudacion no empiece de cero.
    public static let instruccionesEjecucion = """
    Estás ejecutando una tarea autorizada por el dueño. No vuelvas a planificar: ejecuta la instrucción con las herramientas disponibles. Cada herramienta que llames queda registrada en el libro de la tarea. Si una herramienta devuelve un error, corrígelo o explica el bloqueo; no inventes resultados. Cuando termines, da una respuesta final breve en español.
    """

    /// Texto del mensaje de usuario que abre la ejecucion.
    public static func mensajeDeEjecucion(_ tarea: Tarea) -> String {
        var lineas: [String] = [
            "Instrucción:",
            tarea.instruccionEfectiva
        ]

        if let plan = tarea.plan, !plan.pasos.isEmpty {
            lineas.append("")
            lineas.append("Plan aprobado:")
            for paso in plan.pasos {
                lineas.append("\(paso.orden). \(paso.texto)")
            }
        }
        return lineas.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case instruccion
        case estado
        case pasos
        case plan
        case conversacionID
        case proveedorID
        case costoAcumuladoUSD
        case resultado
        case verificadoPorCruce
        case fechaCreacion
        case fechaActualizacion
    }

    /// Decodificacion tolerante: una tarea escrita por una version anterior de
    /// la partida puede no traer plan, libro, proveedor, costo o conversacion.
    /// Se leen como vacios en vez de impedir que arranque toda la lista.
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decode(UUID.self, forKey: .id)
        instruccion = try contenedor.decodeIfPresent(String.self, forKey: .instruccion) ?? ""
        estado = try contenedor.decodeIfPresent(EstadoTarea.self, forKey: .estado) ?? .borrador
        pasos = try contenedor.decodeIfPresent([Paso].self, forKey: .pasos) ?? []
        plan = try contenedor.decodeIfPresent(PlanTarea.self, forKey: .plan)
        conversacionID = try contenedor.decodeIfPresent(UUID.self, forKey: .conversacionID)
        proveedorID = try contenedor.decodeIfPresent(UUID.self, forKey: .proveedorID)
        costoAcumuladoUSD = try contenedor.decodeIfPresent(
            Double.self,
            forKey: .costoAcumuladoUSD
        )
        resultado = try contenedor.decodeIfPresent(String.self, forKey: .resultado)
        verificadoPorCruce = try contenedor.decodeIfPresent(
            Bool.self,
            forKey: .verificadoPorCruce
        ) ?? false
        let creada = try contenedor.decodeIfPresent(Date.self, forKey: .fechaCreacion) ?? Date()
        fechaCreacion = creada
        fechaActualizacion = try contenedor.decodeIfPresent(
            Date.self,
            forKey: .fechaActualizacion
        ) ?? creada
    }
}
