import Foundation

import NodoCore

/// Estado de PRUEBA que la app siembra en memoria para una captura del simulador.
struct EstadoPrueba {
    let nombre: String
    let config: AppConfig
    let conversacion: Conversation
    let conversaciones: [Conversation]
    /// Clave de ejemplo que la Tarjeta de Bienvenida debe leer como guardada.
    ///
    /// En capturas no se escribe nada en el llavero del simulador: la clave
    /// vive solo en memoria mientras dura el test. nil deja la tarjeta en su
    /// estado honesto de "falta tu clave".
    let claveDePrueba: String?
    /// Si el motor determinista debe fallar al responder.
    ///
    /// Solo lo usa el estado `error-en-linea`: la app recorre su ruta normal de
    /// envio y la burbuja de error se pinta como consecuencia real del fallo.
    let motorFalla: Bool
    /// Tareas sembradas en memoria para la pestana Tareas.
    ///
    /// Vacio en casi todos los estados: solo `tarea-aprobacion-pendiente`
    /// necesita una tarea con libro y aprobacion viva.
    let tareas: [Tarea]
    /// Aprobacion vigente sembrada, si el estado la necesita.
    ///
    /// En un estado normal la crea el ToolLoop al pedir permiso; aqui se siembra
    /// para poder probar con toque real la tarjeta del hilo sin red ni motor.
    let solicitudAprobacion: SolicitudAprobacion?
    /// Hilo que el estado de prueba da por abierto.
    ///
    /// Es el mismo valor que deja `TareaView` al aparecer. Se siembra para que
    /// la red de seguridad de la raiz no presente la hoja modal encima de la
    /// tarjeta antes de que el test navegue a la tarea.
    let tareaEnPantalla: UUID?

    init(
        nombre: String,
        config: AppConfig,
        conversacion: Conversation,
        conversaciones: [Conversation],
        claveDePrueba: String? = nil,
        motorFalla: Bool = false,
        tareas: [Tarea] = [],
        solicitudAprobacion: SolicitudAprobacion? = nil,
        tareaEnPantalla: UUID? = nil
    ) {
        self.nombre = nombre
        self.config = config
        self.conversacion = conversacion
        self.conversaciones = conversaciones
        self.claveDePrueba = claveDePrueba
        self.motorFalla = motorFalla
        self.tareas = tareas
        self.solicitudAprobacion = solicitudAprobacion
        self.tareaEnPantalla = tareaEnPantalla
    }
}

/// Gancho de estados de prueba para la verificacion visual en CI (SPEC §6/H7).
///
/// POR QUE: la spec exige que cada fase se cierre con capturas del simulador
/// revisadas contra el contrato. Para que esas capturas sean deterministas y no
/// dependan de datos reales, los tests de UI arrancan la app con
/// `-CapturasPrueba -CapturasEstado <estado>`. Este archivo siembra en memoria
/// el estado minimo que necesita cada pantalla.
///
/// Sin `-CapturasPrueba` la app no lee nada de aqui y se comporta exactamente
/// como siempre. Los datos son genericos de ejemplo: no hay claves, precios ni
/// conversaciones de una persona real.
enum EstadosDePrueba {
    static let argumentoPrueba = "-CapturasPrueba"
    static let argumentoEstado = "-CapturasEstado"

    /// Estados que entienden los tests de captura.
    enum Estado: String, CaseIterable {
        case editorProveedor = "editor-proveedor"
        case ajustesTope = "ajustes-tope"
        case conversacionEjemplo = "conversacion-ejemplo"
        case historialEjemplo = "historial-ejemplo"
        /// Conversacion con historial, Memoria y los 4 combos del preset.
        case chat = "chat"
        /// Nombre heredado del antiguo modo Tarea: hoy siembra un chat normal
        /// con historial, porque el conmutador ya no existe.
        case tarea = "tarea"
        /// Chat vacio con la Tarjeta de Bienvenida y una clave de ejemplo.
        case bienvenida = "bienvenida"
        /// El mismo chat vacio, pero con la clave vacia (preset recien instalado).
        case bienvenidaSinClave = "bienvenida-sin-clave"
        /// Chat cuyo acumulado supera el tope, para la franja ambar.
        case tope = "tope"
        /// Chat vacio con un motor que falla al enviar, para el error en linea.
        case errorEnLinea = "error-en-linea"
        /// Mi Contexto con Memoria, tope, skills y contadores de ejemplo.
        case miContexto = "mi-contexto"
        /// Tarea en curso con una aprobacion pendiente en el hilo (deuda M2).
        ///
        /// Es el unico estado que siembra tareas: existe para probar con toque
        /// real que la tarjeta de aprobacion se pinta junto a su fila y que sus
        /// dos botones resuelven la decision.
        case tareaAprobacionPendiente = "tarea-aprobacion-pendiente"
    }

