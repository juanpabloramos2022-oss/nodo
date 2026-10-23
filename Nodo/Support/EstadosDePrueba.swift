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

    init(
        nombre: String,
        config: AppConfig,
        conversacion: Conversation,
        conversaciones: [Conversation],
        claveDePrueba: String? = nil,
        motorFalla: Bool = false
    ) {
        self.nombre = nombre
        self.config = config
        self.conversacion = conversacion
        self.conversaciones = conversaciones
        self.claveDePrueba = claveDePrueba
        self.motorFalla = motorFalla
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
        actualizada: fechaFija.addingTimeInterval(1)
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
        archivada: true
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
        actualizada: fechaFija.addingTimeInterval(3)
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
        actualizada: fechaFija.addingTimeInterval(1)
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
        config.systemPrompt = memoriaDeEjemplo
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
            systemPrompt: "Memoria de ejemplo para las capturas.",
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
                conversaciones: [conversacionEjemplo, conversacionArchivada]
            )
        case .chat:
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracionChat(),
                conversacion: conversacionChat,
                conversaciones: [conversacionChat]
            )
        case .tarea:
            let conversacionTarea = Conversation(
                id: id("00000000-0000-0000-0000-000000000007"),
                titulo: "Tarea de ejemplo",
                mensajes: [],
                creada: fechaFija,
                actualizada: fechaFija,
                modoTarea: true
            )
            return EstadoPrueba(
                nombre: estado.rawValue,
                config: configuracion(),
                conversacion: conversacionTarea,
                conversaciones: [conversacionTarea]
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
        }
    }
}