    /// Devuelve el estado pedido por los argumentos de lanzamiento, o nil si la
    /// app se esta abriendo de forma normal.
    static func estadoSolicitado(
        argumentos: [String] = ProcessInfo.processInfo.arguments
    ) -> EstadoPrueba? {
        guard argumentos.contains(argumentoPrueba) else { return nil }

        let nombre = valorDeEstado(en: argumentos)
        let estado = Estado(rawValue: nombre ?? "") ?? .editorProveedor
        return datos(para: estado)
    }

    /// Acepta `-CapturasPrueba -CapturasEstado <estado>` y, por comodidad,
    /// tambien `-CapturasPrueba <estado>`.
    private static func valorDeEstado(en argumentos: [String]) -> String? {
        if let indice = argumentos.firstIndex(of: argumentoEstado),
           argumentos.indices.contains(indice + 1) {
            return argumentos[indice + 1]
        }

        if let indice = argumentos.firstIndex(of: argumentoPrueba),
           argumentos.indices.contains(indice + 1) {
            let siguiente = argumentos[indice + 1]
            if !siguiente.hasPrefix("-") { return siguiente }
        }

        return nil
    }

    // MARK: - Datos de ejemplo

    private static func id(_ texto: String) -> UUID {
        UUID(uuidString: texto) ?? UUID()
    }

    private static let fechaFija = Date(timeIntervalSince1970: 1_700_000_000)

    /// Proveedor de ejemplo SIN clave real y con precios genericos de ejemplo.
    private static let proveedorEjemplo = ProviderConfig(
        id: id("00000000-0000-0000-0000-000000000001"),
        nombre: "Proveedor de ejemplo",
        protocolo: .chatCompletions,
        baseURL: "https://api.ejemplo.test/v1",
        modelo: "modelo-de-ejemplo",
        precioEntradaPorMillon: 0.10,
        precioSalidaPorMillon: 0.20
    )

    /// Proveedor activo del preset de fabrica que usan los estados `chat` y
    /// `tope`; las filas del historial necesitan el id del chat para resolver
    /// su modelo y su costo (§3.1).
    private static let proveedorChatID = id("11111111-1111-4111-8111-111111111111")

    private static let conversacionEjemplo: Conversation = Conversation(
        id: id("00000000-0000-0000-0000-000000000002"),
        titulo: "Conversacion de ejemplo",
        mensajes: [
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000003"),
                rol: .usuario,
                texto: "Mensaje de ejemplo",
                fecha: fechaFija
            ),
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000004"),
                rol: .asistente,
                texto: "Respuesta de ejemplo",
                fecha: fechaFija.addingTimeInterval(1),
                tokensEntrada: 12,
                tokensSalida: 24
            )
        ],
        creada: fechaFija,
        actualizada: fechaFija.addingTimeInterval(1),
        proveedorID: proveedorEjemplo.id
    )

    /// Conversacion fijada para la captura del historial: aunque su actividad
    /// es anterior, el orden del nucleo la deja arriba.
    private static let conversacionFijada: Conversation = Conversation(
        id: id("00000000-0000-0000-0000-000000000008"),
        titulo: "Conversacion fijada de ejemplo",
        mensajes: [
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000009"),
                rol: .usuario,
                texto: "Mensaje de la conversacion fijada.",
                fecha: fechaFija.addingTimeInterval(-100)
            ),
            ChatMessage(
                id: id("00000000-0000-0000-0000-00000000000A"),
                rol: .asistente,
                texto: "Respuesta fijada de ejemplo.",
                fecha: fechaFija.addingTimeInterval(-99),
                tokensEntrada: 400,
                tokensSalida: 100
            )
        ],
        creada: fechaFija.addingTimeInterval(-100),
        actualizada: fechaFija.addingTimeInterval(-99),
        fijada: true,
        proveedorID: proveedorEjemplo.id
    )

    private static let conversacionArchivada: Conversation = Conversation(
        id: id("00000000-0000-0000-0000-000000000005"),
        titulo: "Conversacion archivada de ejemplo",
        mensajes: [
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000006"),
                rol: .usuario,
                texto: "Mensaje de ejemplo",
                fecha: fechaFija
            )
        ],
        creada: fechaFija,
        actualizada: fechaFija,
        archivada: true,
        proveedorID: proveedorEjemplo.id
    )

    /// Conversacion del estado `chat`: dos turnos de ejemplo y consumo medido
    /// en la ultima respuesta, para que la pildora, el Estado del chat y el
    /// divisor del cambio de modelo tengan algo real que ensenar.
    private static let conversacionChat: Conversation = Conversation(
        id: id("00000000-0000-0000-0000-000000000020"),
        titulo: "Chat de ejemplo",
        mensajes: [
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000021"),
                rol: .usuario,
                texto: "Hola, primer mensaje de ejemplo.",
                fecha: fechaFija
            ),
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000022"),
                rol: .asistente,
                texto: "Respuesta de ejemplo: aquí estoy para ayudarte.",
                fecha: fechaFija.addingTimeInterval(1)
            ),
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000023"),
                rol: .usuario,
                texto: "Segundo mensaje de ejemplo.",
                fecha: fechaFija.addingTimeInterval(2)
            ),
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000024"),
                rol: .asistente,
                texto: "Segunda respuesta de ejemplo con el consumo del chat.",
                fecha: fechaFija.addingTimeInterval(3),
                tokensEntrada: 1200,
                tokensSalida: 300
            )
        ],
        creada: fechaFija,
        actualizada: fechaFija.addingTimeInterval(3),
        proveedorID: proveedorChatID
    )

    /// Chat vacio de la Tarjeta de Bienvenida. El titulo coincide con el de los
    /// demas estados para que el test lo abra con la misma ruta de navegacion.
    private static let conversacionVaciaBienvenida: Conversation = Conversation(
        id: id("00000000-0000-0000-0000-000000000030"),
        titulo: "Chat de ejemplo",
        mensajes: [],
        creada: fechaFija,
        actualizada: fechaFija
    )

    /// Chat con consumo alto: 2.000.000 de entrada y 1.000.000 de salida con
    /// los precios del preset dan $0.18, por encima del tope de $0.10 del
    /// estado `tope`. Las cifras son de ejemplo, no de una persona real.
    private static let conversacionTope: Conversation = Conversation(
        id: id("00000000-0000-0000-0000-000000000040"),
        titulo: "Chat de ejemplo",
        mensajes: [
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000041"),
                rol: .usuario,
                texto: "Mensaje de ejemplo para el tope.",
                fecha: fechaFija
            ),
            ChatMessage(
                id: id("00000000-0000-0000-0000-000000000042"),
                rol: .asistente,
                texto: "Respuesta de ejemplo con consumo alto.",
                fecha: fechaFija.addingTimeInterval(1),
                tokensEntrada: 2_000_000,
                tokensSalida: 1_000_000
            )
        ],
        creada: fechaFija,
        actualizada: fechaFija.addingTimeInterval(1),
        proveedorID: proveedorChatID
    )

    /// Tarea sembrada para la prueba CON TOQUE de la aprobacion en el hilo.
    ///
    /// El libro tiene dos pasos: el primero ya cerro con su costo sellado y el
    /// segundo espera la decision. `estadoVisibleDePaso` proyecta esa fila como
    /// «Esperando aprobación» porque `aprobacion == .pendiente`, que es la
    /// misma condicion que usa el ToolLoop real.
    private static let tareaAprobacionPendiente: Tarea = {
        let plan = PlanTarea(
            pasos: [
                PasoPlan(orden: 1, texto: "Preparar el material de ejemplo."),
                PasoPlan(orden: 2, texto: "Leer el enlace de ejemplo.")
            ],
            texto: "1. Preparar el material de ejemplo.\n"
                + "2. Leer el enlace de ejemplo.",
            fecha: fechaFija,
            proveedorID: proveedorChatID,
            version: 1
        )

        return Tarea(
            id: id("00000000-0000-0000-0000-000000000050"),
            instruccion: "Revisar el material de ejemplo",
            estado: .enCurso,
            pasos: [
                Paso(
                    id: id("00000000-0000-0000-0000-000000000052"),
                    descripcion: "Preparar el material de ejemplo.",
                    estado: .terminado,
                    herramienta: "traer_url",
                    argumentos: #"{"url":"https://ejemplo.test/material"}"#,
                    resultado: "Material de ejemplo preparado.",
                    url: "https://ejemplo.test/material",
                    costoUSD: 0.012,
                    fechaInicio: fechaFija,
                    fechaFin: fechaFija.addingTimeInterval(2)
                ),
                Paso(
                    id: id("00000000-0000-0000-0000-000000000053"),
                    descripcion: "Leer el enlace de ejemplo.",
                    estado: .pendiente,
                    herramienta: "traer_url",
                    argumentos: #"{"url":"https://ejemplo.test/informe"}"#,
                    url: "https://ejemplo.test/informe",
                    aprobacion: .pendiente,
                    fechaInicio: fechaFija.addingTimeInterval(3)
                )
            ],
            plan: plan,
            proveedorID: proveedorChatID,
            costoAcumuladoUSD: 0.012,
            fechaCreacion: fechaFija,
            fechaActualizacion: fechaFija.addingTimeInterval(3),
            turnos: [
                TurnoTarea(
                    id: id("00000000-0000-0000-0000-000000000054"),
                    rol: .usuario,
                    texto: "Revisar el material de ejemplo",
                    fecha: fechaFija
                )
            ]
        )
    }()

    /// Solicitud vigente de la tarea sembrada.
    ///
    /// No hay ToolLoop vivo: el estado de prueba la siembra tal como la deja
    /// `pedirAprobacion` antes de esperar la decision del dueno.
    private static let solicitudAprobacionPendiente = SolicitudAprobacion(
        id: id("00000000-0000-0000-0000-000000000051"),
        tareaID: id("00000000-0000-0000-0000-000000000050"),
        herramienta: "traer_url",
        descripcion: "Leer el enlace de ejemplo",
        detalle: #"{"url":"https://ejemplo.test/informe"}"#
    )

    /// Memoria de ejemplo que se inyecta en el estado `chat`.
    private static let memoriaDeEjemplo = """
    Memoria de ejemplo: responde en español, con frases cortas y sin tecnicismos.
    """

    /// Configuracion del estado `chat`: los 4 combos del preset InferHub, sin
    /// clave, con precios de ejemplo y una Memoria con texto. El tope se puede
    /// bajar para el estado de la franja ambar.
    private static func configuracionChat(tope: Double = 1.00) -> AppConfig {
        var config = AppConfig.inicial()
        config.memoria = Memoria.entradasDesdeTextoLegado(memoriaDeEjemplo)
        config.topeAvisoCosto = tope
        return config
    }

    /// Configuracion del estado `mi-contexto`: Memoria con texto, tope 0.25
    /// (para que el boton vigente se vea marcado), dos skills con su slug y
    /// contadores globales con cifras de ejemplo.
    private static func configuracionMiContexto() -> AppConfig {
        var config = configuracionChat(tope: 0.25)
        config.skills = [
            SkillLocal(
                nombre: "Resumidor",
                slug: "resumidor",
                instrucciones: "Resume el texto en tres puntos claros."
            ),
            SkillLocal(
                nombre: "Ventas",
                slug: "ventas",
                instrucciones: "Responde con tono comercial y sin tecnicismos."
            )
        ]
        config.gasto = ContadoresGasto(
            delDia: 0.1234,
            fechaDelDia: hoyComoClave(),
            desdeReinicio: 0.4321
        )

        // Libro de sellos de ejemplo para que la tarjeta y la vista Gasto
        // tengan algo que ensenar en las capturas. No toca los contadores:
        // estos siguen siendo la cifra del acumulador de siempre.
        let ahora = Date()
        var libro = UsoApp()
        libro.registrar(
            uso: UsoTokens(entrada: 420_000, salida: 80_000),
            usd: 0.0894,
            fecha: ahora,
            modelo: proveedorEjemplo.modelo
        )
        libro.registrar(
            uso: UsoTokens(entrada: 260_000, salida: 40_000),
            usd: 0.034,
            fecha: ahora,
            modelo: "otro-modelo-de-ejemplo"
        )
        if let antes = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -1,
            to: ahora
        ) {
            libro.registrar(
                uso: UsoTokens(entrada: 900_000, salida: 150_000),
                usd: 0.12,
                fecha: antes,
                modelo: proveedorEjemplo.modelo
            )
        }
        // Un uso sin precio: tokens reales, dolar desconocido.
        libro.registrar(
            uso: UsoTokens(entrada: 12_000, salida: 3_000),
            usd: 0,
            fecha: ahora,
            modelo: "modelo-sin-precios",
            conPrecio: false
        )
        config.usoApp = libro
        return config
    }

    /// Fecha local de hoy con el mismo formato que guarda `ContadoresGasto`.
    private static func hoyComoClave() -> String {
        let formateador = DateFormatter()
        formateador.calendar = Calendar(identifier: .gregorian)
        formateador.locale = Locale(identifier: "en_US_POSIX")
        formateador.dateFormat = "yyyy-MM-dd"
        return formateador.string(from: Date())
    }

    private static func configuracion(tope: Double = 1.00) -> AppConfig {
        AppConfig(
            proveedores: [proveedorEjemplo],
            proveedorActivo: proveedorEjemplo.id,
            memoria: Memoria.entradasDesdeTextoLegado(
                "Memoria de ejemplo para las capturas."
            ),
            servidor: ServerConfig(
                nombre: "Servidor de ejemplo",
                url: "",
                activo: false
            ),
            topeAvisoCosto: tope
        )
    }

    private static func datos(para estado: Estado) -> EstadoPrueba {
        switch estado {
        case .editorProveedor:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracion(),
                conversacion: conversacionEjemplo,
                conversaciones: [conversacionEjemplo]
            )
        case .ajustesTope:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracion(tope: 1.00),
                conversacion: conversacionEjemplo,
                conversaciones: [conversacionEjemplo]
            )
        case .conversacionEjemplo:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracion(),
                conversacion: conversacionEjemplo,
                conversaciones: [conversacionEjemplo]
            )
        case .historialEjemplo:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracion(),
                conversacion: conversacionEjemplo,
                conversaciones: [
                    conversacionFijada,
                    conversacionEjemplo,
                    conversacionArchivada
                ]
            )
        case .chat:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                conversacion: conversacionChat,
                conversaciones: [conversacionChat]
            )
        case .tarea:
            // El estado conserva nombre, id y titulo para no romper los
            // argumentos de captura, pero ya es un chat normal CON historial:
            // el conmutador Chat | Tarea y su bandera desaparecieron.
            var normal = conversacionChat
            normal.id = id("00000000-0000-0000-0000-000000000007")
            normal.titulo = "Tarea de ejemplo"
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                conversacion: normal,
                conversaciones: [normal]
            )
        case .bienvenida:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                conversacion: conversacionVaciaBienvenida,
                conversaciones: [conversacionVaciaBienvenida],
                claveDePrueba: "clave-de-ejemplo"
            )
        case .bienvenidaSinClave:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                conversacion: conversacionVaciaBienvenida,
                conversaciones: [conversacionVaciaBienvenida]
            )
        case .tope:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(tope: 0.10),
                conversacion: conversacionTope,
                conversaciones: [conversacionTope]
            )
        case .errorEnLinea:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                conversacion: conversacionVaciaBienvenida,
                conversaciones: [conversacionVaciaBienvenida],
                motorFalla: true
            )
        case .miContexto:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionMiContexto(),
                conversacion: conversacionVaciaBienvenida,
                conversaciones: [conversacionVaciaBienvenida]
            )
        case .tareaAprobacionPendiente:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                // El chat abierto no importa: la prueba navega a Tareas.
                conversacion: conversacionVaciaBienvenida,
                conversaciones: [conversacionVaciaBienvenida],
                tareas: [tareaAprobacionPendiente],
                solicitudAprobacion: solicitudAprobacionPendiente,
                // Mismo valor que deja `TareaView` al abrir el hilo: la hoja
                // modal de la raiz no tapa la tarjeta que se quiere probar.
                tareaEnPantalla: tareaAprobacionPendiente.id
            )
        }
    }
}
