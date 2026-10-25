import Foundation
import SwiftUI

import NodoCore

/// Consumo que /compact saco del hilo, agrupado por el proveedor que lo genero.
///
/// POR QUE no basta un `UsoTokens`: la factura de esos mensajes ya no puede
/// revaluarse cuando el usuario cambia de modelo. Se guarda el uso de cada
/// proveedor por separado y, en datos viejos sin atribucion, la clave vacia se
/// valora con el proveedor registrado del chat.
///
/// COST.1/HP4: ademas del uso, el balde guarda el USD ya SELLADO de todo lo que
/// resumio (los sellos de los mensajes que salieron mas el de la propia llamada
/// de resumen). Asi el acumulado del chat es sellos vivos + sello del balde y
/// no pierde un centavo al compactar.
private struct UsoResumido: Codable, Equatable {
    /// Uso por proveedor, con su UUID en texto. La clave "" es el respaldo de
    /// los archivos escritos antes de existir esta atribucion.
    var porProveedor: [String: UsoTokens] = [:]
    /// USD sellado de lo compactado. nil en los baldes escritos antes de
    /// existir el sello: esos se valoran por proveedor como respaldo
    /// transitorio, igual que los mensajes legados.
    var costoSelladoUSD: Double?
    /// True si parte del sello del balde es una estimacion de legado. El
    /// rotulo de la Hoja Estado tiene que seguir avisando despues de compactar.
    var costoEsEstimacion: Bool
    /// Marca heredada del formato de v0.3.0.
    ///
    /// Se conserva solo para decodificar los baldes que ya la traen escrita.
    /// Ninguna carga la usa para podar mensajes: la migracion de huerfanos se
    /// retiro y el historial no se toca al arrancar.
    var migradoDeV030: Bool
    /// True si el JSON de origen no traia el campo de sello. Es transitorio:
    /// se calcula al decodificar y no se guarda, porque describe el archivo
    /// leido, no el balde en memoria.
    var sinSelloEnDisco: Bool = false

    static let sinProveedor = ""

    init(
        porProveedor: [String: UsoTokens] = [:],
        costoSelladoUSD: Double? = nil,
        costoEsEstimacion: Bool = false,
        migradoDeV030: Bool = false
    ) {
        self.porProveedor = porProveedor
        self.costoSelladoUSD = costoSelladoUSD
        self.costoEsEstimacion = costoEsEstimacion
        self.migradoDeV030 = migradoDeV030
    }

    private enum CodingKeys: String, CodingKey {
        case porProveedor
        case costoSelladoUSD
        case costoEsEstimacion
        case migradoDeV030
    }

    /// Decodificacion tolerante con los baldes guardados antes de COST.1.
    ///
    /// `porProveedor` se exige a proposito: el formato aun mas viejo (solo
    /// tokens) no lo trae y debe caer al lector de respaldo de
    /// `usosResumidosGuardados`, no leerse como un balde vacio.
    init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        porProveedor = try contenedor.decode(
            [String: UsoTokens].self,
            forKey: .porProveedor
        )
        // El formato de v0.3.0 no tenia `costoSelladoUSD`. La marca se conserva
        // solo como dato de lectura: ya no dispara ninguna poda de mensajes.
        sinSelloEnDisco = !contenedor.contains(.costoSelladoUSD)
        costoSelladoUSD = try contenedor.decodeIfPresent(
            Double.self,
            forKey: .costoSelladoUSD
        )
        costoEsEstimacion = try contenedor.decodeIfPresent(
            Bool.self,
            forKey: .costoEsEstimacion
        ) ?? false
        migradoDeV030 = try contenedor.decodeIfPresent(
            Bool.self,
            forKey: .migradoDeV030
        ) ?? false
    }

    var total: UsoTokens {
        porProveedor.values.reduce(UsoTokens()) { $0.sumando($1) }
    }

    mutating func sumar(_ uso: UsoTokens, proveedorID: UUID?) {
        let clave = proveedorID?.uuidString ?? Self.sinProveedor
        porProveedor[clave] = porProveedor[clave]?.sumando(uso) ?? uso
    }

    /// Fusiona usos y sellos. Un costo desconocido (nil) contamina la suma:
    /// no se rellena con cero porque seria inventar. La marca de estimacion se
    /// hereda si cualquiera de los dos tramos la tenia.
    mutating func fusionar(_ otro: UsoResumido) {
        for (clave, uso) in otro.porProveedor {
            porProveedor[clave] = porProveedor[clave]?.sumando(uso) ?? uso
        }
        costoSelladoUSD = CostoEstimado.sumar(costoSelladoUSD, otro.costoSelladoUSD)
        costoEsEstimacion = costoEsEstimacion || otro.costoEsEstimacion
    }
}

/// Peticion viva de aprobacion del Modo Tarea.
///
/// La hoja no guarda la continuacion: el estado la resuelve con
/// `aprobarSolicitud()` o `denegarSolicitud()` y el ToolLoop recibe el booleano.
/// Asi la vista solo pinta y el motor no conoce SwiftUI.
struct SolicitudAprobacion: Identifiable, Equatable {
    let id: UUID
    let tareaID: UUID
    let herramienta: String
    let descripcion: String
    let detalle: String

    init(
        id: UUID = UUID(),
        tareaID: UUID,
        herramienta: String,
        descripcion: String,
        detalle: String = ""
    ) {
        self.id = id
        self.tareaID = tareaID
        self.herramienta = herramienta
        self.descripcion = descripcion
        self.detalle = detalle
    }
}

/// Escalones rapidos del tope de aviso por chat (§3.5).
///
/// POR QUE un tipo aparte y no una constante de la vista: los chips de Mi
/// Contexto y su prueba tienen que compartir la MISMA lista sin depender de
/// SwiftUI. Todos son positivos porque `fijarTopeAviso` rechaza el cero (0 =
/// aviso desactivado).
enum TopesRapidos {
    static let valores: [Double] = [0.10, 0.25, 0.50, 1.00]
}

/// Estado central de la app.
///
/// Aqui vive todo lo que cambia: la configuracion, las conversaciones y el texto
/// que se esta escribiendo. Las pantallas solo leen y llaman a metodos, de modo
/// que hay un unico sitio que sabe donde se guarda cada cosa.
@MainActor
final class EstadoApp: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            sincronizarSkills()
            guardarConfig()
        }
    }

    @Published private(set) var conversaciones: [Conversation] = []
    @Published var conversacion: Conversation

    /// Tareas guardadas, la mas reciente primero.
    ///
    /// Viven en su propio almacen y en su propia pestana: no se mezclan con las
    /// conversaciones. El estado `.enCurso` que quedo de una sesion anterior se
    /// convierte en `.interrumpida` al arrancar.
    @Published private(set) var tareas: [Tarea] = []
    /// True mientras se pide el plan de una tarea al modelo.
    @Published private(set) var generandoPlan = false
    /// Tarea cuyo plan se esta generando ahora mismo (B3-A).
    ///
    /// `generandoPlan` dice si hay una peticion en vuelo; este id dice DE QUE
    /// tarea es, para que la cabecera fija del hilo muestre «Planificando» solo
    /// en la tarea correcta y el composer sepa que el envio esta en pausa.
    @Published private(set) var idTareaPlanificando: UUID?
    /// True mientras /plan pide el plan dentro de un chat.
    @Published private(set) var generandoPlanChat = false
    /// Error propio de la pantalla de Tareas, separado del error del chat.
    @Published var errorTarea: String?
    /// Aprobacion pendiente del Modo Tarea, si hay una.
    ///
    /// La hoja de TareaView la presenta; los tests la resuelven llamando a
    /// `aprobarSolicitud()` o `denegarSolicitud()`.
    @Published var solicitudAprobacion: SolicitudAprobacion?

    /// Propuesta de escritura sensible pendiente de aprobacion (B2.4).
    ///
    /// P0.2 solo la proyecta como `.hojaAprobacionMemoria`: el flujo que la
    /// crea y la resuelve llega en B2.4. Mientras esta pendiente, la hoja es el
    /// unico artefacto visible del turno.
    @Published var propuestaMemoriaSensible: PropuestaMemoriaSensible?

    @Published private(set) var enviando = false
    @Published private(set) var textoEnCurso = ""
    /// Texto de la caja de la conversacion abierta.
    ///
    /// Vive aqui y no en ChatView para que los comandos, el selector flotante
    /// y el dictado trabajen sobre un unico borrador: enviar, completar una
    /// skill o limpiar tras un comando son operaciones de la misma ruta.
    @Published var borrador = ""
    /// Aviso pequeno sobre la caja (comando desconocido, skill sin mensaje,
    /// permisos de dictado o compactacion corta). No es la franja de tope.
    @Published var avisoComando: String?
    /// True mientras se esta pidiendo el resumen de /compact. Deshabilita la
    /// caja para que no se envie un turno a mitad de la compactacion.
    @Published private(set) var compactando = false
    /// True mientras el microfono esta escuchando (dictado).
    ///
    /// Vive en el estado y no en ChatView para poder probar la logica sin
    /// SwiftUI: el boton no puede quedarse pegado en "grabando" si el
    /// reconocimiento falla o se cancela.
    @Published private(set) var dictando = false
    /// La hoja de /modelos la abre un comando desde EstadoApp; ChatView la
    /// presenta observando esta bandera.
    @Published var mostrarHojaModelos = false
    /// Conversacion que /nuevo quiere abrir. ChatsRaizView la empuja a su pila.
    @Published var idParaAbrir: UUID?
    /// Conversacion que Ramificar quiere abrir con la pila reiniciada.
    ///
    /// La raiz deja la ruta como una apertura normal desde la lista
    /// (raiz -> copia), en vez de apilar la copia sobre el chat original: asi
    /// el boton de volver dice "Chats" y el gesto de borde no cambia.
    @Published var idParaAbrirReiniciandoRuta: UUID?
    /// Texto que /exportar quiere compartir. ChatView lo recoge y presenta la
    /// hoja del sistema.
    @Published var textoParaCompartirSolicitado: String?
    /// Divisores y avisos del hilo abierto (SPEC §2.6).
    ///
    /// Viven fuera de `mensajes` a proposito: son metadatos de interfaz y jamas
    /// pueden viajar en el payload. Tampoco se persisten: al abrir o crear otra
    /// conversacion se limpian.
    @Published private(set) var eventosVisuales: [EventoVisual] = []
    @Published var error: String?
    /// Mensaje legible del ultimo turno fallido.
    ///
    /// Se lee y escribe en la conversacion abierta (`Conversation.errorDeTurno`)
    /// para que el fallo sobreviva a cerrar y reabrir el chat y a reiniciar la
    /// app. Se pinta en linea al final del hilo (§3.7) en vez de en el aviso
    /// generico: asi el mensaje del usuario sigue a la vista y se puede
    /// reintentar sin volver a escribirlo.
    var errorDeTurno: String? {
        get { conversacion.errorDeTurno }
        set { conversacion.errorDeTurno = newValue }
    }

    /// Ventana de contexto de cada modelo, en tokens.
    ///
    /// La clave es el identificador crudo del modelo (`vendedor/modelo`), no el
    /// nombre limpio: asi la tabla sigue valiendo aunque cambie como se pinta.
    /// Vive fuera de `AppConfig` a proposito, porque el formato exportable de
    /// la configuracion no cambia en esta tarea.
    @Published var ventanasPorModelo: [String: Int] = [:] {
        didSet { guardarVentanas() }
    }

    /// Uso de los mensajes que /compact resumio, por conversacion.
    ///
    /// La factura no puede bajar al compactar (§4.1): los mensajes resumidos
    /// salen del hilo, pero su consumo se conserva aqui y se suma al de los
    /// mensajes que quedan. Vive fuera de `Conversation` para no tocar el
    /// modelo de NodoCore.
    private var usoResumidoPorConversacion: [String: UsoResumido] = [:] {
        didSet { guardarUsosResumidos() }
    }

    /// Ultimo resumen de /compact por conversacion (COMP.2).
    ///
    /// Se guarda aparte de `Conversation` y junto a los usos resumidos porque
    /// el resumen tiene que sobrevivir a la poda y llegar al modelo tambien en
    /// un chat SIN memoria. La copia de `Conversation.resumenCompactado` sigue
    /// siendo la via de la Memoria; esta es el respaldo persistido que Historial
    /// inyecta cuando esa via no lo aporta.
    private var resumenesCompactadosPorConversacion: [String: String] = [:] {
        didSet { guardarResumenesCompactados() }
    }

    private let llavero: AlmacenClaves
    /// Estado sembrado por `-CapturasPrueba`, o nil en un arranque normal.
    /// Ademas de no persistir, activa el motor y la herramienta deterministas.
    private let estadoDePrueba: EstadoPrueba?
    /// Servicio de dictado: el real en produccion y el doble de CI en capturas.
    let dictado: SpeechRecognizing
    /// Punto UNICO de construccion del puerto de skills. Se rellena con
    /// `config.skills` en cada cambio de configuracion, asi el parser y el
    /// selector flotante leen el almacen real sin conocer la interfaz.
    private let resolvedorSkills = ResolvedorSkillsEnMemoria()
    /// En modo capturas no se escribe nada en el almacenamiento del telefono:
    /// el estado llega sembrado en memoria y las capturas no deben ensuciar
    /// los datos de quien use la app de verdad.
    private let persistir: Bool
    /// Transporte inyectable: en produccion es URLSession y en los tests es un
    /// doble que graba las peticiones y devuelve respuestas guionizadas. El tipo
    /// compuesto cubre los dos usos de red de la app: streaming y peticion
    /// completa.
    private let transporte: any HTTPStreaming & HTTPUnary
    /// Preferencias inyectables: los tests usan una suite temporal para no
    /// tocar los datos del telefono ni depender de un estado anterior.
    private let defaults: UserDefaults
    private var store: ConversationStore?
    /// Almacen de tareas, independiente del de conversaciones.
    private var storeTareas: TareaStore?
    private var tareaActual: Task<Void, Never>?
    /// Ejecucion de la tarea abierta, separada del turno de chat.
    ///
    /// Se guarda aparte para que Detener corte SOLO la tarea y para que una
    /// ejecucion vieja que termina tarde no escriba en una reanudacion nueva.
    private var ejecucionTarea: Task<Void, Never>?
    private var idTareaEjecutando: UUID?
    private var generacionEjecucionTarea = UUID()
    /// Continuacion que espera la hoja de aprobacion. Se resuelve una sola vez.
    private var continuacionAprobacion: CheckedContinuation<Bool, Never>?
    private var idSolicitudAprobacion: UUID?
    /// Continuacion que espera la decision de una propuesta sensible de Chat
    /// (B2.4). Es independiente de la de Tarea: el turno de Chat queda detenido
    /// mientras la hoja del hilo esta pendiente.
    private var continuacionPropuestaSensible: CheckedContinuation<Bool, Never>?
    /// Tarea de resumen de /compact, para poder cancelarla al cambiar de chat.
    private var tareaCompactado: Task<Void, Never>?
    /// Tarea de /plan en el chat, para cancelarla al cambiar de conversacion.
    private var tareaPlanChat: Task<Void, Never>?
    /// Identifica la compactacion vigente: una tarea vieja que termina tarde no
    /// puede reabrir la caja de una compactacion nueva.
    private var generacionCompactado = UUID()
    /// Cambia al guardar una clave para que la Tarjeta de Bienvenida vuelva a
    /// leer el llavero y pase a su estado normal.
    @Published private(set) var clavesVersion = 0
    /// Que clase de turno fallo, para que `reintentar()` sepa si debe volver a
    /// enviar el historial actual o regenerar la ultima respuesta restaurada.
    private enum TipoTurnoFallido {
        case envio
        case regeneracion
    }
    private var turnoFallido: TipoTurnoFallido?
    /// Texto que ya habia en la caja al empezar a dictar: las parciales se
    /// anaden a el y nunca se pierden si el dictado falla o se corta.
    private var prefijoDictado = ""
    /// Identifica la sesion de dictado vigente: un callback tardio de una sesion
    /// vieja (parcial o fallo) no puede tocar la caja de la nueva.
    private var generacionDictado = UUID()
    /// La carga inicial del diccionario no debe escribir nada: se activa al
    /// terminar el init normal y se queda apagada en modo de prueba.
    private var puedeGuardarVentanas = false
    private var puedeGuardarUsosResumidos = false
    private var puedeGuardarResumenesCompactados = false

    private static let claveConfig = "nodo.config.v1"
    private static let claveVentanas = "nodo.ventanas.v1"
    private static let claveUsosResumidos = "nodo.usos-resumidos.v1"
    private static let claveResumenesCompactados = "nodo.resumenes-compactados.v1"

    /// Instrucciones del resumen de /compact (§4.2). Es una llamada aparte,
    /// sin herramientas y sin streaming.
    private static let instruccionesCompactar = """
    Resume esta conversación en un solo bloque, en español, conservando los datos, las decisiones y los pendientes importantes. No inventes nada que no se haya dicho y no añadas opiniones. Devuelve solo el resumen.
    """

    /// Miles con punto y sin decimales, como en el texto de §2.4.
    private static func tokensTexto(_ valor: Int) -> String {
        let formateador = NumberFormatter()
        formateador.locale = Locale(identifier: "es_ES")
        formateador.numberStyle = .decimal
        formateador.minimumFractionDigits = 0
        formateador.maximumFractionDigits = 0
        return formateador.string(from: NSNumber(value: valor)) ?? "\(valor)"
    }

    init(
        llavero: AlmacenClaves = LlaveroAlmacen(),
        estadoDePrueba: EstadoPrueba? = nil,
        transporte: any HTTPStreaming & HTTPUnary = TransporteURLSession(),
        defaults: UserDefaults = .standard,
        directorioStore: URL? = nil,
        directorioTareas: URL? = nil,
        dictado: SpeechRecognizing? = nil
    ) {
        self.llavero = llavero
        self.estadoDePrueba = estadoDePrueba
        self.persistir = estadoDePrueba == nil
        self.transporte = transporte
        self.defaults = defaults
        // En capturas el dictado es un doble que inyecta una transcripcion fija
        // sin pedir permisos ni tocar el microfono. El resto del flujo es el
        // mismo que en el iPhone real. Un reconocedor inyectado (tests de la
        // logica de estado) manda sobre los dos.
        if let dictado {
            self.dictado = dictado
        } else if estadoDePrueba == nil {
            self.dictado = DictadoReconocimiento()
        } else {
            self.dictado = DictadoDePrueba()
        }

        // Gancho de capturas (SPEC §6/H7): estado de PRUEBA en memoria, sin
        // leer ni escribir la configuracion, las conversaciones o el llavero
        // reales. Sin este argumento se sigue por la ruta normal de siempre.
        if let prueba = estadoDePrueba {
            self.config = prueba.config
            self.conversacion = prueba.conversacion
            self.conversaciones = prueba.conversaciones
            // En capturas la tabla arranca vacia y no toca UserDefaults: el
            // estado sembrado debe ser determinista y no ensuciar el telefono.
            self.ventanasPorModelo = [:]
            self.store = nil
            // Las capturas no siembran tareas: la pestana Tareas es un espacio
            // propio de TASK.1 y no forma parte del estado de prueba anterior.
            self.tareas = []
            sincronizarSkills()
            return
        }

        if let datos = defaults.data(forKey: Self.claveConfig),
           let cargada = try? AppConfig.desde(json: datos) {
            self.config = cargada
        } else {
            self.config = .inicial()
        }

        self.conversacion = Conversation()
        self.ventanasPorModelo = Self.ventanasGuardadas(de: defaults)
        self.usoResumidoPorConversacion = Self.usosResumidosGuardados(de: defaults)
        self.resumenesCompactadosPorConversacion =
            Self.resumenesCompactadosGuardados(de: defaults)

        var almacen: ConversationStore?
        do {
            // Un directorio inyectado manda; nil conserva la ruta real de la
            // app. Asi los tests escriben en una carpeta temporal sin tocar el
            // historial del telefono.
            let directorio: URL
            if let directorioStore {
                directorio = directorioStore
            } else {
                directorio = try ConversationStore.directorioPorDefecto()
            }
            almacen = try ConversationStore(directorio: directorio)
        } catch {
            self.error = "No se pudo abrir el almacen de conversaciones."
        }
        self.store = almacen
        self.conversaciones = almacen?.listar() ?? []

        // Almacen propio de tareas. Si el llamador inyecta `directorioTareas`
        // manda ese; si solo inyecta el de conversaciones, las tareas viven en
        // una subcarpeta hermana para no mezclar los dos tipos de archivo.
        var almacenTareas: TareaStore?
        do {
            let directorio: URL
            if let directorioTareas {
                directorio = directorioTareas
            } else if let directorioStore {
                directorio = TareaStore.directorioEn(directorioStore)
            } else {
                directorio = try TareaStore.directorioPorDefecto()
            }
            almacenTareas = try TareaStore(directorio: directorio)
        } catch {
            self.error = "No se pudo abrir el almacen de tareas."
        }
        self.storeTareas = almacenTareas
        self.tareas = almacenTareas?.listar() ?? []

        // Frontera honesta de iOS: no hay ejecucion en segundo plano. Toda
        // tarea que quedo `enCurso` al cerrar la app se lee como interrumpida.
        if let almacenTareas {
            let interrumpidas = almacenTareas.marcarInterrumpidas()
            if interrumpidas > 0 {
                self.tareas = almacenTareas.listar()
            }
        }

        self.puedeGuardarVentanas = true
        self.puedeGuardarUsosResumidos = true
        self.puedeGuardarResumenesCompactados = true
        sincronizarSkills()

        // PACK.1: siembra del pack de fabrica en el arranque. Es trabajo en
        // memoria sobre la configuracion ya cargada (12 registros, sin red) y
        // no bloquea el primer pintado: solo escribe la configuracion si de
        // verdad hubo algo que sembrar o si el marcador subio.
        sembrarSkillsDeFabrica()
        // El pack pudo crear skills: el parser de "/" y el selector tienen que
        // verlas ya en este primer arranque, no en el siguiente.
        sincronizarSkills()

        // COST.3 y COST.2, en este orden: primero se sellan los mensajes legados
        // con los precios de SU proveedor y despues se migra el libro, para que
        // el USD migrado ya cuente esas estimaciones. La antigua poda de
        // compactados huerfanos se retiro: ninguna carga borra mensajes.
        sellarLegadosAlCargar()
        migrarLibroDeGastoAlArrancar()
    }

    // MARK: - Configuracion

    private func guardarConfig() {
        guard persistir, let datos = try? config.json() else { return }
        defaults.set(datos, forKey: Self.claveConfig)
    }

    /// Copia las skills persistidas al puerto que consume el parser.
    ///
    /// Se llama en cada cambio de configuracion y al terminar el init: asi el
    /// parser de "/" y el selector flotante ven siempre el almacen real.
    private func sincronizarSkills() {
        resolvedorSkills.skills = config.skills.map { skill in
            SkillResuelta(
                nombre: skill.nombre,
                slug: skill.slug,
                descripcion: skill.descripcion,
                instrucciones: skill.instrucciones
            )
        }
    }

    // MARK: - Skills

    /// Crea o edita una skill con las reglas del nucleo (§4.4).
    @discardableResult
    func guardarSkill(
        nombre: String,
        instrucciones: String,
        idExistente: UUID? = nil
    ) -> Result<SkillLocal, ErrorSkill> {
        config.guardar(
            nombre: nombre,
            instrucciones: instrucciones,
            idExistente: idExistente
        )
    }

    /// Borra la skill por id. El `didSet` de la configuracion refresca el parser.
    func borrarSkill(id: UUID) {
        config.borrar(id: id)
    }

    /// Borra la skill indicada; comodo para las vistas que ya la tienen.
    func borrarSkill(_ skill: SkillLocal) {
        borrarSkill(id: skill.id)
    }

    /// Siembra las skills del pack de fabrica al arrancar (PACK.1).
    ///
    /// Corre dentro del init, igual que la migracion del libro de gasto, y por
    /// eso persiste a mano: los observadores de `config` pueden no dispararse
    /// durante el arranque. Si el marcador ya esta al dia no hace nada: no
    /// reescribe la configuracion ni recorre las skills del dueno.
    private func sembrarSkillsDeFabrica() {
        let versionAnterior = config.packSkillsVersion
        let creadas = SiembraSkills.sembrarSiFaltaVersion(en: &config)
        guard creadas > 0 || config.packSkillsVersion != versionAnterior else {
            return
        }
        guardarConfig()
    }

    /// [Restaurar skills de fabrica]: repone las del pack que el dueno borro.
    ///
    /// POR QUE no reusa la siembra por version: el marcador ya subio y la
    /// siembra normal no resucita lo borrado. Este boton es la via explicita:
    /// siembra inmediata de los slugs de fabrica ausentes, sin tocar las
    /// skills propias ni las de fabrica que ya existen (aunque el dueno las
    /// haya editado).
    ///
    /// - Returns: cuantas skills de fabrica volvieron.
    @discardableResult
    func restaurarSkillsDeFabrica() -> Int {
        let creadas = SiembraSkills.restaurar(en: &config)
        // Se refresca el parser y se persiste a mano cuando hubo cambios: el
        // acceso `inout` a `config` no siempre dispara su `didSet`, y el boton
        // tiene que dejar el efecto hecho antes de volver a la pantalla.
        if creadas > 0 {
            sincronizarSkills()
            guardarConfig()
        }
        return creadas
    }

    // MARK: - Ventanas de contexto

    /// Ventana guardada para un modelo, o nil si no hay ninguna definida.
    ///
    /// Un cero o un negativo no cuenta como ventana: el contrato prohibe
    /// inventar un porcentaje cuando falta el denominador.
    func ventana(paraModelo modelo: String) -> Int? {
        let clave = Self.claveDeModelo(modelo)
        guard !clave.isEmpty,
              let ventana = ventanasPorModelo[clave],
              ventana > 0
        else {
            return nil
        }
        return ventana
    }

    /// Fija la ventana de un modelo. nil o un valor no positivo borra la fila.
    func fijarVentana(_ ventana: Int?, paraModelo modelo: String) {
        let clave = Self.claveDeModelo(modelo)
        guard !clave.isEmpty else { return }

        if let ventana, ventana > 0 {
            ventanasPorModelo[clave] = ventana
        } else {
            ventanasPorModelo.removeValue(forKey: clave)
        }
    }

    /// Aplica un respaldo y deja sus ventanas en el mismo almacen de siempre.
    ///
    /// La configuracion se persiste por su `didSet` y la tabla de ventanas por
    /// el suyo, bajo `nodo.ventanas.v1`: la misma clave que lee la Hoja Estado
    /// del chat. En modo capturas nada de esto toca el almacenamiento real.
    func importarRespaldo(_ respaldo: RespaldoConfiguracion) {
        config = RespaldoConfiguracion.aplicar(respaldo, sobre: config)
        ventanasPorModelo = respaldo.ventanas
    }

    // MARK: - Respaldo total (BACK.1/BACK.2)

    /// Construye el respaldo TOTAL del estado vivo.
    ///
    /// Reune la configuracion, las ventanas, las conversaciones completas (con
    /// resumen de /compact y sellos de costo) y las tareas con su libro. Las
    /// claves no entran: los proveedores solo llevan el nombre de su credencial
    /// en el llavero.
    func hacerRespaldoTotal() -> RespaldoConfiguracion {
        RespaldoConfiguracion.hacerRespaldo(
            config: config,
            ventanas: ventanasPorModelo,
            // B2.2: el respaldo tampoco puede llevarse un hilo temporal. La
            // lista no lo contiene (nunca se persiste), pero el filtro lo deja
            // escrito aqui para que ningun camino futuro lo cuele.
            conversaciones: conversaciones.filter(\.sePersiste),
            tareas: tareas
        )
    }

    /// JSON del respaldo total, listo para que el dueno lo guarde fuera.
    func exportarRespaldo() -> Data? {
        try? hacerRespaldoTotal().json()
    }

    /// Valida un respaldo SIN tocar el estado y devuelve su manifiesto.
    ///
    /// La vista la usa para ensenar el resumen de conteos antes de que el dueno
    /// confirme el reemplazo.
    func validarRespaldo(
        _ respaldo: RespaldoConfiguracion
    ) -> Result<ManifiestoRespaldo, ErrorRespaldo> {
        do {
            try respaldo.validar()
            guard let manifiesto = respaldo.manifiesto else {
                return .failure(.sinManifiesto)
            }
            return .success(manifiesto)
        } catch let error as ErrorRespaldo {
            return .failure(error)
        } catch {
            return .failure(.manifiestoIncoherente)
        }
    }

    /// Reemplazo TOTAL y verificado del estado (BACK.2).
    ///
    /// Primero valida el archivo; despues sustituye configuracion, ventanas,
    /// conversaciones y tareas SIN mezclar con lo anterior; y al final compara
    /// los conteos resultantes con el manifiesto. Si no cuadran, lanza el
    /// error: no se finge exito. La siembra de fabrica es idempotente por slug,
    /// asi que restaurar un pack ya presente no duplica nada.
    @discardableResult
    func importarRespaldoTotal(
        _ respaldo: RespaldoConfiguracion
    ) throws -> ManifiestoRespaldo {
        let manifiesto: ManifiestoRespaldo
        switch validarRespaldo(respaldo) {
        case .success(let valor):
            manifiesto = valor
        case .failure(let error):
            throw error
        }

        // 1) Configuracion completa (proveedores sin claves, memoria, skills,
        //    tope, libro de gasto, contadores y MCP). Primero se corta cualquier
        //    turno vivo: no puede seguir escribiendo un estado que se reemplaza.
        cancelar()
        config = RespaldoConfiguracion.aplicar(respaldo, sobre: config)
        // 2) Ventanas, conversaciones y tareas: reemplazo, sin mezcla.
        ventanasPorModelo = respaldo.ventanas
        reemplazarConversaciones(con: respaldo.conversaciones)
        reemplazarTareas(con: respaldo.tareas)

        // 3) Verificacion contra el manifiesto: lo aplicado tiene que cuadrar
        //    con lo anunciado. `real` son los conteos del estado ya aplicado y
        //    `respaldo` es la fuente del manifiesto; `validarRespaldo` garantiza
        //    que su manifiesto cuadra con su contenido, asi que comparar contra
        //    el respaldo comprueba exactamente los conteos anunciados.
        let real = hacerRespaldoTotal().conteos
        guard real.cuadraCon(respaldo) else {
            throw ErrorRespaldo.verificacionFallida
        }
        return manifiesto
    }

    /// Sustituye las conversaciones guardadas por las del respaldo.
    ///
    /// Se borran TODAS las viejas antes de escribir las nuevas: un chat que no
    /// venia en el respaldo desaparece, que es la diferencia entre restaurar y
    /// mezclar.
    private func reemplazarConversaciones(con nuevas: [Conversation]) {
        if let store {
            try? store.borrarTodo()
            for conversacion in nuevas {
                try? store.guardar(conversacion)
            }
        }

        conversaciones = nuevas

        // Los resumenes y los baldes de compactacion pertenecen a una
        // conversacion concreta: los huerfanos no deben sobrevivir al reemplazo.
        let ids = Set(nuevas.map { $0.id.uuidString })
        usoResumidoPorConversacion = usoResumidoPorConversacion.filter {
            ids.contains($0.key)
        }
        resumenesCompactadosPorConversacion = resumenesCompactadosPorConversacion.filter {
            ids.contains($0.key)
        }

        // La conversacion abierta se reengancha a la copia restaurada si seguia en
        // el respaldo; si no, se cae a la primera o a una nueva. En cualquiera de
        // los dos casos se limpia el estado transitorio de la caja.
        let idAbierto = conversacion.id
        conversacion = nuevas.first(where: { $0.id == idAbierto })
            ?? nuevas.first
            ?? Conversation()
        limpiarEventosVisuales()
        limpiarErrorDeTurno()
        limpiarEstadoDeCaja()
    }

    /// Sustituye las tareas guardadas por las del respaldo.
    private func reemplazarTareas(con nuevas: [Tarea]) {
        if let storeTareas {
            try? storeTareas.borrarTodo()
            for tarea in nuevas {
                try? storeTareas.guardar(tarea)
            }
        }
        tareas = nuevas
    }

    /// La tabla se guarda como JSON aparte de la configuracion.
    ///
    /// `didSet` solo llega aqui cuando cambia el diccionario; `persistir`
    /// mantiene las capturas fuera del almacenamiento real.
    private func guardarVentanas() {
        guard persistir, puedeGuardarVentanas,
              let datos = try? JSONEncoder().encode(ventanasPorModelo)
        else {
            return
        }
        defaults.set(datos, forKey: Self.claveVentanas)
    }

    private static func ventanasGuardadas(de defaults: UserDefaults) -> [String: Int] {
        guard let datos = defaults.data(forKey: claveVentanas),
              let ventanas = try? JSONDecoder().decode([String: Int].self, from: datos)
        else {
            return [:]
        }
        // Una ventana no positiva no es una ventana, y una clave vacia no
        // apunta a ningun modelo: se descartan al cargar para que la tabla no
        // ensene filas que el medidor no puede usar.
        return ventanas.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.value > 0
        }
    }

    /// Guarda el consumo de los mensajes resumidos, fuera de `Conversation`.
    private func guardarUsosResumidos() {
        guard persistir, puedeGuardarUsosResumidos,
              let datos = try? JSONEncoder().encode(usoResumidoPorConversacion)
        else {
            return
        }
        defaults.set(datos, forKey: Self.claveUsosResumidos)
    }

    private static func usosResumidosGuardados(de defaults: UserDefaults) -> [String: UsoResumido] {
        guard let datos = defaults.data(forKey: claveUsosResumidos) else {
            return [:]
        }

        // Formato nuevo: uso atribuido a cada proveedor.
        if let usos = try? JSONDecoder().decode([String: UsoResumido].self, from: datos) {
            return usos
        }

        // Formato viejo: solo tokens. Se conserva como respaldo sin proveedor
        // para no perder la factura ya compactada al actualizar la app.
        guard let viejos = try? JSONDecoder().decode([String: UsoTokens].self, from: datos)
        else {
            return [:]
        }
        return viejos.mapValues { uso in
            var atribuido = UsoResumido()
            atribuido.sumar(uso, proveedorID: nil)
            // El formato solo-tokens es aun mas viejo que el de v0.3.0 y
            // tampoco trae sello. La marca queda como dato de lectura; ya no
            // se usa para podar mensajes.
            atribuido.sinSelloEnDisco = true
            return atribuido
        }
    }

    /// Guarda el ultimo resumen de compactacion por conversacion (COMP.2).
    private func guardarResumenesCompactados() {
        guard persistir, puedeGuardarResumenesCompactados,
              let datos = try? JSONEncoder().encode(resumenesCompactadosPorConversacion)
        else {
            return
        }
        defaults.set(datos, forKey: Self.claveResumenesCompactados)
    }

    private static func resumenesCompactadosGuardados(
        de defaults: UserDefaults
    ) -> [String: String] {
        guard let datos = defaults.data(forKey: claveResumenesCompactados),
              let resumenes = try? JSONDecoder().decode([String: String].self, from: datos)
        else {
            return [:]
        }
        // Un resumen vacio no es un resumen: se descarta al cargar para que
        // Historial no inyecte una cabecera sin texto.
        return resumenes.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Sellos de costo y libro de gasto (COST.1-3)

    /// Sella al cargar los mensajes legados que aun no tienen sello (COST.3).
    ///
    /// Se hace una vez, sobre las conversaciones recien leidas del almacen, y
    /// se vuelven a guardar solo las que cambiaron. El proveedor de cada sello
    /// es el que genero el mensaje (o el registrado del chat en los mas
    /// viejos): nunca el activo global, que puede ser otro modelo. Los que no
    /// tienen proveedor resoluble se quedan sin sello.
    private func sellarLegadosAlCargar() {
        var cambiadas: [Conversation] = []

        for indice in conversaciones.indices {
            let cambios = SellosDeCosto.sellarLegados(
                en: &conversaciones[indice],
                proveedores: config.proveedores
            )
            if cambios > 0 {
                cambiadas.append(conversaciones[indice])
            }
        }

        for conversacion in cambiadas {
            try? store?.guardar(conversacion)
        }
    }

    /// Migra el libro de gasto la primera vez que arranca esta version (COST.2).
    ///
    /// POR QUE: las conversaciones ya gastaron dinero antes de que existiera el
    /// libro. Se vuelca al mes en curso el uso de cada ventana de chat y el USD
    /// de sus sellos (los legados ya se sellaron arriba, como estimacion). Los
    /// dias empiezan hoy: no se inventa un reparto hacia atras. Un tramo que no
    /// se puede valorar no suma USD, pero sus tokens si quedan contados.
    private func migrarLibroDeGastoAlArrancar() {
        guard !config.usoApp.migrado else { return }

        var uso = UsoTokens()
        var usd = 0.0

        for conversacion in conversaciones {
            if let suyo = CostoEstimado.usoAcumulado(de: conversacion.mensajes) {
                uso = uso.sumando(suyo)
            }
            if let sellado = CostoEstimado.acumuladoSellado(
                mensajes: conversacion.mensajes,
                proveedores: config.proveedores,
                proveedorDelChat: conversacion.proveedorID
            ) {
                usd += sellado
            }
            if let resumido = usoResumidoPorConversacion[conversacion.id.uuidString] {
                uso = uso.sumando(resumido.total)
                // Un balde legado sin sello se valora con el proveedor de SU
                // chat para no perder lo que ya se compacto.
                if let suyo = costoDeResumido(
                    resumido,
                    proveedorDelChat: conversacion.proveedorID
                ) {
                    usd += suyo
                }
            }
        }

        config.usoApp.migrar(uso: uso, usd: usd, fecha: Date())
        // Se persiste aqui a proposito: la migracion corre dentro del init,
        // donde los observadores de `config` pueden no dispararse, y el libro
        // tiene que quedar guardado con su marca de migrado.
        guardarConfig()
    }

    /// El identificador crudo se recorta, pero no se transforma: la tabla debe
    /// seguir apuntando al mismo modelo que envia el proveedor.
    private static func claveDeModelo(_ modelo: String) -> String {
        modelo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clave(para proveedor: ProviderConfig) -> String? {
        // En capturas no hay llavero real, pero algunos estados siembran una
        // clave de ejemplo para que la Tarjeta de Bienvenida pueda ensenar su
        // estado conectado sin tocar el almacenamiento del simulador.
        if let estadoDePrueba {
            return estadoDePrueba.claveDePrueba
        }
        return llavero.leer(proveedor.claveKeychain)
    }

    /// Guarda o borra la clave del proveedor y la propaga a sus companeros.
    ///
    /// Devuelve true si el llavero quedo escrito. La Tarjeta de Bienvenida usa
    /// ese resultado para no cambiar de estado si el guardado fallo.
    @discardableResult
    func guardarClave(_ clave: String, para proveedor: ProviderConfig) -> Bool {
        guard persistir else { return false }
        let limpia = clave.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if limpia.isEmpty {
                try llavero.borrar(proveedor.claveKeychain)
            } else {
                try llavero.guardar(limpia, para: proveedor.claveKeychain)
                propagarClave(limpia, desde: proveedor)
            }
            clavesVersion += 1
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Propaga una clave recien guardada a los companeros del mismo host.
    ///
    /// La regla pura vive en `AppConfig.companerosDeHost` (§3.7). Aqui solo se
    /// escribe directo en el llavero, sin volver a llamar a `guardarClave`:
    /// una clave propia distinta ya guardada no se pisa nunca.
    private func propagarClave(_ clave: String, desde proveedor: ProviderConfig) {
        for companero in config.companerosDeHost(de: proveedor) {
            let actual = llavero.leer(companero.claveKeychain) ?? ""
            let vacia = actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard vacia else { continue }
            try? llavero.guardar(clave, para: companero.claveKeychain)
        }
    }

    var tokenServidor: String? {
        guard persistir else { return nil }
        return llavero.leer(ServerConfig.tokenKeychain)
    }

    func guardarTokenServidor(_ token: String) {
        guard persistir else { return }
        let limpio = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if limpio.isEmpty {
                try llavero.borrar(ServerConfig.tokenKeychain)
            } else {
                try llavero.guardar(limpio, para: ServerConfig.tokenKeychain)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Lo que le falta al proveedor activo para poder usarse, o nil si esta bien.
    func problemaDeConfiguracion() -> String? {
        guard let proveedor = config.proveedorSeleccionado else {
            return "No hay ningun proveedor configurado."
        }
        do {
            try proveedor.validar()
        } catch {
            return error.localizedDescription
        }
        if (clave(para: proveedor) ?? "").isEmpty {
            return "Falta la clave de API de \(proveedor.nombre)."
        }
        return nil
    }

    /// Consumo acumulado del chat abierto: mensajes vivos + resumidos.
    ///
    /// Al compactar, los mensajes resumidos salen del hilo pero su consumo se
    /// conserva aparte para que la factura nunca baje (§4.1).
    var usoAcumuladoDelChat: UsoTokens? {
        var total = CostoEstimado.usoAcumulado(de: conversacion.mensajes)
        if let resumido = usoResumidoPorConversacion[conversacion.id.uuidString] {
            let usoDelResumen = resumido.total
            total = total?.sumando(usoDelResumen) ?? usoDelResumen
        }
        return total
    }

    /// Proveedor registrado del chat abierto, el que genero sus mensajes.
    ///
    /// Es solo el respaldo de los mensajes viejos: cada respuesta nueva lleva
    /// su propio proveedor. Nunca se usa el activo global para valorar historia.
    private var proveedorDelChat: ProviderConfig? {
        let id = conversacion.proveedorID
            ?? conversacion.mensajes.last(where: { $0.proveedorID != nil })?.proveedorID
        guard let id else { return nil }
        return config.proveedores.first { $0.id == id }
    }

    /// Costo de un mensaje tal como se sello al cerrar su generacion.
    ///
    /// Lo usa el pie de cada respuesta. Si el mensaje es legado y no tiene
    /// sello, se valora con el proveedor que lo genero (respaldo transitorio);
    /// sin precios de ESE proveedor no hay cifra, aunque el activo tenga otros.
    func costo(de mensaje: ChatMessage) -> Double? {
        CostoEstimado.costoSellado(
            de: mensaje,
            proveedores: config.proveedores,
            proveedorDelChat: conversacion.proveedorID
        )
    }

    /// True si el acumulado incluye algun sello estimado.
    ///
    /// Son los legados que se sellaron al cargar con los precios actuales de su
    /// proveedor (COST.3). Tambien cuenta el balde de /compact: puede llevar
    /// estimaciones de los mensajes que ya salieron del hilo, o su valoracion
    /// de respaldo hecha con los precios de hoy. El rotulo de /costo y la Hoja
    /// Estado lo advierten.
    var hayCostosEstimados: Bool {
        let enMensajes = conversacion.mensajes.contains { mensaje in
            mensaje.costoEsEstimacion
                && mensaje.uso != nil
                && mensaje.costoSelladoUSD != nil
        }
        if enMensajes { return true }

        guard let resumido = usoResumidoPorConversacion[conversacion.id.uuidString]
        else {
            return false
        }
        if resumido.costoEsEstimacion { return true }
        // Un balde sin sello se valora con los precios de hoy: es estimacion.
        return resumido.costoSelladoUSD == nil && !resumido.porProveedor.isEmpty
    }

    /// Costo acumulado del chat abierto: sellos vivos + sello del balde.
    ///
    /// Es el lector unico de COST.1. Sin precios configurados no hay cifra: no
    /// se inventa un costo. Cambiar el proveedor activo o editar sus precios no
    /// puede alterar este numero, porque los mensajes ya estan sellados.
    var costoAcumuladoDelChat: Double? {
        var total: Double?

        if CostoEstimado.usoAcumulado(de: conversacion.mensajes) != nil {
            guard let deMensajes = CostoEstimado.acumuladoSellado(
                mensajes: conversacion.mensajes,
                proveedores: config.proveedores,
                proveedorDelChat: conversacion.proveedorID
            ) else {
                return nil
            }
            total = deMensajes
        }

        if let resumido = usoResumidoPorConversacion[conversacion.id.uuidString] {
            guard let deResumen = costoDeResumido(
                resumido,
                proveedorDelChat: conversacion.proveedorID
            ) else {
                return nil
            }
            total = (total ?? 0) + deResumen
        }

        return total
    }

    /// Costo del balde de /compact: su sello si lo tiene y, si es legado, la
    /// valoracion por proveedor que hacia antes de existir el sello.
    private func costoDeResumido(
        _ resumido: UsoResumido,
        proveedorDelChat: UUID?
    ) -> Double? {
        if let sellado = resumido.costoSelladoUSD { return sellado }
        guard !resumido.porProveedor.isEmpty else { return nil }

        var total = 0.0
        for clave in resumido.porProveedor.keys.sorted() {
            guard let uso = resumido.porProveedor[clave] else { continue }

            let id = clave.isEmpty
                ? proveedorDelChat
                : UUID(uuidString: clave)
            guard let id,
                  let proveedor = config.proveedores.first(where: { $0.id == id }),
                  let parcial = CostoEstimado.costo(
                      uso: uso,
                      precioEntrada: proveedor.precioEntradaPorMillon,
                      precioSalida: proveedor.precioSalidaPorMillon
                  )
            else {
                return nil
            }
            total += parcial
        }
        return total
    }

    // MARK: - Memoria

    /// Texto plano de la Memoria para medir su peso y su costo estimado.
    ///
    /// Mi Contexto (MEM.4) y la hoja rapida del chat (H6.3) ya editan por
    /// entradas, una fila por cada una; esto solo une el texto para contar
    /// caracteres. El payload NO usa esto: `Historial` manda el bloque con las
    /// entradas y sus ids.
    var textoMemoria: String {
        Memoria.textoPlano(config.memoria)
    }

    /// Peso estimado de la Memoria: caracteres / 4, minimo 1 (§3.5).
    ///
    /// Es la misma heuristica de la Hoja Memoria rapida; vive aqui para que las
    /// dos caras de la Memoria ensenen siempre la misma cifra.
    var pesoEstimadoMemoria: Int {
        max(1, textoMemoria.count / 4)
    }

    /// Costo estimado de mandar la Memoria en un envio.
    ///
    /// Usa solo el precio de entrada del proveedor ACTIVO y devuelve su nombre
    /// limpio para rotularlo. Sin precio de entrada no hay cifra. Es un rotulo
    /// informativo de la vista, no un costo historico: por eso manda el activo
    /// y no el proveedor que genero cada mensaje.
    var costoEstimadoDeMemoria: (costo: Double, proveedor: String)? {
        let memoria = textoMemoria
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memoria.isEmpty,
              let proveedor = config.proveedorSeleccionado,
              let precioEntrada = proveedor.precioEntradaPorMillon,
              precioEntrada.isFinite,
              precioEntrada >= 0
        else {
            return nil
        }

        let costo = Double(pesoEstimadoMemoria) * precioEntrada / 1_000_000
        let nombre = NombresLimpios.proveedor(
            nombre: proveedor.nombre,
            baseURL: proveedor.baseURL
        )
        return (costo, nombre)
    }

    /// Estado visible de la Memoria en Mi Contexto (B2.5).
    ///
    /// El contador, la banda y la agrupación viven en el nucleo para probarse
    /// sin simulador; la vista solo pinta lo que este valor declara.
    var estadoMemoria: EstadoMemoriaMiContexto {
        EstadoMemoriaMiContexto(entradas: config.memoria)
    }

    /// True mientras la hoja de una propuesta sensible está pendiente y ya no
    /// cabe ninguna entrada más (B2.5).
    ///
    /// La hoja lo muestra antes de decidir y, aun con [Aprobar], el ejecutor
    /// rechaza la creación con «memoria en tope».
    var avisoTopeEnPropuestaSensible: Bool {
        propuestaMemoriaSensible != nil && estadoMemoria.enTope
    }

    /// Anade una entrada escrita a mano desde Mi Contexto (MEM.4).
    ///
    /// Aqui no hay tarjeta ni Deshacer: el dueno esta en la pantalla de edicion
    /// y el cambio es directo. La tarjeta es para los cambios que ordena al
    /// modelo dentro de un chat.
    ///
    /// B2.5: el tope rige también la creación manual; la hoja ya deshabilita
    /// Guardar con el tope lleno y esta guarda es la segunda barrera.
    @discardableResult
    func agregarEntradaMemoria(_ texto: String) -> EntradaMemoria? {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, !estadoMemoria.enTope else { return nil }

        let entrada = EntradaMemoria(texto: limpio)
        config.memoria.append(entrada)
        return entrada
    }

    /// Cambia el texto de UNA entrada sin tocar las demas (MEM.4).
    func actualizarEntradaMemoria(id: UUID, texto: String) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty,
              let indice = config.memoria.firstIndex(where: { $0.id == id })
        else {
            return
        }
        config.memoria[indice].texto = limpio
    }

    /// Borra UNA entrada de la Memoria (MEM.4).
    func borrarEntradaMemoria(id: UUID) {
        config.memoria.removeAll { $0.id == id }
    }

    /// Aplica una operacion tipada de memoria sobre la configuracion y deja la
    /// linea de evento en el hilo donde se dio la orden.
    ///
    /// Se llama desde la herramienta, ya en el MainActor. La lista se escribe
    /// una sola vez y solo cuando la operacion se aplico: un id desconocido no
    /// toca nada.
    ///
    /// B2.4: `.proponerSensible` NO entra por `aplicarTipada` (que la rechaza
    /// como segunda barrera). Se desvia a `proponerMemoriaSensible`, que
    /// detiene el turno con la hoja y solo escribe tras [Aprobar].
    private func aplicarOperacionDeMemoria(
        _ operacion: OperacionMemoriaTipada,
        idConversacion: UUID
    ) async -> ResultadoAccionMemoria {
        if case .proponerSensible(let contenido, let categoria, _) = operacion {
            return await proponerMemoriaSensible(
                contenido: contenido,
                categoria: categoria,
                idConversacion: idConversacion
            )
        }

        var entradas = config.memoria
        let resultado = Memoria.aplicarTipada(operacion, en: &entradas)
        guard case .aplicada(let cambio) = resultado else {
            return resultado
        }

        config.memoria = entradas

        // La linea se ancla al ultimo mensaje visible: la orden del dueno ya
        // esta en el hilo y la confirmacion del modelo aun no ha llegado.
        // Si el dueno cambio de chat mientras el modelo respondia, el cambio
        // de Memoria sigue siendo real (es global), pero su linea no debe
        // aparecer en otro hilo.
        if conversacion.id == idConversacion {
            eventosVisuales.append(
                EventoVisual(
                    trasMensaje: conversacion.mensajes.last?.id,
                    texto: cambio.textoDeLinea,
                    cambioMemoria: cambio
                )
            )
        }

        return .aplicada(cambio)
    }

    /// Detiene el turno en la hoja y escribe SOLO si el dueno aprueba (B2.4).
    ///
    /// La hoja es el unico artefacto visible mientras esta pendiente: la
    /// proyeccion la pinta al final del hilo y no anade burbuja en curso. Al
    /// denegar, cerrar el hilo o cerrar la app sin decidir no se escribe nada:
    /// el turno recibe un rechazo interno (rol `.herramienta`) que cierra ese
    /// `tool_call_id`, de modo que el payload siguiente no lo reenvia como
    /// pendiente.
    private func proponerMemoriaSensible(
        contenido: String,
        categoria: CategoriaSensibleMemoria,
        idConversacion: UUID
    ) async -> ResultadoAccionMemoria {
        // Si el dueno ya cambio de hilo, la hoja no puede aparecer en otro
        // chat: la propuesta se cierra como denegada sin tocar el registro.
        guard conversacion.id == idConversacion else {
            return .rechazada("denegado por el dueno")
        }
        guard propuestaMemoriaSensible == nil else {
            return .rechazada("ya hay una propuesta sensible pendiente en este turno.")
        }

        propuestaMemoriaSensible = PropuestaMemoriaSensible(
            texto: contenido,
            categoriaSensible: categoria
        )

        let aprobada = await withCheckedContinuation {
            (continuacion: CheckedContinuation<Bool, Never>) in
            self.continuacionPropuestaSensible = continuacion
        }

        propuestaMemoriaSensible = nil

        guard !Task.isCancelled else {
            return .rechazada("turno cancelado")
        }
        guard aprobada else {
            return .rechazada("denegado por el dueno")
        }

        var entradas = config.memoria
        let resultado = Memoria.aplicarSensibleAprobada(
            contenido: contenido,
            categoria: categoria,
            en: &entradas
        )
        guard case .aplicada(let cambio) = resultado else {
            return resultado
        }

        config.memoria = entradas

        // La linea unica de aviso posterior se ancla al ultimo mensaje visible
        // (la orden del dueno), igual que las escrituras no sensibles.
        if conversacion.id == idConversacion {
            eventosVisuales.append(
                EventoVisual(
                    trasMensaje: conversacion.mensajes.last?.id,
                    texto: cambio.textoDeLinea,
                    cambioMemoria: cambio
                )
            )
        }

        return .aplicada(cambio)
    }

    /// Revierte exactamente el cambio de una linea de Memoria (MEM.3).
    ///
    /// Devuelve false si la linea no existe, no es de Memoria o ya se habia
    /// deshecho: el segundo toque no puede volver a aplicar el inverso.
    @discardableResult
    func deshacerCambioDeMemoria(id eventoID: UUID) -> Bool {
        guard let indice = eventosVisuales.firstIndex(where: { $0.id == eventoID }),
              let cambio = eventosVisuales[indice].cambioMemoria,
              !eventosVisuales[indice].deshecho
        else {
            return false
        }

        var entradas = config.memoria
        Memoria.deshacer(cambio, en: &entradas)
        config.memoria = entradas
        eventosVisuales[indice] = eventosVisuales[indice].comoDeshecho()
        return true
    }

    /// Ocupacion de la ventana del chat abierto (§4.1).
    ///
    /// Mientras la ultima operacion sea una compactacion, manda el uso de esa
    /// llamada de resumen: es lo que hace bajar el medidor sin tocar la
    /// factura. El siguiente turno normal limpia ese respaldo y vuelve a mandar
    /// el uso de la ultima respuesta.
    var ocupacionDelChat: UsoTokens? {
        if let trasCompactar = conversacion.usoTrasCompactar {
            return trasCompactar
        }
        return MetricasChat.ocupacionVentana(de: conversacion.mensajes)
    }

    /// True cuando el acumulado del chat abierto alcanzo el tope vigente.
    ///
    /// La franja de §3.3 se pinta con esto y desaparece sola si el tope sube o
    /// si el usuario marco "Seguir igual" en este chat (`topeIgnorado`).
    var topeSuperado: Bool {
        guard !conversacion.topeIgnorado else { return false }
        let tope = config.topeAvisoCostoEfectivo
        guard tope > 0, let costo = costoAcumuladoDelChat else { return false }
        return costo >= tope
    }

    /// Sube (o fija) el tope global de aviso y lo persiste.
    func fijarTopeAviso(_ valor: Double) {
        guard valor > 0 else { return }
        config.topeAvisoCosto = valor
    }

    /// Enciende o apaga «Memoria inteligente» desde Mi Contexto (B2.3).
    ///
    /// Cambiar el interruptor NO crea, borra ni edita ninguna entrada: solo
    /// elige la instruccion de disparo del siguiente payload. La lista de
    /// entradas queda intacta y el valor se persiste con la configuracion.
    func fijarMemoriaInteligente(_ activa: Bool) {
        guard config.memoriaInteligente != activa else { return }
        config.memoriaInteligente = activa
    }

    /// "Seguir igual" de la franja: silencia el tope solo en este chat.
    func ignorarTopeEnEsteChat() {
        guard !conversacion.topeIgnorado else { return }
        conversacion.topeIgnorado = true
        guardarActual()
    }

    /// [Reiniciar contador] de Mi Contexto: pone a cero solo el acumulado
    /// desde el ultimo reinicio; el de "Hoy" se reinicia solo al cambiar el dia.
    func reiniciarContadorGasto() {
        config.gasto.reiniciar()
    }

    /// Gasto del dia que se debe ensenar ahora mismo.
    ///
    /// Si la fecha guardada no es la de hoy, el contador diario se lee como
    /// cero aunque todavia no haya llegado ningun uso: el dia ya cambio.
    var gastoDelDiaVisible: Double {
        config.gasto.fechaDelDia == Self.hoyComoClave() ? config.gasto.delDia : 0
    }

    /// Resumen completo de la vista Gasto (SPEND.1/SPEND.2).
    ///
    /// Se arma SOLO con el libro de sellos: no consulta al proveedor activo ni
    /// sus precios, asi que cambiar de modelo no mueve ninguna cifra. La fecha
    /// se puede pasar para que las pruebas sean deterministas.
    func resumenDeGasto(ahora: Date = Date()) -> ResumenGasto {
        ResumenGasto.desde(libro: config.usoApp, ahora: ahora)
    }

    /// Suma a los contadores y al libro de gasto el costo de un uso recibido.
    ///
    /// Es el punto UNICO de alimentacion: lo llaman los turnos normales
    /// (envios y regeneraciones) y la llamada de resumen de /compact. El
    /// contador vive en `AppConfig`, asi que borrar un chat no lo resta; el
    /// libro de COST.2 anota la misma llamada en su dia, su mes y su modelo.
    ///
    /// El USD que entra al libro es el mismo que se sella en el mensaje: se
    /// calcula con los precios del proveedor que genero ESTA llamada. Si no
    /// tiene precios, el libro guarda los tokens y marca el uso como "sin
    /// precio" en vez de inventar un dolar.
    private func registrarGasto(
        uso: UsoTokens?,
        proveedor: ProviderConfig,
        fecha: Date = Date()
    ) {
        guard let uso, uso.total > 0 else { return }

        let costo = CostoEstimado.costo(
            uso: uso,
            precioEntrada: proveedor.precioEntradaPorMillon,
            precioSalida: proveedor.precioSalidaPorMillon
        )

        if let costo, costo > 0 {
            config.gasto.registrar(costo: costo, hoy: Self.hoyComoClave(fecha))
        }

        // El libro anota la llamada real aunque no se pueda valorar: los tokens
        // son un hecho. Sin precios, el USD queda en cero y el uso se marca
        // como "sin precio" para que la vista Gasto lo declare aparte.
        config.usoApp.registrar(
            uso: uso,
            usd: costo ?? 0,
            fecha: fecha,
            modelo: proveedor.modelo,
            conPrecio: costo != nil
        )
    }

    /// Fecha local de `fecha` en el formato que guarda `ContadoresGasto`.
    private static func hoyComoClave(_ fecha: Date = Date()) -> String {
        let formateador = DateFormatter()
        formateador.calendar = Calendar(identifier: .gregorian)
        formateador.locale = Locale(identifier: "en_US_POSIX")
        formateador.dateFormat = "yyyy-MM-dd"
        return formateador.string(from: fecha)
    }

    /// Proveedor y clave con los que se puede enviar, o nil si falta algo.
    ///
    /// En modo capturas no hay llavero real ni clave: el motor de prueba no la
    /// usa, asi que se permite enviar con una clave vacia para que la captura
    /// solo tenga que escribir y pulsar enviar.
    private func proveedorYClaveParaEnviar() -> (ProviderConfig, String)? {
        if estadoDePrueba != nil {
            guard let proveedor = config.proveedorSeleccionado else {
                error = "Falta la configuracion del proveedor."
                return nil
            }
            return (proveedor, "")
        }

        if let problema = problemaDeConfiguracion() {
            error = problema
            return nil
        }

        guard let proveedor = config.proveedorSeleccionado,
              let clave = clave(para: proveedor)
        else {
            error = "Falta la configuracion del proveedor."
            return nil
        }
        return (proveedor, clave)
    }

    /// Proveedor y clave de un combo concreto, sin mirar cual es el activo.
    ///
    /// Lo usa "Regenerar con...": el combo elegido solo alimenta el motor de
    /// esa regeneracion puntual, no cambia la configuracion global.
    private func proveedorYClave(para proveedor: ProviderConfig) -> (ProviderConfig, String)? {
        if estadoDePrueba != nil {
            return (proveedor, "")
        }

        do {
            try proveedor.validar()
        } catch {
            self.error = error.localizedDescription
            return nil
        }

        guard let clave = clave(para: proveedor), !clave.isEmpty else {
            error = "Falta la clave de API de \(proveedor.nombre)."
            return nil
        }
        return (proveedor, clave)
    }

    // MARK: - Proveedores

    /// Crea un proveedor nuevo como borrador, sin tocar la configuracion.
    ///
    /// El editor solo lo guarda si el usuario confirma; asi Cancelar no deja
    /// registros a medias ni cambia el proveedor activo.
    func proveedorNuevo() -> ProviderConfig {
        ProviderConfig(
            nombre: "Proveedor",
            protocolo: .chatCompletions,
            baseURL: "https://",
            modelo: ""
        )
    }

    /// Borrador de un registro que hereda nombre, URL y clave de otro.
    ///
    /// Es el "+ Anadir modelo/combo" de Conexiones (§3.6): el registro nace
    /// con el modelo y los precios vacios para que solo haya que escribir el
    /// ID y sus dos precios. La clave se copia ya al llavero con el id nuevo,
    /// de modo que el Editor la muestre rellena y Guardar no la borre.
    func proveedorDuplicado(desde origen: ProviderConfig) -> ProviderConfig {
        var nuevo = origen
        nuevo.id = UUID()
        nuevo.modelo = ""
        nuevo.precioEntradaPorMillon = nil
        nuevo.precioSalidaPorMillon = nil

        if let clave = clave(para: origen),
           !clave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guardarClave(clave, para: nuevo)
        }
        return nuevo
    }

    /// Borra la clave de un borrador que nunca llego a guardarse.
    ///
    /// Al abrir "+ Anadir modelo/combo" la clave se copia al llavero antes de
    /// tiempo para que el Editor la muestre. Si el usuario cancela, ese
    /// registro no entra en la configuracion y su credencial tampoco debe
    /// quedarse huerfana.
    func descartarClave(para proveedor: ProviderConfig) {
        guard persistir else { return }
        try? llavero.borrar(proveedor.claveKeychain)
        clavesVersion += 1
    }

    func actualizarProveedor(_ proveedor: ProviderConfig) {
        if let indice = config.proveedores.firstIndex(where: { $0.id == proveedor.id }) {
            config.proveedores[indice] = proveedor
        } else {
            // Un proveedor recien creado entra aqui al confirmar Guardar.
            config.proveedores.append(proveedor)
            config.proveedorActivo = proveedor.id
        }
    }

    func borrarProveedor(_ proveedor: ProviderConfig) {
        config.proveedores.removeAll { $0.id == proveedor.id }
        if persistir {
            try? llavero.borrar(proveedor.claveKeychain)
        }

        if config.proveedorActivo == proveedor.id {
            config.proveedorActivo = config.proveedores.first?.id
        }
    }

    // MARK: - Conversaciones

    func recargarConversaciones() {
        // En modo capturas `store` es nil: se conserva el estado sembrado en
        // memoria en lugar de vaciar la lista.
        guard let store else { return }
        conversaciones = store.listar()
    }

    func nuevaConversacion(sinMemoria: Bool = false) {
        cancelar()
        limpiarEventosVisuales()
        limpiarErrorDeTurno()
        limpiarEstadoDeCaja()
        conversacion = Conversation(sinMemoria: sinMemoria)
    }

    /// Crea un hilo de Chat Temporal (B2.2): el camino de creacion propio.
    ///
    /// POR QUE no es `nuevaConversacion(sinMemoria: true)`: un chat sin memoria
    /// es un chat normal que se guarda; el temporal no llega nunca al almacen,
    /// no ofrece herramientas de escritura de Memoria y su cabecera lo declara
    /// durante todo el hilo. La conversacion se construye ya marcada
    /// `esTemporal`, asi el resto del estado (payload, persistencia, respaldo)
    /// la trata distinto desde el primer instante.
    func nuevaConversacionTemporal() {
        cancelar()
        limpiarEventosVisuales()
        limpiarErrorDeTurno()
        limpiarEstadoDeCaja()
        conversacion = Conversation(esTemporal: true)
    }

    /// True si el hilo abierto es un Chat Temporal.
    var hiloTemporal: Bool {
        conversacion.esTemporal
    }

    /// Alterna el hilo abierto entre normal y temporal: UN toque (R19).
    ///
    /// Solo se puede alternar ANTES del primer mensaje: con mensajes ya
    /// enviados el modo queda fijado (un hilo temporal no se persiste y no
    /// puede convertirse en normal sin guardar lo conversado). Devuelve `true`
    /// si el toque cambio el modo, `false` si no habia nada que cambiar.
    @discardableResult
    func alternarChatTemporal() -> Bool {
        guard conversacion.mensajes.isEmpty, !enviando else { return false }
        conversacion.esTemporal.toggle()
        return true
    }

    /// Cierra el hilo temporal abierto: camino de SALIDA propio (B2.2).
    ///
    /// No guarda nada, no deja borrador y no toca la lista ni Mi Contexto: el
    /// hilo se descarta y la app vuelve a un chat normal vacio. Si el hilo
    /// abierto no es temporal no hace nada (un chat normal se guarda como
    /// siempre).
    func cerrarHiloTemporal() {
        guard conversacion.esTemporal else { return }
        cancelar()
        limpiarEventosVisuales()
        limpiarErrorDeTurno()
        // El borrador de un hilo temporal se borra al cerrar el hilo.
        limpiarEstadoDeCaja()
        conversacion = Conversation()
    }

    func abrir(_ otra: Conversation) {
        cancelar()
        limpiarEventosVisuales()
        limpiarErrorDeTurno()
        limpiarEstadoDeCaja()
        conversacion = otra
    }

    /// Crea una conversacion nueva con el historial clonado hasta `mensaje`
    /// (inclusive) y entra directamente en ella (§5.4).
    ///
    /// El clon y su acumulado salen del nucleo (`ramificar`): la copia hereda
    /// los usos de los mensajes clonados, asi que su costo sigue siendo honesto
    /// desde el primer mensaje. La conversacion original no se toca.
    func ramificar(desde mensaje: ChatMessage) {
        // B2.2: un hilo temporal no se ramifica. La rama es un chat NUEVO que
        // si se guarda; sacarla de un hilo que promete no dejar rastro seria
        // justo el rastro que el modo evita. La vista no ofrece la accion en
        // ese hilo; esta guarda cubre cualquier llamada futura.
        guard conversacion.sePersiste else { return }
        guard let nueva = conversacion.ramificar(hastaElMensaje: mensaje.id) else {
            return
        }

        // COMP.3: la rama hereda el resumen y el balde sellado de lo ya
        // resumido. El acumulado facturable no puede perderse al ramificar, y
        // en un chat sin Memoria el respaldo persistido es la unica via para
        // que el resumen llegue al siguiente payload.
        let claveOrigen = conversacion.id.uuidString
        let claveNueva = nueva.id.uuidString
        if let resumen = resumenesCompactadosPorConversacion[claveOrigen] {
            resumenesCompactadosPorConversacion[claveNueva] = resumen
        }
        if let uso = usoResumidoPorConversacion[claveOrigen] {
            usoResumidoPorConversacion[claveNueva] = uso
        }

        try? store?.guardar(nueva)
        if store == nil {
            // En capturas no hay almacen: se conserva la lista en memoria para
            // que la copia tambien exista si se vuelve atras.
            conversaciones.append(nueva)
        } else {
            recargarConversaciones()
        }

        abrir(nueva)
        // La raiz observa este id y reinicia la pila: raiz -> copia, la misma
        // profundidad que una apertura normal desde la lista.
        idParaAbrirReiniciandoRuta = nueva.id
    }

    func borrar(_ otra: Conversation) {
        if conversacion.id == otra.id {
            cancelar()
        }
        try? store?.borrar(id: otra.id)
        usoResumidoPorConversacion.removeValue(forKey: otra.id.uuidString)
        // COMP.2: el resumen pertenece a esa conversacion; si se borra, no
        // puede quedar un respaldo huerfano que un id reutilizado pudiera leer.
        resumenesCompactadosPorConversacion.removeValue(forKey: otra.id.uuidString)
        if store == nil {
            // En capturas no hay almacen: la lista en memoria tambien refleja
            // el borrado para que la pantalla no ensene una fila fantasma.
            conversaciones.removeAll { $0.id == otra.id }
        }
        if conversacion.id == otra.id {
            limpiarEventosVisuales()
            limpiarErrorDeTurno()
            limpiarEstadoDeCaja()
            conversacion = Conversation()
        }
        recargarConversaciones()
    }

    /// Refleja en la lista en memoria un cambio de una conversacion cuando no
    /// hay almacen (modo capturas). En produccion manda `recargarConversaciones`.
    private func reemplazarEnMemoria(_ conversacion: Conversation) {
        guard store == nil,
              let indice = conversaciones.firstIndex(where: { $0.id == conversacion.id })
        else {
            return
        }
        conversaciones[indice] = conversacion
    }

    /// Deja limpio todo lo que pertenece a la caja de la conversacion abierta.
    private func limpiarEstadoDeCaja() {
        borrador = ""
        avisoComando = nil
        mostrarHojaModelos = false
        textoParaCompartirSolicitado = nil
        idParaAbrir = nil
        idParaAbrirReiniciandoRuta = nil
    }

    /// Cambia el proveedor activo y deja el divisor visual del cambio de modelo.
    ///
    /// El evento solo se pinta si el chat ya tiene mensajes; el historial no se
    /// toca y el cambio aplica desde el siguiente turno (SPEC §3.2/§2.6).
    func cambiarProveedor(_ proveedor: ProviderConfig) {
        guard config.proveedorActivo != proveedor.id else { return }

        // Si el id guardado no existia, el proveedor ya se estaba mostrando
        // como seleccionado por el respaldo: se corrige el id sin divisor.
        let yaSeleccionado = config.proveedorSeleccionado?.id == proveedor.id
        config.proveedorActivo = proveedor.id

        guard !yaSeleccionado,
              !conversacion.mensajes.isEmpty,
              let ultimo = conversacion.mensajes.last?.id
        else {
            return
        }

        let modelo = NombresLimpios.modelo(proveedor.modelo)
        let nombre = modelo.isEmpty
            ? NombresLimpios.proveedor(nombre: proveedor.nombre, baseURL: proveedor.baseURL)
            : modelo
        registrarEventoVisual("── Ahora responde \(nombre) ──", tras: ultimo)
    }

    /// Adopta el proveedor del turno sin reescribir la historia.
    ///
    /// Antes de cambiar el id del chat, los mensajes viejos que no traen
    /// proveedor propio se anclan al que tenia el chat: si no, al enviar con
    /// otro modelo quedarian valorados con los precios nuevos.
    private func adoptarProveedorDelChat(_ proveedor: ProviderConfig) {
        let anterior = conversacion.proveedorID
        if let anterior, anterior != proveedor.id {
            for indice in conversacion.mensajes.indices
            where conversacion.mensajes[indice].proveedorID == nil {
                conversacion.mensajes[indice].proveedorID = anterior
            }

            // El consumo de /compact guardado con el formato viejo tampoco
            // puede quedar apuntando al proveedor nuevo.
            let clave = conversacion.id.uuidString
            if var resumido = usoResumidoPorConversacion[clave],
               let sinProveedor = resumido.porProveedor
                   .removeValue(forKey: UsoResumido.sinProveedor) {
                resumido.sumar(sinProveedor, proveedorID: anterior)
                usoResumidoPorConversacion[clave] = resumido
            }
        }
        conversacion.proveedorID = proveedor.id
    }

    /// Activa o desactiva la Memoria en el chat abierto y lo persiste.
    ///
    /// Al apagarla con mensajes ya enviados se deja el divisor del punto exacto
    /// del cambio; los turnos anteriores ya viajaron con la Memoria (§4.6).
    func alternarSinMemoria() {
        // B2.2: en un hilo temporal el interruptor no tendria efecto
        // observable (el temporal no usa la Memoria por definicion), asi que
        // no se ofrece ni cambia nada. En un chat normal sigue como siempre.
        guard !conversacion.esTemporal else { return }
        let teniaMensajes = !conversacion.mensajes.isEmpty
        conversacion.sinMemoria.toggle()

        if conversacion.sinMemoria, teniaMensajes,
           let ultimo = conversacion.mensajes.last?.id {
            registrarEventoVisual(
                "── Memoria desactivada desde este mensaje ──",
                tras: ultimo
            )
        }

        guardarActual()
    }

    private func limpiarEventosVisuales() {
        eventosVisuales = []
    }

    private func limpiarErrorDeTurno() {
        errorDeTurno = nil
        turnoFallido = nil
    }

    private func registrarEventoVisual(_ texto: String, tras mensaje: UUID?) {
        eventosVisuales.append(EventoVisual(trasMensaje: mensaje, texto: texto))
    }

    /// Mueve al ultimo mensaje del usuario los divisores que colgaban del turno
    /// que se va a regenerar.
    ///
    /// Sin esto, un "── Ahora responde X ──" anclado a la respuesta descartada
    /// quedaria huerfano y se pintaria despues de la respuesta nueva.
    private func reanclarEventosDelTurnoDescartado(_ descartados: [ChatMessage]) {
        let ids = Set(descartados.map(\.id))
        guard let ancla = conversacion.mensajes.last(where: { $0.rol == .usuario })?.id else {
            return
        }

        for indice in eventosVisuales.indices {
            guard let tras = eventosVisuales[indice].trasMensaje,
                  ids.contains(tras),
                  eventosVisuales[indice].texto.hasPrefix("── Ahora responde")
            else {
                continue
            }
            eventosVisuales[indice] = EventoVisual(
                id: eventosVisuales[indice].id,
                trasMensaje: ancla,
                texto: eventosVisuales[indice].texto,
                cambioMemoria: eventosVisuales[indice].cambioMemoria,
                deshecho: eventosVisuales[indice].deshecho
            )
        }
    }

    func renombrar(_ otra: Conversation, titulo: String) {
        // Un hilo temporal no tiene fila ni archivo que renombrar (B2.2).
        guard otra.sePersiste else { return }
        var copia = otra
        copia.titulo = titulo
        try? store?.guardar(copia)
        reemplazarEnMemoria(copia)
        recargarConversaciones()
    }

    /// Fija o desfija una conversacion sin tocar la que este abierta.
    func fijar(_ otra: Conversation, fijada: Bool = true) {
        guard otra.sePersiste else { return }
        var copia = otra
        copia.fijada = fijada
        try? store?.guardar(copia)
        if conversacion.id == copia.id {
            conversacion.fijada = fijada
        }
        reemplazarEnMemoria(copia)
        recargarConversaciones()
    }

    func desfijar(_ otra: Conversation) {
        fijar(otra, fijada: false)
    }

    /// Archiva o desarchiva una conversacion sin tocar la que este abierta.
    func archivar(_ otra: Conversation, archivada: Bool = true) {
        // Archivar es escribir: un hilo temporal no llega al almacen.
        guard otra.sePersiste else { return }
        var copia = otra
        copia.archivada = archivada
        try? store?.guardar(copia)
        if conversacion.id == copia.id {
            conversacion.archivada = archivada
        }
        reemplazarEnMemoria(copia)
        recargarConversaciones()
    }

    func desarchivar(_ otra: Conversation) {
        archivar(otra, archivada: false)
    }

    /// Punto UNICO de escritura de la conversacion abierta.
    ///
    /// B2.2: el camino de salida del Chat Temporal se decide aqui. Un hilo
    /// temporal no pasa por el almacen ni refresca la lista, de modo que
    /// enviar, regenerar, reintentar, fallar o compactar no dejan rastro por
    /// mucho que llamen a `persistirActual`.
    private func guardarActual() {
        guard conversacion.sePersiste else { return }
        try? store?.guardar(conversacion)
        recargarConversaciones()
    }

    private func persistirActual() {
        conversacion.actualizada = Date()
        guardarActual()
    }

    // MARK: - Tareas

    /// Vuelve a leer la lista de tareas del almacen.
    ///
    /// En modo capturas `storeTareas` es nil: se conserva la lista en memoria.
    func recargarTareas() {
        guard let storeTareas else { return }
        tareas = storeTareas.listar()
    }

    /// Crea una tarea en borrador y la persiste.
    ///
    /// Nace sin plan: la vista de la tarea pide el plan al aparecer o cuando el
    /// dueno pulsa Regenerar. El proveedor queda anotado para que el plan se
    /// genere con el que tenia la tarea, no con el activo de otro momento.
    @discardableResult
    func crearTarea(instruccion: String = "", conversacionID: UUID? = nil) -> Tarea {
        let limpia = instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
        var tarea = Tarea(
            instruccion: limpia,
            conversacionID: conversacionID,
            proveedorID: config.proveedorSeleccionado?.id
        )
        // El encargo es el primer turno del hilo (B3-A): una tarea creada con
        // instruccion ya muestra su burbuja al abrir, sin un campo aparte.
        if !limpia.isEmpty {
            tarea.turnos = [
                TurnoTarea(rol: .usuario, texto: limpia)
            ]
        }
        guardarTarea(tarea)
        return tarea
    }

    /// Borra una tarea y su archivo. El plan y el libro se van con ella.
    func borrarTarea(id: UUID) {
        // Una ejecucion viva no puede seguir escribiendo un archivo que se va a
        // borrar: primero se detiene y se resuelve cualquier aprobacion abierta.
        if idTareaEjecutando == id {
            detenerTarea(id: id)
        }
        do {
            try storeTareas?.borrar(id: id)
        } catch {
            errorTarea = "No se pudo borrar la tarea."
        }
        if storeTareas == nil {
            tareas.removeAll { $0.id == id }
        }
        recargarTareas()
    }

    /// Comodo para las vistas que ya tienen la tarea.
    func borrarTarea(_ tarea: Tarea) {
        borrarTarea(id: tarea.id)
    }

    /// Guarda una instruccion editada y invalida el plan anterior.
    ///
    /// POR QUE invalida el plan: un plan generado para otra instruccion no
    /// describe lo que se va a ejecutar. El dueno tiene que regenerarlo antes
    /// de poder pulsar Empezar.
    func actualizarInstruccionTarea(id: UUID, instruccion: String) {
        guard let indice = tareas.firstIndex(where: { $0.id == id }),
              tareas[indice].admiteEdicion
        else {
            return
        }

        let limpia = instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpia.isEmpty else {
            errorTarea = "Escribe una instrucción para la tarea."
            return
        }

        tareas[indice].instruccion = limpia
        tareas[indice].plan = nil
        tareas[indice].estado = .borrador
        tareas[indice].fechaActualizacion = Date()
        guardarTarea(tareas[indice])
    }

    /// Pide al modelo un plan por pasos y lo guarda en la tarea.
    ///
    /// Es el mismo mecanismo que usa /plan en un chat: una sola llamada al
    /// motor con `herramientas: []`, sin ToolLoop y sin tocar MCP. El payload
    /// no lleva el arreglo `tools` aunque haya servidor configurado; por eso el
    /// plan es solo texto y no puede ejecutar nada.
    ///
    /// - Parameters:
    ///   - id: tarea a planificar.
    ///   - instruccion: si viene, sustituye a la guardada antes de pedir el plan.
    ///   - instruccionVisible: texto que queda como `instruccion` de la tarea
    ///     cuando el prompt del plan es una composicion de turnos (B3-A). nil
    ///     conserva el comportamiento historico: se guarda `instruccion`.
    func generarPlan(
        id: UUID,
        instruccion: String? = nil,
        instruccionVisible: String? = nil
    ) async {
        guard !generandoPlan else { return }
        guard let indice = tareas.firstIndex(where: { $0.id == id }) else { return }

        let cruda = (instruccion ?? tareas[indice].instruccion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cruda.isEmpty else {
            errorTarea = "Escribe una instrucción para generar el plan."
            return
        }
        // En una tarea /boost el prefijo es el disparo, no parte del encargo:
        // el plan se pide sobre el texto efectivo, pero se guarda la instruccion
        // cruda para que el modo se pueda seguir derivando de ella.
        let limpia = AnalizadorComandos.instruccionDeBoost(cruda) ?? cruda
        guard !limpia.isEmpty else {
            errorTarea = "Escribe la instrucción del boost después de /boost."
            return
        }
        guard tareas[indice].admiteEdicion else {
            errorTarea = "La tarea ya empezó: el plan no se puede cambiar."
            return
        }

        // La version del plan se captura ANTES de invalidarlo: cada plan nuevo
        // es la version anterior + 1 (B3-A). El contador vive en la tarea para
        // que una regeneracion fallida no lo reinicie a 1.
        let versionAnterior = max(
            tareas[indice].versionPlan,
            tareas[indice].plan?.version ?? 0
        )

        // La instruccion editada se guarda antes de salir a la red. Si la
        // llamada falla, el dueno no pierde lo que escribio.
        tareas[indice].instruccion = instruccionVisible ?? cruda
        tareas[indice].plan = nil
        tareas[indice].estado = .borrador
        tareas[indice].fechaActualizacion = Date()
        guardarTarea(tareas[indice])

        // `guardarTarea` recarga la lista ordenada: se vuelve a buscar la tarea
        // por id en vez de reutilizar el indice anterior.
        guard let tareaParaPlan = tareas.first(where: { $0.id == id }),
              let (proveedor, clave) = proveedorYClaveParaTarea(tareaParaPlan)
        else {
            // Un proveedor ausente o sin clave tambien es un error visible del
            // hilo (E7), no solo un aviso global que se pierde al reabrir.
            if let mensaje = errorTarea {
                anotarErrorDeTarea(id: id, mensaje: mensaje)
            }
            return
        }

        generandoPlan = true
        idTareaPlanificando = id
        errorTarea = nil
        defer {
            generandoPlan = false
            idTareaPlanificando = nil
        }

        do {
            let motor = motorPara(proveedor: proveedor, clave: clave)
            let respuesta = try await motor.responder(
                mensajes: PlanTarea.mensajesParaSolicitar(instruccion: limpia),
                // El plan se genera en modo solo-texto: ninguna herramienta,
                // ni siquiera si hay un servidor MCP configurado.
                herramientas: [],
                alRecibirTexto: nil
            )
            try Task.checkCancellation()

            // El plan consume cuota como cualquier llamada; se anota en el
            // acumulador global aunque no pertenezca a una conversacion.
            registrarGasto(uso: respuesta.uso, proveedor: proveedor)

            // COST de la tarea: la planificacion tambien es una llamada al
            // modelo dentro de la tarea y su sello forma parte del acumulado.
            var costoDeLaLlamada: Double?
            if let uso = respuesta.uso {
                var mensaje = ChatMessage(
                    rol: .asistente,
                    texto: "",
                    tokensEntrada: uso.entrada,
                    tokensSalida: uso.salida
                )
                SellosDeCosto.sellar(&mensaje, proveedor: proveedor)
                costoDeLaLlamada = mensaje.costoSelladoUSD
            }

            var plan = PlanTarea.desde(
                texto: respuesta.texto,
                proveedorID: proveedor.id
            )
            guard !plan.pasos.isEmpty else {
                anotarErrorDeTarea(
                    id: id,
                    mensaje: "El modelo devolvió un plan vacío. Inténtalo de nuevo."
                )
                return
            }
            plan.version = versionAnterior + 1

            // La tarea pudo borrarse o empezar mientras llegaba la respuesta:
            // en ese caso el plan ya no se publica.
            guard let actual = tareas.firstIndex(where: { $0.id == id }),
                  tareas[actual].admiteEdicion
            else {
                return
            }
            tareas[actual].instruccion = instruccionVisible ?? cruda
            tareas[actual].plan = plan
            tareas[actual].versionPlan = plan.version
            tareas[actual].estado = .esperandoInicio
            tareas[actual].proveedorID = proveedor.id
            tareas[actual].ultimoError = nil
            if let costoDeLaLlamada {
                tareas[actual].costoAcumuladoUSD =
                    (tareas[actual].costoAcumuladoUSD ?? 0) + costoDeLaLlamada
            }
            tareas[actual].fechaActualizacion = Date()
            guardarTarea(tareas[actual])
        } catch is CancellationError {
            // Cambiar de pantalla o borrar la tarea no deja un error falso.
        } catch {
            let detalle = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            anotarErrorDeTarea(
                id: id,
                mensaje: "No se pudo generar el plan: \(detalle)"
            )
        }
    }

    // MARK: - Hilo conversacional de Tarea (B3-A)

    /// Registra un mensaje del dueno como turno del hilo de la tarea.
    ///
    /// Es la mitad sincrona del envio: persiste el turno y deja la tarea lista
    /// para pedir el plan. El primer mensaje de una tarea vacia ES el encargo y
    /// alimenta `instruccion` (fuente del motor y del titulo); los siguientes
    /// son ajustes. Un mensaje posterior a la ejecucion solo queda como turno:
    /// no reabre pasos cerrados ni reescribe el plan aprobado.
    @discardableResult
    func registrarMensajeTarea(id: UUID, texto: String) -> Bool {
        guard !generandoPlan else { return false }
        guard let indice = tareas.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return false }
        guard tareas[indice].estado != .enCurso else {
            errorTarea = "La tarea está en curso: detenla antes de escribir."
            return false
        }

        var tarea = tareas[indice]
        let posterior = !tarea.pasos.isEmpty
            || tarea.estado.esFinal
            || tarea.estado == .detenida
        tarea.turnos.append(
            TurnoTarea(
                rol: .usuario,
                texto: limpio,
                despuesDeEjecutar: posterior
            )
        )
        if tarea.turnos.count == 1 {
            tarea.instruccion = limpio
        }
        tarea.ultimoError = nil
        tarea.fechaActualizacion = Date()
        guardarTarea(tarea)

        // La cabecera muestra «Planificando» desde el instante en que el
        // encargo entra al hilo, no solo mientras la red esta abierta.
        if tarea.admiteEdicion {
            idTareaPlanificando = id
        }
        return true
    }

    /// Pide el plan de la tarea a partir de sus turnos de planificacion.
    ///
    /// El prompt es el encargo mas una linea «Ajuste: …» por cada mensaje
    /// posterior. `instruccion` visible se queda en el encargo para que el
    /// titulo de la tarea no cambie con cada ajuste.
    func solicitarPlanTarea(id: UUID) async {
        guard let tarea = tareas.first(where: { $0.id == id }) else { return }
        guard tarea.admiteEdicion else {
            idTareaPlanificando = nil
            return
        }
        await generarPlan(
            id: id,
            instruccion: tarea.instruccionParaPlan,
            instruccionVisible: tarea.instruccion
        )
        // Si generarPlan sale antes de su propio defer (falta de proveedor,
        // plan vacio), la cabecera no puede quedarse en «Planificando».
        if idTareaPlanificando == id {
            idTareaPlanificando = nil
        }
    }

    /// Envio completo del composer de Tarea: registra el turno y pide el plan.
    func enviarMensajeTarea(id: UUID, texto: String) async {
        guard registrarMensajeTarea(id: id, texto: texto) else { return }
        await solicitarPlanTarea(id: id)
    }

    /// Accion [Ajustar / Regenerar] de la tarjeta: mismo efecto sin mensaje.
    func regenerarPlanTarea(id: UUID) async {
        guard let tarea = tareas.first(where: { $0.id == id }) else { return }
        guard tarea.admiteEdicion else { return }
        idTareaPlanificando = id
        await generarPlan(
            id: id,
            instruccion: tarea.instruccionParaPlan,
            instruccionVisible: tarea.instruccion
        )
        if idTareaPlanificando == id {
            idTareaPlanificando = nil
        }
    }

    /// Deja el error en la tarea para que el hilo lo muestre en su punto (E7)
    /// y no como una alerta que tape la conversacion.
    private func anotarErrorDeTarea(id: UUID, mensaje: String) {
        errorTarea = mensaje
        modificarTarea(id: id) { tarea in
            tarea.ultimoError = mensaje
        }
    }

    /// Autoriza la ejecucion y arranca el ToolLoop de la tarea.
    ///
    /// Empezar ya no deja la tarea "en curso" sin hacer nada: TASK.3 conecta el
    /// mismo bucle que usa el chat, con las herramientas DE TAREA. La llamada
    /// vuelve enseguida; el trabajo corre en `ejecucionTarea`.
    @discardableResult
    func empezarTarea(id: UUID) -> Bool {
        guard let indice = tareas.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard tareas[indice].admiteEdicion else {
            return false
        }
        guard tareas[indice].plan != nil else {
            errorTarea = "Genera el plan antes de empezar la tarea."
            return false
        }

        var tarea = tareas[indice]
        tarea.estado = .enCurso
        tarea.fechaActualizacion = Date()
        // Una tarea que empieza de cero no arrastra un libro de otra corrida.
        // El costo de planificacion si se conserva: ya se gasto en esta tarea.
        tarea.pasos = []
        // La respuesta y su marca de verificacion pertenecen a la corrida
        // anterior: si el dueno vuelve a empezar, no puede quedar una respuesta
        // vieja marcada como verificada.
        tarea.resultado = nil
        tarea.verificadoPorCruce = false
        tarea.ultimoError = nil
        guardarTarea(tarea)
        errorTarea = nil
        lanzarEjecucionTarea(id: id)
        return true
    }

    /// Reanuda una tarea detenida o interrumpida desde su libro.
    ///
    /// No borra ni repite los pasos resueltos: se reinyectan como historial de
    /// herramientas para que el modelo sepa que ya se hizo. Los pasos que
    /// quedaron "en curso" al cerrar la app se marcan fallidos antes de seguir.
    @discardableResult
    func reanudarTarea(id: UUID) -> Bool {
        guard let indice = tareas.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard tareas[indice].estado == .detenida
            || tareas[indice].estado == .interrumpida
        else {
            return false
        }
        guard tareas[indice].plan != nil else {
            errorTarea = "La tarea no tiene plan para reanudar."
            return false
        }

        var tarea = tareas[indice]
        for paso in tarea.pasos.indices {
            if tarea.pasos[paso].estado == .enCurso
                || tarea.pasos[paso].estado == .pendiente {
                tarea.pasos[paso].estado = .fallido
                tarea.pasos[paso].resultado = "Interrumpida antes de terminar."
                tarea.pasos[paso].fechaFin = Date()
            }
        }

        tarea.estado = .enCurso
        tarea.fechaActualizacion = Date()
        guardarTarea(tarea)
        errorTarea = nil
        lanzarEjecucionTarea(id: id)
        return true
    }

    /// Detiene la ejecucion en curso sin tocar los pasos ya resueltos.
    ///
    /// La generacion se invalida ANTES de cancelar: los ganchos de una tarea
    /// vieja que despierta tarde no pueden escribir en el libro que el dueno
    /// acaba de congelar.
    func detenerTarea(id: UUID) {
        let enCursoSinEjecucion = idTareaEjecutando == nil
            && tareas.first(where: { $0.id == id })?.estado == .enCurso
        guard idTareaEjecutando == id || enCursoSinEjecucion else {
            return
        }

        generacionEjecucionTarea = UUID()
        ejecucionTarea?.cancel()
        ejecucionTarea = nil
        idTareaEjecutando = nil
        resolverAprobacion(false)

        modificarTarea(id: id) { tarea in
            tarea.estado = .detenida
            for indice in tarea.pasos.indices {
                if tarea.pasos[indice].estado == .enCurso
                    || tarea.pasos[indice].estado == .pendiente {
                    tarea.pasos[indice].estado = .fallido
                    tarea.pasos[indice].resultado = "Detenida por el dueño."
                    tarea.pasos[indice].fechaFin = Date()
                }
            }
        }
    }

    /// Resuelve la hoja a favor: la herramienta se ejecuta y el paso sigue.
    func aprobarSolicitud() {
        resolverAprobacion(true)
    }

    /// Resuelve la hoja en contra: no se escribe nada y el paso queda Denegado.
    func denegarSolicitud() {
        resolverAprobacion(false)
    }

    private func resolverAprobacion(_ aprobada: Bool) {
        guard let continuacion = continuacionAprobacion else {
            solicitudAprobacion = nil
            idSolicitudAprobacion = nil
            return
        }
        continuacionAprobacion = nil
        solicitudAprobacion = nil
        idSolicitudAprobacion = nil
        continuacion.resume(returning: aprobada)
    }

    // MARK: - Hoja de propuesta sensible de Chat (B2.4)

    /// Resuelve la hoja sensible a favor: recien entonces se escribe la
    /// entrada en Mi Contexto.
    func aprobarPropuestaSensible() {
        resolverPropuestaSensible(aprobada: true)
    }

    /// Resuelve la hoja sensible en contra: no se escribe nada y el turno
    /// recibe el rechazo interno.
    func denegarPropuestaSensible() {
        resolverPropuestaSensible(aprobada: false)
    }

    /// Cerrar la hoja (o el hilo) sin decidir es DENEGAR (B2.4).
    ///
    /// Mismo resultado interno de rechazo y cero persistencia. La hoja no se
    /// puede arrastrar para cerrar, pero Detener, cambiar de chat o cerrar el
    /// hilo pasan por `cancelar()`, que llama aqui antes de cortar el turno.
    func cerrarPropuestaSensible() {
        resolverPropuestaSensible(aprobada: false)
    }

    private func resolverPropuestaSensible(aprobada: Bool) {
        // La hoja deja de proyectarse en el acto; el turno sigue (o se corta)
        // con la decision tomada.
        propuestaMemoriaSensible = nil
        guard let continuacion = continuacionPropuestaSensible else { return }
        continuacionPropuestaSensible = nil
        continuacion.resume(returning: aprobada)
    }

    // MARK: - Ejecucion de la tarea (TASK.3)

    /// Lanza el bucle en una tarea propia y sella la generacion.
    ///
    /// `generacion` es la frontera entre una ejecucion y la siguiente: Detener
    /// la cambia para que los ganchos que despiertan tarde no toquen el libro.
    private func lanzarEjecucionTarea(id: UUID) {
        // Solo se ejecuta una tarea a la vez. Si habia otra viva, se detiene
        // con su libro intacto antes de empezar esta.
        if let anterior = idTareaEjecutando, anterior != id {
            detenerTarea(id: anterior)
        }
        ejecucionTarea?.cancel()
        let generacion = UUID()
        generacionEjecucionTarea = generacion
        idTareaEjecutando = id
        ejecucionTarea = Task { [weak self] in
            guard let self else { return }
            await self.ejecutarTarea(id: id, generacion: generacion)
        }
    }

    private func ejecutarTarea(id: UUID, generacion: UUID) async {
        guard let tarea = tareas.first(where: { $0.id == id }) else {
            if generacion == generacionEjecucionTarea {
                finalizarTareaConError(id: id, mensaje: "La tarea ya no existe.")
                ejecucionTarea = nil
                idTareaEjecutando = nil
            }
            return
        }

        // BOOST.1: una tarea /boost no pasa por el ToolLoop. La tuberia de tres
        // fases corre EN SU LUGAR y escribe sus propios pasos en el mismo libro;
        // asi Detener, Reanudar y el tope de gasto siguen siendo los de TASK.
        if tarea.esDeBoost {
            await ejecutarTuberiaBoost(id: id, generacion: generacion)
            if generacion == generacionEjecucionTarea {
                ejecucionTarea = nil
                idTareaEjecutando = nil
            }
            return
        }

        guard let (proveedor, clave) = proveedorYClaveParaTarea(tarea) else {
            if generacion == generacionEjecucionTarea {
                finalizarTareaConError(
                    id: id,
                    mensaje: errorTarea ?? "No se pudo preparar la ejecución."
                )
                ejecucionTarea = nil
                idTareaEjecutando = nil
            }
            return
        }

        let (herramientas, nombresMCP) = await herramientasDeTarea()
        guard generacion == generacionEjecucionTarea else { return }

        let motor = motorPara(proveedor: proveedor, clave: clave)
        let bucle = ToolLoop(
            motor: motor,
            herramientas: herramientas,
            maxIteraciones: 8
        )

        // La politica vive en NodoCore (deuda DEM reconectada aqui). La lista
        // de exentas del dueno se respeta para lo que no es Memoria; una
        // escritura propuesta SIEMPRE pasa por la hoja.
        let exentas = config.herramientasSinAprobacion ?? []
        bucle.requiereAprobacion = { llamada in
            if llamada.nombre == Memoria.nombreHerramientaTarea {
                return true
            }
            let esMCP = nombresMCP.contains(llamada.nombre)
            // traer_url es la unica HTTP propia y su metodo es GET.
            let metodo = llamada.nombre == "traer_url" ? "GET" : nil
            return PoliticaAprobacion.requiereAprobacion(
                esMCP: esMCP,
                metodoHTTP: metodo,
                nombreHerramienta: llamada.nombre,
                exentas: exentas
            )
        }

        bucle.aprobador = { [weak self] llamada in
            guard let self else { return false }
            return await self.pedirAprobacion(
                llamada,
                idTarea: id,
                generacion: generacion
            )
        }

        bucle.alIniciarHerramienta = { [weak self] llamada in
            guard let self else { return }
            await self.pasoIniciado(
                llamada,
                idTarea: id,
                generacion: generacion
            )
        }
        bucle.alTerminarHerramienta = { [weak self] llamada, resultado in
            guard let self else { return }
            await self.pasoTerminado(
                llamada,
                resultado: resultado,
                idTarea: id,
                generacion: generacion
            )
        }
        bucle.alDenegarHerramienta = { [weak self] llamada, motivo in
            guard let self else { return }
            await self.pasoDenegado(
                llamada,
                motivo: motivo,
                idTarea: id,
                generacion: generacion
            )
        }
        bucle.alTerminarLlamadaModelo = { [weak self] uso in
            guard let self else { return }
            await self.registrarUsoDeTarea(
                uso,
                idTarea: id,
                proveedor: proveedor,
                generacion: generacion
            )
        }

        do {
            let resultado = try await bucle.ejecutar(
                historial: historialDeTarea(tarea)
            )
            guard generacion == generacionEjecucionTarea else { return }

            if resultado.seAgotoElLimite {
                finalizarTareaConError(
                    id: id,
                    mensaje: "Se alcanzó el límite de \(bucle.maxIteraciones) vueltas de herramientas."
                )
            } else {
                modificarTarea(id: id) { tarea in
                    tarea.estado = .completada
                    // E8: el resultado final es el ultimo elemento del hilo.
                    // Hasta B3-A la tarea normal lo descartaba y solo /boost lo
                    // guardaba; la presentacion no puede inventarlo.
                    tarea.resultado = resultado.texto
                    tarea.ultimoError = nil
                }
            }
        } catch is CancellationError {
            // Detener ya dejo el estado Detenida y los pasos previos intactos.
            // Si la cancelacion vino de otro sitio, se declara igual.
            guard generacion == generacionEjecucionTarea else { return }
            modificarTarea(id: id) { tarea in
                tarea.estado = .detenida
            }
        } catch {
            guard generacion == generacionEjecucionTarea else { return }
            let detalle = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            finalizarTareaConError(id: id, mensaje: detalle)
        }

        if generacion == generacionEjecucionTarea {
            ejecucionTarea = nil
            idTareaEjecutando = nil
        }
    }

    // MARK: - Tuberia /boost (BOOST.1)

    /// Corre las tres fases de /boost EN LUGAR del bucle normal.
    ///
    /// No cambia el modelo del turno ni abre un chat: encadena llamadas sueltas
    /// sin herramientas y cada una queda como `Paso` con su proveedor y su
    /// sello COST. La cancelacion se comprueba entre fases para que Detener
    /// corte la tuberia aunque el modelo ya haya respondido la anterior.
    private func ejecutarTuberiaBoost(id: UUID, generacion: UUID) async {
        guard let tarea = tareas.first(where: { $0.id == id }) else { return }
        let problema = tarea.instruccionEfectiva
        guard !problema.isEmpty else {
            finalizarTareaConError(
                id: id,
                mensaje: "El boost necesita una instrucción después de /boost."
            )
            return
        }

        let tope = config.topeAvisoCostoEfectivo
        let preferido = tarea.proveedorID.flatMap { idTarea in
            config.proveedores.first { $0.id == idTarea }
        } ?? config.proveedorSeleccionado

        guard let fuerteBase = Boost.proveedorFuerte(
            en: config.proveedores,
            preferido: preferido
        ), let (fuerte, claveFuerte) = proveedorConClave(fuerteBase) else {
            guard generacion == generacionEjecucionTarea else { return }
            finalizarTareaConError(
                id: id,
                mensaje: errorTarea ?? "No hay proveedor utilizable para el boost."
            )
            return
        }

        do {
            // El tope se mira tambien antes de la primera fase: el plan ya
            // gasto, y una tuberia no puede arrancar por encima del limite.
            guard puedeCorrerFaseBoost(id: id, tope: tope, fase: .orquestacion)
            else {
                return
            }

            // FASE 1 — Orquestacion con el combo fuerte: descompone el problema.
            let orquestacion = try await correrFaseBoost(
                id: id,
                generacion: generacion,
                fase: .orquestacion,
                numeroAngulo: nil,
                descripcion: "Orquestación: descomponer el problema en ángulos",
                proveedor: fuerte,
                clave: claveFuerte,
                mensajes: Boost.mensajesOrquestacion(problema: problema)
            )
            guard generacion == generacionEjecucionTarea else { return }

            let desglose = Boost.angulos(desde: orquestacion.texto)
            if desglose.parseoFallido {
                // Se declara en el propio paso: el dueno tiene que saber que la
                // "lista de angulos" fue en realidad la respuesta entera.
                anotarResultadoDePaso(
                    idTarea: id,
                    pasoID: orquestacion.pasoID,
                    generacion: generacion,
                    nota: "parseo fallido: la respuesta completa se toma como un solo ángulo"
                )
            }
            guard !desglose.angulos.isEmpty else { throw ErrorBoost.sinAngulos }

            // FASE 2 — Un angulo por llamada separada, con combos baratos
            // distintos entre si mientras existan.
            let combos = Boost.combosDeAngulos(
                cantidad: desglose.angulos.count,
                proveedores: config.proveedores,
                fuerte: fuerte
            )
            guard !combos.isEmpty else { throw ErrorBoost.sinCombos }

            var resultados: [Boost.ResultadoAngulo] = []
            for (indice, angulo) in desglose.angulos.enumerated() {
                try Task.checkCancellation()
                guard puedeCorrerFaseBoost(id: id, tope: tope, fase: .angulo) else {
                    return
                }

                let combo = combos[indice]
                let descripcion = "Ángulo \(indice + 1): \(Self.resumenDeAngulo(angulo))"
                guard let (proveedorAngulo, claveAngulo) = proveedorConClave(combo) else {
                    // Un combo sin clave no puede tumbar la tuberia entera: se
                    // declara el angulo como no ejecutado y los demas siguen.
                    registrarFaseNoEjecutada(
                        id: id,
                        generacion: generacion,
                        descripcion: descripcion,
                        motivo: errorTarea ?? "sin clave de API"
                    )
                    continue
                }

                do {
                    let fase = try await correrFaseBoost(
                        id: id,
                        generacion: generacion,
                        fase: .angulo,
                        numeroAngulo: indice + 1,
                        descripcion: descripcion,
                        proveedor: proveedorAngulo,
                        clave: claveAngulo,
                        mensajes: Boost.mensajesAngulo(
                            problema: problema,
                            angulo: angulo,
                            indice: indice + 1,
                            total: desglose.angulos.count
                        )
                    )
                    guard generacion == generacionEjecucionTarea else { return }
                    resultados.append(
                        Boost.ResultadoAngulo(
                            indice: indice + 1,
                            proveedor: proveedorAngulo.nombre,
                            texto: fase.texto
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // `correrFaseBoost` ya dejo el paso Fallido en el libro; el
                    // resto de angulos sigue aportando contraste.
                    continue
                }
            }

            guard !resultados.isEmpty else { throw ErrorBoost.sinAngulosResueltos }

            // FASE 3 — Sintesis con el combo fuerte: cruza y descarta.
            guard puedeCorrerFaseBoost(id: id, tope: tope, fase: .sintesis) else {
                return
            }
            let sintesis = try await correrFaseBoost(
                id: id,
                generacion: generacion,
                fase: .sintesis,
                numeroAngulo: nil,
                descripcion: "Síntesis: cruzar ángulos y descartar lo no verificado",
                proveedor: fuerte,
                clave: claveFuerte,
                mensajes: Boost.mensajesSintesis(
                    problema: problema,
                    angulos: resultados
                )
            )
            guard generacion == generacionEjecucionTarea else { return }

            // La marca solo se escribe aqui: si la sintesis no corrio, la
            // respuesta no puede decir que paso por verificacion cruzada.
            modificarTarea(id: id) { tarea in
                tarea.resultado = sintesis.texto
                tarea.verificadoPorCruce = true
                tarea.estado = .completada
            }
        } catch is CancellationError {
            guard generacion == generacionEjecucionTarea else { return }
            modificarTarea(id: id) { tarea in
                tarea.estado = .detenida
            }
        } catch {
            guard generacion == generacionEjecucionTarea else { return }
            let detalle = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            finalizarTareaConError(id: id, mensaje: detalle)
        }
    }

    /// Una fase de la tuberia: abre el paso, llama sin herramientas y lo cierra
    /// con su sello de costo. Devuelve el id del paso para poder anotarlo.
    private func correrFaseBoost(
        id: UUID,
        generacion: UUID,
        fase: FaseBoost,
        numeroAngulo: Int?,
        descripcion: String,
        proveedor: ProviderConfig,
        clave: String,
        mensajes: [ChatMessage]
    ) async throws -> ResultadoFaseBoost {
        let pasoID = UUID()
        iniciarPasoDeFase(
            id: id,
            generacion: generacion,
            pasoID: pasoID,
            fase: fase,
            numeroAngulo: numeroAngulo,
            descripcion: descripcion,
            proveedor: proveedor
        )

        let motor = motorPara(proveedor: proveedor, clave: clave)
        do {
            let respuesta = try await motor.responder(
                mensajes: mensajes,
                // Sin herramientas por diseño: un angulo es analisis, no
                // ejecucion. La tuberia no puede tocar archivos, Memoria ni red.
                herramientas: [],
                alRecibirTexto: nil
            )
            try Task.checkCancellation()

            let texto = respuesta.texto
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !texto.isEmpty else {
                throw ErrorBoost.respuestaVacia(fase: fase)
            }

            registrarGasto(uso: respuesta.uso, proveedor: proveedor)
            let costo = costoDeLlamada(respuesta.uso, proveedor: proveedor)
            cerrarPasoDeFase(
                idTarea: id,
                generacion: generacion,
                pasoID: pasoID,
                estado: .terminado,
                resultado: texto,
                costo: costo
            )
            return ResultadoFaseBoost(pasoID: pasoID, texto: texto, costo: costo)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let detalle = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            cerrarPasoDeFase(
                idTarea: id,
                generacion: generacion,
                pasoID: pasoID,
                estado: .fallido,
                resultado: "Error: \(detalle)",
                costo: nil
            )
            throw error
        }
    }

    private func iniciarPasoDeFase(
        id: UUID,
        generacion: UUID,
        pasoID: UUID,
        fase: FaseBoost,
        numeroAngulo: Int?,
        descripcion: String,
        proveedor: ProviderConfig
    ) {
        guard generacion == generacionEjecucionTarea else { return }
        modificarTarea(id: id) { tarea in
            tarea.pasos.append(
                Paso(
                    id: pasoID,
                    descripcion: descripcion,
                    estado: .enCurso,
                    fase: fase,
                    numeroAngulo: numeroAngulo,
                    proveedorID: proveedor.id,
                    proveedorNombre: proveedor.nombre,
                    fechaInicio: Date()
                )
            )
        }
    }

    /// Cierra el paso y acumula su costo en el total de la tarea.
    ///
    /// El sello se escribe UNA vez, con los precios del proveedor de la fase:
    /// recalcularlo despues inventaria un gasto que no ocurrio (COST).
    private func cerrarPasoDeFase(
        idTarea: UUID,
        generacion: UUID,
        pasoID: UUID,
        estado: EstadoPaso,
        resultado: String,
        costo: Double?
    ) {
        guard generacion == generacionEjecucionTarea else { return }
        modificarTarea(id: idTarea) { tarea in
            if let indice = tarea.pasos.firstIndex(where: { $0.id == pasoID }) {
                tarea.pasos[indice].estado = estado
                tarea.pasos[indice].resultado = resultado
                tarea.pasos[indice].costoUSD = costo
                tarea.pasos[indice].fechaFin = Date()
            }
            if let costo {
                tarea.costoAcumuladoUSD =
                    (tarea.costoAcumuladoUSD ?? 0) + costo
            }
        }
    }

    /// Deja constancia en el paso de orquestacion de que el parseo fallo.
    private func anotarResultadoDePaso(
        idTarea: UUID,
        pasoID: UUID,
        generacion: UUID,
        nota: String
    ) {
        guard generacion == generacionEjecucionTarea else { return }
        modificarTarea(id: idTarea) { tarea in
            guard let indice = tarea.pasos.firstIndex(where: { $0.id == pasoID })
            else { return }
            let actual = tarea.pasos[indice].resultado ?? ""
            tarea.pasos[indice].resultado = actual + "\n\n[\(nota)]"
        }
    }

    /// Comprueba el tope ANTES de una fase y, si ya se alcanzo, la declara.
    ///
    /// El costo de una llamada no se conoce antes de hacerla: la unica frontera
    /// honesta es mirar lo ya sellado. Si la fase anterior dejo el acumulado en
    /// o por encima del tope, la siguiente no arranca y el libro lo dice.
    private func puedeCorrerFaseBoost(
        id: UUID,
        tope: Double,
        fase: FaseBoost
    ) -> Bool {
        let acumulado = tareas.first(where: { $0.id == id })?.costoAcumuladoUSD ?? 0
        guard Boost.excedeTope(acumulado: acumulado, tope: tope) else {
            return true
        }

        modificarTarea(id: id) { tarea in
            tarea.estado = .detenida
            // Sin `fase` a proposito: esta fase no corrio, no tiene combo ni
            // sello, y marcarla como fase dejaria el costo del boost en
            // "desconocido" aunque las fases reales si se midieron.
            tarea.pasos.append(
                Paso(
                    descripcion: "Boost detenido por el tope de gasto",
                    estado: .fallido,
                    resultado: """
                    El costo acumulado de la tarea (≈$\(String(format: "%.6f", acumulado))) \
                    alcanzó el tope de ≈$\(String(format: "%.6f", tope)). \
                    No se ejecutó la fase \(fase.titulo).
                    """,
                    fechaFin: Date()
                )
            )
        }
        return false
    }

    /// Un angulo que no pudo correr (sin clave) queda como paso fallido, no
    /// como fase: no se pago nada y no tiene sello.
    private func registrarFaseNoEjecutada(
        id: UUID,
        generacion: UUID,
        descripcion: String,
        motivo: String
    ) {
        guard generacion == generacionEjecucionTarea else { return }
        modificarTarea(id: id) { tarea in
            tarea.pasos.append(
                Paso(
                    descripcion: descripcion,
                    estado: .fallido,
                    resultado: "No se ejecutó: \(motivo)",
                    fechaFin: Date()
                )
            )
        }
    }

    private func costoDeLlamada(
        _ uso: UsoTokens?,
        proveedor: ProviderConfig
    ) -> Double? {
        guard let uso else { return nil }
        var mensaje = ChatMessage(
            rol: .asistente,
            texto: "",
            tokensEntrada: uso.entrada,
            tokensSalida: uso.salida
        )
        SellosDeCosto.sellar(&mensaje, proveedor: proveedor)
        return mensaje.costoSelladoUSD
    }

    /// Proveedor y clave para UNA fase, con la misma validacion que la tarea.
    ///
    /// Existe aparte porque /boost usa varios proveedores en la misma corrida y
    /// `proveedorYClaveParaTarea` resuelve uno solo.
    private func proveedorConClave(
        _ proveedor: ProviderConfig
    ) -> (ProviderConfig, String)? {
        if estadoDePrueba != nil {
            return (proveedor, "")
        }

        do {
            try proveedor.validar()
        } catch {
            errorTarea = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return nil
        }

        guard let clave = clave(para: proveedor),
              !clave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            errorTarea = "Falta la clave de API de \(proveedor.nombre)."
            return nil
        }
        return (proveedor, clave)
    }

    private static func resumenDeAngulo(
        _ texto: String,
        limite: Int = 60
    ) -> String {
        let limpio = texto
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.count <= limite { return limpio }
        return String(limpio.prefix(limite)) + "…"
    }

    /// Herramientas que existen DENTRO de una tarea, nunca en Chat.
    ///
    /// `traer_url` es la de fetch HTTP que ya traia la app. `proponer_memoria`
    /// es la unica via de escritura en Memoria dentro de Tarea (HP1). Las MCP
    /// solo aparecen si hay servidor configurado en Conexiones.
    private func herramientasDeTarea() async -> (
        herramientas: [Herramienta],
        mcp: Set<String>
    ) {
        var herramientas: [Herramienta] = [
            HttpFetchTool(transporte: transporte),
            HerramientaProponerMemoria { [weak self] accion in
                guard let self else {
                    return .rechazada("la Memoria no está disponible en esta tarea.")
                }
                return await self.aplicarAccionDeMemoriaTarea(accion)
            }
        ]
        var nombresMCP: Set<String> = []

        guard config.servidor.estaConfigurado else {
            return (herramientas, nombresMCP)
        }

        do {
            let cliente = try MCPClient(
                transporte: transporte,
                config: config.servidor,
                token: tokenServidor
            )
            _ = try await cliente.inicializar()
            let definiciones = try await cliente.listarHerramientas()
            let prefijo = HerramientaMCP.prefijo(servidor: config.servidor.nombre)
            for definicion in definiciones {
                let remota = HerramientaMCP(
                    cliente: cliente,
                    definicion: definicion,
                    prefijo: prefijo
                )
                nombresMCP.insert(remota.definicion.nombre)
                herramientas.append(remota)
            }
        } catch {
            // Un servidor caido no puede dejar la tarea sin sus herramientas
            // locales: se avisa y se sigue con lo que hay.
            let detalle = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorTarea = "No se pudieron cargar las herramientas MCP: \(detalle)"
        }

        return (herramientas, nombresMCP)
    }

    /// Historial de ejecucion. En una reanudacion reinyecta los pasos resueltos
    /// como llamadas y resultados reales, para no repetirlos.
    private func historialDeTarea(_ tarea: Tarea) -> [ChatMessage] {
        var mensajes = [
            ChatMessage(rol: .sistema, texto: Tarea.instruccionesEjecucion),
            ChatMessage(rol: .usuario, texto: Tarea.mensajeDeEjecucion(tarea))
        ]

        let resueltos = tarea.pasos.compactMap { paso -> (Paso, ToolCall)? in
            guard paso.estado.estaResuelto,
                  let herramienta = paso.herramienta,
                  let llamadaID = paso.llamadaID
            else {
                return nil
            }
            return (
                paso,
                ToolCall(
                    id: llamadaID,
                    nombre: herramienta,
                    argumentos: paso.argumentos ?? "{}"
                )
            )
        }

        guard !resueltos.isEmpty else { return mensajes }

        mensajes.append(
            ChatMessage(
                rol: .sistema,
                texto: "Libro previo: estos pasos ya están resueltos. No los repitas; continúa desde aquí."
            )
        )
        for (paso, llamada) in resueltos {
            mensajes.append(
                ChatMessage(rol: .asistente, texto: "", toolCalls: [llamada])
            )
            mensajes.append(
                ChatMessage(
                    rol: .herramienta,
                    texto: paso.resultado ?? "",
                    toolCallId: llamada.id
                )
            )
        }
        return mensajes
    }

    /// Crea el paso Pendiente y abre la hoja ANTES de ejecutar nada.
    private func pedirAprobacion(
        _ llamada: ToolCall,
        idTarea: UUID,
        generacion: UUID
    ) async -> Bool {
        guard generacion == generacionEjecucionTarea else { return false }

        crearOActualizarPaso(
            llamada,
            idTarea: idTarea,
            generacion: generacion,
            estado: .pendiente,
            aprobacion: .pendiente,
            descripcion: descripcionDeLlamada(llamada)
        )

        guard generacion == generacionEjecucionTarea else { return false }

        let solicitud = SolicitudAprobacion(
            tareaID: idTarea,
            herramienta: llamada.nombre,
            descripcion: descripcionDeLlamada(llamada),
            detalle: llamada.argumentos
        )
        idSolicitudAprobacion = solicitud.id
        solicitudAprobacion = solicitud

        let aprobada = await withCheckedContinuation {
            (continuacion: CheckedContinuation<Bool, Never>) in
            self.continuacionAprobacion = continuacion
        }

        if idSolicitudAprobacion == solicitud.id {
            idSolicitudAprobacion = nil
            solicitudAprobacion = nil
        }
        return aprobada
    }

    private func pasoIniciado(
        _ llamada: ToolCall,
        idTarea: UUID,
        generacion: UUID
    ) async {
        crearOActualizarPaso(
            llamada,
            idTarea: idTarea,
            generacion: generacion,
            estado: .enCurso,
            fechaInicio: Date()
        )
    }

    private func pasoTerminado(
        _ llamada: ToolCall,
        resultado: String,
        idTarea: UUID,
        generacion: UUID
    ) async {
        let fallo = resultado.hasPrefix("Error")
        crearOActualizarPaso(
            llamada,
            idTarea: idTarea,
            generacion: generacion,
            estado: fallo ? .fallido : .terminado,
            resultado: resultado,
            fechaFin: Date()
        )
    }

    private func pasoDenegado(
        _ llamada: ToolCall,
        motivo: String,
        idTarea: UUID,
        generacion: UUID
    ) async {
        crearOActualizarPaso(
            llamada,
            idTarea: idTarea,
            generacion: generacion,
            estado: .denegado,
            aprobacion: .denegada,
            resultado: motivo,
            fechaFin: Date()
        )
    }

    /// COST dentro de la tarea: cada llamada al modelo se sella y se acumula.
    private func registrarUsoDeTarea(
        _ uso: UsoTokens,
        idTarea: UUID,
        proveedor: ProviderConfig,
        generacion: UUID
    ) async {
        guard generacion == generacionEjecucionTarea else { return }

        registrarGasto(uso: uso, proveedor: proveedor)

        // Se usa el mismo sello inmutable que los mensajes del chat: si el
        // proveedor no tiene precios, el costo queda desconocido (nil) en vez
        // de inventarse.
        guard let costo = costoDeLlamada(uso, proveedor: proveedor) else { return }

        modificarTarea(id: idTarea) { tarea in
            tarea.costoAcumuladoUSD = (tarea.costoAcumuladoUSD ?? 0) + costo
        }
    }

    /// Aplica una accion de `proponer_memoria` YA aprobada en la hoja (TASK.4).
    ///
    /// B2.4: el regimen no cambia —toda escritura de Tarea sigue pasando por
    /// propuesta y hoja—, pero la accion aprobada se expresa sobre el esquema
    /// tipado y entra por `aplicarTipada`, el mismo camino que Chat. El mapeo
    /// vive en `Memoria.operacionTipada`: `guardar` -> `save_memory`
    /// (categoria `durable_fact`), `actualizar` -> `update_memory` conservando
    /// la categoria base, `borrar` -> `delete_memory`. Una entrada sensible no
    /// se reescribe por esta via: `aplicarTipada` la rechaza.
    private func aplicarAccionDeMemoriaTarea(
        _ accion: AccionMemoria
    ) -> ResultadoAccionMemoria {
        var entradas = config.memoria
        let operacion = Memoria.operacionTipada(accion, en: entradas)
        let resultado = Memoria.aplicarTipada(operacion, en: &entradas)
        if case .aplicada = resultado {
            config.memoria = entradas
        }
        return resultado
    }

    private func crearOActualizarPaso(
        _ llamada: ToolCall,
        idTarea: UUID,
        generacion: UUID,
        estado: EstadoPaso,
        aprobacion: EstadoAprobacion? = nil,
        resultado: String? = nil,
        descripcion: String? = nil,
        fechaInicio: Date? = nil,
        fechaFin: Date? = nil
    ) {
        guard generacion == generacionEjecucionTarea else { return }

        modificarTarea(id: idTarea) { tarea in
            if let indice = tarea.pasos.firstIndex(where: {
                $0.llamadaID == llamada.id
            }) {
                var paso = tarea.pasos[indice]
                paso.estado = estado
                if let aprobacion {
                    paso.aprobacion = aprobacion
                } else if paso.aprobacion == .pendiente {
                    // Llego a ejecutarse: la hoja se aprobo.
                    paso.aprobacion = .aprobada
                }
                if let resultado { paso.resultado = resultado }
                if let descripcion { paso.descripcion = descripcion }
                if let fechaInicio { paso.fechaInicio = fechaInicio }
                if let fechaFin { paso.fechaFin = fechaFin }
                if paso.herramienta == nil { paso.herramienta = llamada.nombre }
                if paso.argumentos == nil { paso.argumentos = llamada.argumentos }
                if paso.url == nil { paso.url = urlDeLlamada(llamada) }
                tarea.pasos[indice] = paso
            } else {
                tarea.pasos.append(
                    Paso(
                        descripcion: descripcion ?? descripcionDeLlamada(llamada),
                        estado: estado,
                        herramienta: llamada.nombre,
                        argumentos: llamada.argumentos,
                        resultado: resultado,
                        llamadaID: llamada.id,
                        url: urlDeLlamada(llamada),
                        aprobacion: aprobacion,
                        fechaInicio: fechaInicio,
                        fechaFin: fechaFin
                    )
                )
            }
        }
    }

    private func descripcionDeLlamada(_ llamada: ToolCall) -> String {
        if llamada.nombre == Memoria.nombreHerramientaTarea,
           let accion = try? Memoria.accion(desdeArgumentos: llamada.argumentos) {
            switch accion {
            case .guardar(let texto):
                return "Guardar en Memoria: \(texto)"
            case .actualizar(let id, let texto):
                return "Actualizar en Memoria \(id.uuidString): \(texto)"
            case .borrar(let id):
                return "Borrar de Memoria \(id.uuidString)"
            }
        }

        if llamada.nombre == "traer_url", let url = urlDeLlamada(llamada) {
            return "Traer \(url)"
        }
        return llamada.nombre
    }

    private func urlDeLlamada(_ llamada: ToolCall) -> String? {
        guard llamada.nombre == "traer_url",
              let argumentos = try? Argumentos.diccionario(llamada.argumentos)
        else {
            return nil
        }
        return Argumentos.texto(argumentos, clave: "url")
    }

    private func modificarTarea(id: UUID, _ cambio: (inout Tarea) -> Void) {
        guard let indice = tareas.firstIndex(where: { $0.id == id }) else { return }
        var tarea = tareas[indice]
        cambio(&tarea)
        tarea.fechaActualizacion = Date()
        guardarTarea(tarea)
    }

    private func finalizarTareaConError(id: UUID, mensaje: String) {
        modificarTarea(id: id) { tarea in
            tarea.estado = .fallida
            tarea.ultimoError = mensaje
            tarea.pasos.append(
                Paso(
                    descripcion: "Error: \(mensaje)",
                    estado: .fallido,
                    resultado: mensaje,
                    fechaFin: Date()
                )
            )
        }
        errorTarea = mensaje
    }

    /// Guarda una tarea en el almacen y refresca la lista.
    ///
    /// En modo capturas no hay almacen: la lista en memoria tambien refleja el
    /// cambio para que la pantalla no ensene una fila fantasma.
    private func guardarTarea(_ tarea: Tarea) {
        if let storeTareas {
            do {
                try storeTareas.guardar(tarea)
            } catch {
                errorTarea = "No se pudo guardar la tarea."
            }
            recargarTareas()
        } else if let indice = tareas.firstIndex(where: { $0.id == tarea.id }) {
            tareas[indice] = tarea
        } else {
            tareas.append(tarea)
        }
    }

    /// Proveedor y clave de una tarea, o nil si falta configuracion.
    ///
    /// El proveedor anotado en la tarea manda; si ya no existe, se cae al
    /// activo. La clave se lee del llavero por la misma ruta que el chat.
    private func proveedorYClaveParaTarea(
        _ tarea: Tarea
    ) -> (ProviderConfig, String)? {
        let proveedor = tarea.proveedorID.flatMap { id in
            config.proveedores.first { $0.id == id }
        } ?? config.proveedorSeleccionado

        guard let proveedor else {
            errorTarea = "No hay ningún proveedor configurado."
            return nil
        }

        if estadoDePrueba != nil {
            return (proveedor, "")
        }

        do {
            try proveedor.validar()
        } catch {
            errorTarea = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return nil
        }

        guard let clave = clave(para: proveedor),
              !clave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            errorTarea = "Falta la clave de API de \(proveedor.nombre)."
            return nil
        }
        return (proveedor, clave)
    }

    // MARK: - Envio

    /// Ruta unica de la caja: analiza el borrador y despacha comandos, skills
    /// o el mensaje normal (§4.2).
    ///
    /// ChatView ya no llama a `enviar()` directamente. Los comandos locales
    /// limpian el borrador; un token desconocido o una skill sin mensaje lo
    /// dejan intacto y publican `avisoComando`.
    func enviarTextoActual() {
        guard !enviando, !compactando, !generandoPlanChat else { return }

        let texto = borrador
        guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        avisoComando = nil

        switch AnalizadorComandos.analizar(texto, resolvedor: resolvedorSkills) {
        case .mensajeNormal(let limpio):
            borrador = limpio
            enviar(limpio)
            borrador = ""

        case .comando(let comando):
            borrador = ""
            ejecutar(comando)

        case .comandoConTexto(let comando, let descartado):
            // D1=A: el primer token manda. El comando se ejecuta y el resto se
            // descarta, pero el dueno tiene que verlo en el hilo: se registra un
            // evento visual despues de ejecutar (un comando como /nuevo limpia
            // los eventos y el aviso tiene que sobrevivir en el chat nuevo).
            borrador = ""
            ejecutar(comando)
            avisarTextoDescartado(descartado, para: comando)

        case .conSkills(let skills, let mensaje):
            borrador = mensaje
            enviar(mensaje, skills: skills)
            borrador = ""

        case .tokensDesconocidos(let slugs):
            let lista = slugs.map { "/\($0)" }.joined(separator: ", ")
            avisoComando = "No reconozco: \(lista). Revisa el comando o quítalo para enviar como mensaje normal."

        case .skillSinMensaje(let skill):
            avisoComando = "La skill \(skill.nombre) necesita un mensaje detrás."
        }
    }

    /// Skills que encajan con lo tecleado en el selector flotante.
    ///
    /// El parser y esta ruta comparten el mismo puerto: la Fase 4 solo cambia
    /// la fuente de datos, no la gramatica.
    func skillsParaSelector(_ consulta: String) -> [SkillResuelta] {
        let buscado = AnalizadorComandos.normalizarSlug(consulta)
        let todas = resolvedorSkills.todas()
        guard !buscado.isEmpty else { return todas }

        return todas.filter { skill in
            let slug = AnalizadorComandos.normalizarSlug(skill.slug)
            let nombre = AnalizadorComandos.normalizarSlug(skill.nombre)
            return slug.hasPrefix(buscado) || nombre.contains(buscado)
        }
    }

    /// Ejecuta un comando integrado sin enviar nada al modelo.
    private func ejecutar(_ comando: ComandoIntegrado) {
        switch comando {
        case .costo:
            registrarEventoVisual(
                textoDeCosto(),
                tras: conversacion.mensajes.last?.id
            )

        case .modelos:
            mostrarHojaModelos = true

        case .nuevo:
            nuevaConversacion()
            // La raiz observa este id y empuja la conversacion recien creada.
            idParaAbrir = conversacion.id

        case .exportar:
            textoParaCompartirSolicitado = exportarConversacion()

        case .compact:
            compactar()

        case .plan:
            generarPlanDeChat()

        case .boost:
            // /boost no ejecuta nada en un chat: su tuberia vive DENTRO de una
            // Tarea. Se avisa donde se usa en vez de fingir una accion.
            avisoComando = "El boost se activa en una Tarea: escribe /boost seguido del encargo."
        }
    }

    /// Deja constancia en el hilo de que un comando descarto el texto que le
    /// seguia (D1=A).
    ///
    /// POR QUE un evento visual y no `avisoComando`: el requisito firmado pide
    /// que el aviso quede VISIBLE EN EL HILO y no solo pegado a la caja. Ademas
    /// los eventos no son mensajes: jamas viajan al modelo ni se persisten.
    private func avisarTextoDescartado(
        _ descartado: String,
        para comando: ComandoIntegrado
    ) {
        registrarEventoVisual(
            "El resto del texto no se envió: /\(comando.rawValue) se ejecutó solo. "
                + "Se descartó: «\(descartado)».",
            tras: conversacion.mensajes.last?.id
        )
    }

    /// /plan dentro de un chat: mismo mecanismo que la tarea, sin ejecutar.
    ///
    /// Usa el ultimo mensaje del usuario como instruccion, llama al motor con
    /// `herramientas: []` y deja la respuesta como mensaje de plan en el hilo.
    /// No crea una Tarea ni toca el libro: el plan es solo texto visible.
    private func generarPlanDeChat() {
        guard !generandoPlanChat, !enviando, !compactando else { return }

        guard let instruccion = conversacion.mensajes
            .last(where: { $0.rol == .usuario })?
            .texto
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !instruccion.isEmpty
        else {
            avisoComando = "Escribe primero el encargo del que quieres el plan."
            return
        }

        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }

        let idConversacion = conversacion.id
        generandoPlanChat = true
        error = nil

        tareaPlanChat = Task { [weak self] in
            guard let self else { return }
            defer {
                self.generandoPlanChat = false
                self.tareaPlanChat = nil
            }

            do {
                let motor = self.motorPara(proveedor: proveedor, clave: clave)
                let respuesta = try await motor.responder(
                    mensajes: PlanTarea.mensajesParaSolicitar(instruccion: instruccion),
                    // Solo texto: /plan no ofrece herramientas ni las ejecuta.
                    herramientas: [],
                    alRecibirTexto: nil
                )
                try Task.checkCancellation()

                let plan = PlanTarea.desde(
                    texto: respuesta.texto,
                    proveedorID: proveedor.id
                )
                guard !plan.pasos.isEmpty else {
                    self.error = "No se pudo generar el plan: el modelo devolvió un plan vacío."
                    return
                }

                self.registrarGasto(uso: respuesta.uso, proveedor: proveedor)

                // Si el dueno cambio de chat mientras se generaba, el plan no
                // se publica en otro hilo.
                guard self.conversacion.id == idConversacion else { return }

                var mensaje = ChatMessage(rol: .asistente, texto: plan.textoParaChat)
                mensaje.proveedorID = proveedor.id
                mensaje.tokensEntrada = respuesta.uso?.entrada
                mensaje.tokensSalida = respuesta.uso?.salida
                SellosDeCosto.sellar(&mensaje, proveedor: proveedor)
                self.conversacion.mensajes.append(mensaje)
                self.persistirActual()
            } catch is CancellationError {
                // Cambiar de conversacion cancela el plan sin dejar error.
            } catch {
                let detalle = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.error = "No se pudo generar el plan: \(detalle)"
            }
        }
    }

    /// Texto de /costo con el consumo real y el tope vigente (§2.4).
    ///
    /// Si no hay precios configurados no se inventa un costo; si el tope es 0
    /// (aviso desactivado) se omite la frase del tope.
    private func textoDeCosto() -> String {
        let proveedor = proveedorDelChat
        let usoReal = usoAcumuladoDelChat
        let uso = usoReal ?? UsoTokens()

        let modelo: String
        if let proveedor {
            let limpio = NombresLimpios.modelo(proveedor.modelo)
            modelo = limpio.isEmpty
                ? NombresLimpios.proveedor(
                    nombre: proveedor.nombre,
                    baseURL: proveedor.baseURL
                )
                : limpio
        } else {
            modelo = "Sin modelo"
        }

        var texto = "En este chat van \(Self.tokensTexto(uso.total)) tokens "
            + "(\(Self.tokensTexto(uso.entrada)) de entrada + "
            + "\(Self.tokensTexto(uso.salida)) de salida)"

        if usoReal != nil, let costo = costoAcumuladoDelChat {
            // Mismo formato que el pie y el subtitulo de la pildora.
            texto += " · ≈ $\(String(format: "%.4f", costo)) con \(modelo)"
            if hayCostosEstimados {
                // COST.3: los legados se sellaron al cargar con los precios de
                // hoy de su proveedor, no con lo que se pago entonces.
                texto += " (incluye estimaciones de legado)"
            }
        } else {
            texto += " con \(modelo)"
        }

        let tope = config.topeAvisoCostoEfectivo
        if tope > 0 {
            texto += ". El tope de aviso está en $\(String(format: "%.2f", tope))."
        } else {
            texto += "."
        }
        return texto
    }

    /// Compacta el historial conservando los ultimos 6 mensajes (§4.2).
    ///
    /// Hace UNA sola llamada de resumen sobre los mensajes antiguos (todo menos
    /// los ultimos 6). La conversacion solo se toca cuando el resumen reduce de
    /// verdad el contexto: si la llamada falla o el resumen no comprime, el
    /// hilo queda intacto y se avisa sin guardar nada.
    func compactar() {
        guard !compactando, !enviando else { return }
        // B2.2: compactar guarda el resumen por conversacion y persiste el
        // hilo. En un hilo temporal eso seria un rastro, asi que no se ofrece
        // (el menu ••• lo oculta) y, si se pide por comando, se avisa en vez
        // de quedarse en silencio.
        guard conversacion.sePersiste else {
            avisoComando = "El chat temporal no se guarda: no hay nada que compactar."
            return
        }

        let total = conversacion.mensajes.count
        // Con 6 mensajes o menos no queda prefijo antiguo que resumir: llamar
        // al modelo con cero mensajes gastaria una peticion inutil.
        guard total > Compactador.minimoParaResumir else {
            avisoComando = "Todavía no hace falta compactar: la conversación es corta."
            return
        }

        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }

        let idConversacion = conversacion.id
        let mensajes = conversacion.mensajes

        avisoComando = nil
        error = nil
        compactando = true
        let generacion = UUID()
        generacionCompactado = generacion

        tareaCompactado = Task { [weak self] in
            guard let self else { return }

            defer {
                // Solo la compactacion vigente reabre la caja.
                if self.generacionCompactado == generacion {
                    self.compactando = false
                    self.tareaCompactado = nil
                }
            }

            do {
                let motor = self.motorPara(proveedor: proveedor, clave: clave)
                var usoResumen: UsoTokens?

                let resultado = try await Compactador.compactar(
                    mensajes: mensajes
                ) { texto in
                    // Sin herramientas y sin streaming: es una llamada de
                    // resumen, no un turno de conversacion. El texto ya trae
                    // solo el prefijo antiguo con sus roles; las instrucciones
                    // van como sistema.
                    let peticion = [
                        ChatMessage(rol: .sistema, texto: Self.instruccionesCompactar),
                        ChatMessage(rol: .usuario, texto: texto)
                    ]
                    let respuesta = try await motor.responder(
                        mensajes: peticion,
                        herramientas: [],
                        alRecibirTexto: nil
                    )
                    try Task.checkCancellation()

                    // La llamada de resumen consume y cuenta para el acumulador
                    // global aunque la guarda de no-reduccion la descarte.
                    self.registrarGasto(uso: respuesta.uso, proveedor: proveedor)
                    usoResumen = respuesta.uso
                    return respuesta.texto
                }
                try Task.checkCancellation()

                guard self.conversacion.id == idConversacion,
                      self.generacionCompactado == generacion
                else {
                    return
                }

                guard resultado.aplicada, let resumen = resultado.resumen else {
                    // Un resumen generado pero no aplicado es el caso de la
                    // guarda: el hilo queda como estaba y se avisa. Si no hay
                    // texto generado, el modelo devolvio un resumen vacio.
                    if resultado.resumenGenerado != nil {
                        self.avisoComando = "El resumen no reducía el contexto: "
                            + "se conservaron los mensajes."
                    } else {
                        self.error = "No se pudo compactar: el modelo devolvió un resumen vacío."
                    }
                    return
                }

                let resumidos = mensajes.count - resultado.mensajes.count
                let mensajesResumidos = Array(mensajes.prefix(resumidos))
                // La factura conserva el consumo de los mensajes que salen y
                // tambien el de la unica llamada de resumen.
                var usoHistorico = UsoResumido()
                var costoHistorico: Double? = 0
                var esEstimacion = false
                for mensaje in mensajesResumidos {
                    guard let uso = mensaje.uso else { continue }
                    // El mensaje conserva el proveedor que lo genero; los
                    // viejos sin anotacion caen al proveedor del chat.
                    let id = mensaje.proveedorID
                        ?? self.conversacion.proveedorID
                    usoHistorico.sumar(uso, proveedorID: id)
                    if mensaje.costoEsEstimacion {
                        esEstimacion = true
                    }
                    // HP4: el balde absorbe el sello del mensaje. Un legado sin
                    // sello aporta su valoracion por proveedor, igual que el
                    // lector del acumulado.
                    costoHistorico = CostoEstimado.sumar(
                        costoHistorico,
                        CostoEstimado.costoSellado(
                            de: mensaje,
                            proveedores: self.config.proveedores,
                            proveedorDelChat: self.conversacion.proveedorID
                        )
                    )
                }
                if let usoResumen {
                    usoHistorico.sumar(usoResumen, proveedorID: proveedor.id)
                    // La llamada de resumen se sella a los precios del
                    // proveedor que la hizo en este momento.
                    costoHistorico = CostoEstimado.sumar(
                        costoHistorico,
                        CostoEstimado.costo(
                            uso: usoResumen,
                            precioEntrada: proveedor.precioEntradaPorMillon,
                            precioSalida: proveedor.precioSalidaPorMillon
                        )
                    )
                }
                usoHistorico.costoSelladoUSD = costoHistorico
                usoHistorico.costoEsEstimacion = esEstimacion

                if usoHistorico.total.total > 0 {
                    let claveBalde = idConversacion.uuidString
                    var fusionado = self.usoResumidoPorConversacion[claveBalde]
                        ?? UsoResumido()
                    // Un balde legado sin sello se valora ahora por proveedor
                    // para que la suma no pierda lo ya compactado; un balde
                    // vacio vale cero, no "desconocido". Esa valoracion usa
                    // los precios de hoy, asi que se marca como estimacion.
                    if fusionado.costoSelladoUSD == nil {
                        if fusionado.porProveedor.isEmpty {
                            fusionado.costoSelladoUSD = 0
                        } else {
                            fusionado.costoSelladoUSD = self.costoDeResumido(
                                fusionado,
                                proveedorDelChat: self.conversacion.proveedorID
                            )
                            fusionado.costoEsEstimacion = true
                        }
                    }
                    fusionado.fusionar(usoHistorico)
                    self.usoResumidoPorConversacion[claveBalde] = fusionado
                }

                let idsResumidos = Set(mensajesResumidos.map(\.id))
                self.conversacion.mensajes = resultado.mensajes
                self.conversacion.resumenCompactado = resumen
                self.conversacion.usoTrasCompactar = usoResumen
                self.actualizarResumenCompactado(resumen, para: idConversacion)

                // Los divisores anclados a mensajes que se van ya no tienen
                // sentido; el divisor de compactacion se pinta al principio.
                self.eventosVisuales.removeAll { evento in
                    guard let ancla = evento.trasMensaje else { return false }
                    return idsResumidos.contains(ancla)
                }
                self.registrarEventoVisual(
                    "── Conversación compactada: se resumieron \(resumidos) mensajes ──",
                    tras: nil
                )

                self.persistirActual()
            } catch is CancellationError {
                // Cambiar de chat o pulsar Detener no toca la conversacion.
            } catch {
                guard !Task.isCancelled,
                      self.conversacion.id == idConversacion,
                      self.generacionCompactado == generacion
                else {
                    return
                }
                let detalle = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.error = "No se pudo compactar: \(detalle)"
            }
        }
    }

    /// Guarda o borra el respaldo del ultimo resumen de /compact (COMP.2).
    private func actualizarResumenCompactado(_ resumen: String?, para id: UUID) {
        let clave = id.uuidString
        let limpio = (resumen ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty {
            resumenesCompactadosPorConversacion.removeValue(forKey: clave)
        } else {
            resumenesCompactadosPorConversacion[clave] = limpio
        }
    }

    /// Manda el mensaje y va pintando la respuesta segun llega.
    func enviar(_ texto: String) {
        enviar(texto, skills: [])
    }

    /// Envio con las skills resueltas de este turno.
    ///
    /// Los nombres visibles se guardan en el mensaje del usuario; las
    /// instrucciones solo viajan en el payload de ESTE turno, insertadas por
    /// `Historial.insertarInstrucciones` antes de llamar al motor.
    private func enviar(_ texto: String, skills: [SkillResuelta]) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, !enviando else { return }

        // Un mensaje nuevo retira la burbuja de error del turno anterior.
        limpiarErrorDeTurno()

        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }

        // El chat conserva el proveedor con el que se habla: la fila del
        // historial saca de ahi su ultimo modelo y sus precios.
        adoptarProveedorDelChat(proveedor)

        // La etiqueta ⚡ y las instrucciones viajan juntas: una skill sin
        // instrucciones no se pinta como aplicada ni se inyecta.
        let aplicables = skills.filter { skill in
            !skill.instrucciones
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        var mensaje = ChatMessage(rol: .usuario, texto: limpio)
        mensaje.skillsAplicadas = aplicables.map(\.nombre)
        conversacion.mensajes.append(mensaje)
        if conversacion.titulo == "Conversacion" {
            conversacion.titulo = conversacion.tituloSugerido
        }
        persistirActual()

        lanzarTurno(
            tipo: .envio,
            proveedor: proveedor,
            clave: clave,
            instrucciones: aplicables.map(\.instrucciones),
            alFracasar: {}
        )
    }

    /// True si esa respuesta es la UNICA que puede regenerarse (D2=B).
    ///
    /// La regla vive en el estado y no en la vista para poder probarla sin
    /// SwiftUI: el pie solo ofrece ↻ bajo la ultima respuesta del asistente; en
    /// las anteriores no hay ↻ y queda Ramificar, que ya existia.
    func puedeRegenerar(_ mensaje: ChatMessage) -> Bool {
        !enviando
            && mensaje.rol == .asistente
            && mensaje.uso != nil
            && conversacion.idUltimaRespuestaAsistente == mensaje.id
    }

    /// Descarta la ultima respuesta y la vuelve a generar con el proveedor y el
    /// modelo seleccionados ahora mismo.
    ///
    /// Si el turno nuevo falla, el anterior vuelve tal cual: un reintento malo
    /// no puede costar una respuesta buena.
    func regenerar() {
        guard !enviando else { return }
        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }
        regenerar(con: proveedor, clave: clave)
    }

    /// Regenera la ultima respuesta con otro proveedor configurado.
    ///
    /// El combo elegido se usa SOLO para construir el motor de esta
    /// regeneracion: no se asigna `config.proveedorActivo` ni se llama a
    /// `cambiarProveedor`, asi que el proveedor global y su divisor visual
    /// quedan como estaban. El mensaje nuevo si conserva ese proveedor para
    /// que su costo futuro sea honesto.
    func regenerarCon(proveedorID: UUID) {
        guard !enviando else { return }
        guard let proveedor = config.proveedores.first(where: { $0.id == proveedorID }),
              let (elegido, clave) = proveedorYClave(para: proveedor)
        else {
            return
        }
        regenerar(con: elegido, clave: clave)
    }

    /// Ruta comun de regeneracion con un proveedor y su clave ya resueltos.
    private func regenerar(con proveedor: ProviderConfig, clave: String) {
        guard !enviando else { return }
        // D2=B: solo hay regeneracion si existe una respuesta del asistente que
        // descartar; `descartarUltimoTurno` decide el corte exacto.
        guard conversacion.idUltimaRespuestaAsistente != nil else { return }

        adoptarProveedorDelChat(proveedor)

        let turnoDescartado = conversacion.descartarUltimoTurno()
        guard !turnoDescartado.isEmpty else { return }
        reanclarEventosDelTurnoDescartado(turnoDescartado)
        persistirActual()

        limpiarErrorDeTurno()
        lanzarTurno(
            tipo: .regeneracion,
            proveedor: proveedor,
            clave: clave,
            alFracasar: { [weak self] in
                self?.conversacion.mensajes.append(contentsOf: turnoDescartado)
            }
        )
    }

    /// Reintenta el ultimo turno fallido sin perder el texto del usuario.
    ///
    /// Un envio fallido se relanza sobre el historial actual (el mensaje del
    /// usuario ya esta dentro). Una regeneracion fallida se vuelve a regenerar
    /// sobre el turno anterior restaurado. Tras cambiar de modelo desde la
    /// burbuja de error, este reintento usa ya el proveedor nuevo.
    func reintentar() {
        guard errorDeTurno != nil, !enviando else { return }

        // Tras reiniciar la app el tipo de turno fallido no viaja en el archivo
        // (es estado vivo), asi que se infiere del hilo: si la ultima es del
        // asistente, el turno era una regeneracion con su respuesta vieja
        // restaurada; si la ultima es del usuario, era un envio. En los dos
        // casos el mensaje del usuario ya esta y no se vuelve a escribir.
        let tipo = turnoFallido
            ?? (conversacion.mensajes.last?.rol == .asistente ? .regeneracion : .envio)
        limpiarErrorDeTurno()

        switch tipo {
        case .regeneracion:
            regenerar()
        case .envio:
            reintentarEnvio()
        }
    }

    private func reintentarEnvio() {
        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }
        lanzarTurno(
            tipo: .envio,
            proveedor: proveedor,
            clave: clave,
            alFracasar: {}
        )
    }

    /// Arranca un turno con el historial ya preparado.
    ///
    /// La usan enviar, regenerar y los reintentos para no repetir la puesta a
    /// punto de la tarea ni el manejo de `enviando`.
    private func lanzarTurno(
        tipo: TipoTurnoFallido,
        proveedor: ProviderConfig,
        clave: String,
        instrucciones: [String] = [],
        alFracasar: @escaping () -> Void
    ) {
        // Cubre tambien los reintentos: el proveedor del chat es el que se
        // esta usando ahora, no el activo global de otro momento.
        adoptarProveedorDelChat(proveedor)

        enviando = true
        textoEnCurso = ""
        error = nil

        var historial = historialParaEnviar()
        if !instrucciones.isEmpty {
            historial = Historial.insertarInstrucciones(
                historial,
                instrucciones: instrucciones
            )
        }
        // La misma foto manda en el historial y en las herramientas: si el chat
        // usa Memoria, el payload lleva bloque y herramientas tipadas; si no, ni
        // uno ni otro. Se captura antes de lanzar la tarea para que un cambio de
        // chat a mitad de turno no mezcle dos contextos.
        //
        // B2.2: la regla es `usaMemoriaEnPayload`, no `sinMemoria`. Asi un hilo
        // temporal no ofrece NUNCA herramientas de escritura ni inyecta
        // entradas, aunque su bandera de «sin memoria» no este puesta.
        let usaMemoria = conversacion.usaMemoriaEnPayload
        let idConversacion = conversacion.id
        tareaActual = Task { [weak self] in
            guard let self else { return }

            await self.ejecutarTurno(
                proveedor: proveedor,
                clave: clave,
                historial: historial,
                usaMemoria: usaMemoria,
                idConversacion: idConversacion,
                tipo: tipo,
                alFracasar: alFracasar
            )

            self.enviando = false
            self.tareaActual = nil
        }
    }

    /// Corre un turno con el historial ya preparado y deja el resultado en la
    /// conversacion.
    ///
    /// Es la maquinaria que comparten enviar y regenerar. Si el turno falla,
    /// `alFracasar` deshace lo que haya hecho quien llama antes de publicar el
    /// error en linea (`errorDeTurno`), nunca en el aviso generico.
    private func ejecutarTurno(
        proveedor: ProviderConfig,
        clave: String,
        historial: [ChatMessage],
        usaMemoria: Bool,
        idConversacion: UUID,
        tipo: TipoTurnoFallido,
        alFracasar: () -> Void
    ) async {
        do {
            let motor = motorPara(proveedor: proveedor, clave: clave)
            // Un chat normal sigue SIN las herramientas del modo Tarea. La unica
            // excepcion es la Memoria: si el chat la usa, se ofrecen las cuatro
            // herramientas tipadas de escritura y un ejecutor NUEVO por turno.
            // B2.4: `propose_sensitive_memory` ya se ofrece porque su hoja de
            // aprobacion esta cableada en este mismo turno; ofrecerla sin hoja
            // habria sido forma sin fondo.
            //
            // B2.3: este conjunto NO depende del interruptor «Memoria
            // inteligente». ON y OFF ofrecen exactamente las mismas
            // herramientas tipadas con el mismo ejecutor; lo unico que cambia
            // entre ramas es la instruccion de disparo del bloque de sistema
            // (ver `historialParaEnviar`).
            //
            // B2.2: en un hilo temporal `usaMemoria` es false por construccion
            // (`Conversation.usaMemoriaEnPayload`), asi que el array `tools` de
            // la peticion sale vacio y el cliente ni siquiera manda la clave.
            var herramientas: [Herramienta] = []
            if usaMemoria {
                // El snapshot de entradas se toma al inicio del turno: los
                // `entry_id` de actualizacion y borrado se validan contra esta
                // foto, no contra una lista que pudo cambiar a mitad.
                let entradasDelTurno = config.memoria
                let ejecutorMemoria = EjecutorMemoriaDelTurno(
                    entradas: entradasDelTurno
                ) { [weak self] operacion in
                    guard let self else {
                        return .rechazada(
                            "la Memoria no esta disponible en este turno."
                        )
                    }
                    return await self.aplicarOperacionDeMemoria(
                        operacion,
                        idConversacion: idConversacion
                    )
                }
                herramientas = [
                    HerramientaMemoriaTipada(
                        definicion: Memoria.herramientaGuardar
                    ) { argumentos in
                        try await ejecutorMemoria.ejecutar(
                            herramienta: Memoria.nombreGuardar,
                            argumentos: argumentos
                        )
                    },
                    HerramientaMemoriaTipada(
                        definicion: Memoria.herramientaActualizar
                    ) { argumentos in
                        try await ejecutorMemoria.ejecutar(
                            herramienta: Memoria.nombreActualizar,
                            argumentos: argumentos
                        )
                    },
                    HerramientaMemoriaTipada(
                        definicion: Memoria.herramientaProponerSensible
                    ) { argumentos in
                        try await ejecutorMemoria.ejecutar(
                            herramienta: Memoria.nombreProponerSensible,
                            argumentos: argumentos
                        )
                    },
                    HerramientaMemoriaTipada(
                        definicion: Memoria.herramientaBorrar
                    ) { argumentos in
                        try await ejecutorMemoria.ejecutar(
                            herramienta: Memoria.nombreBorrar,
                            argumentos: argumentos
                        )
                    }
                ]
            }
            let bucle = ToolLoop(motor: motor, herramientas: herramientas)

            let resultado = try await bucle.ejecutar(
                historial: historial,
                alRecibirTexto: { fragmento in
                    Task { @MainActor [weak self] in
                        if let self { self.textoEnCurso += fragmento }
                    }
                }
            )

            // Todo uso recibido alimenta el acumulador global, incluso si el
            // usuario pulso Detener justo despues de que llegara la respuesta.
            registrarGasto(uso: resultado.usoTotal, proveedor: proveedor)

            // Si el usuario pulso Detener justo despues de recibir la
            // respuesta, el turno no se publica aunque el bucle ya haya
            // devuelto un resultado.
            try Task.checkCancellation()

            textoEnCurso = ""
            // B2.2: si el hilo abierto ya es otro (se cerro un hilo temporal o
            // se cambio de chat mientras corria el turno), la respuesta no se
            // escribe en el hilo nuevo ni se guarda: seria un rastro del
            // temporal y, en el caso normal, un mensaje en el chat equivocado.
            guard conversacion.id == idConversacion else { return }
            // Cada mensaje generado conserva su proveedor y, si trae consumo,
            // su sello de costo con los precios de ESE proveedor en este
            // momento (COST.1). Regenerar y reintentar pasan por aqui, asi que
            // sellan igual; el sello de un mensaje anterior no se reescribe.
            var nuevos = resultado.mensajesNuevos
            for indice in nuevos.indices {
                nuevos[indice].proveedorID = proveedor.id
                SellosDeCosto.sellar(&nuevos[indice], proveedor: proveedor)
            }
            conversacion.mensajes.append(contentsOf: nuevos)
            // La respuesta nueva pasa a ser la medida de la ventana; el uso de
            // la compactacion deja de ser el numerador.
            conversacion.usoTrasCompactar = nil
            limpiarErrorDeTurno()

            if resultado.seAgotoElLimite {
                error = "Se alcanzo el limite de \(bucle.maxIteraciones) vueltas de herramientas."
            }

            persistirActual()
        } catch is CancellationError {
            textoEnCurso = ""
            alFracasar()
            // Cerrar un hilo temporal cancela el turno y deja abierto un chat
            // normal vacio: sin esta guarda, el turno cancelado guardaria ese
            // chat vacio en la lista (B2.2).
            guard conversacion.id == idConversacion else { return }
            persistirActual()
        } catch let fallo {
            textoEnCurso = ""
            alFracasar()
            let detalle = (fallo as? LocalizedError)?.errorDescription
                ?? fallo.localizedDescription
            // El error se guarda CON la conversacion: tiene que seguir en el
            // hilo tras reabrir el chat o reiniciar la app. El mensaje del
            // usuario ya esta persistido, asi que reintentar no lo duplica.
            guard conversacion.id == idConversacion else { return }
            conversacion.errorDeTurno = detalle
            turnoFallido = tipo
            persistirActual()
        }
    }

    func cancelar() {
        // Cambiar de chat o cortar el turno tambien corta el dictado: el
        // microfono no puede quedar escuchando en una conversacion que ya no
        // esta en pantalla.
        detenerDictado()
        // B2.4: cortar el turno con la hoja sensible abierta es cerrarla sin
        // aprobar. Se resuelve como denegacion para que el turno no quede
        // colgado esperando una decision que ya no va a llegar; la tarea se
        // cancela justo despues y no llega a escribir nada.
        cerrarPropuestaSensible()
        tareaActual?.cancel()
        tareaActual = nil
        tareaCompactado?.cancel()
        tareaCompactado = nil
        tareaPlanChat?.cancel()
        tareaPlanChat = nil
        generacionCompactado = UUID()
        compactando = false
        generandoPlanChat = false
        enviando = false
        textoEnCurso = ""
    }

    // MARK: - Proyeccion visible (P0.2)

    /// Que se ve en el hilo abierto, en orden y sin efectos.
    ///
    /// Es la traduccion ejecutable de la tabla S0-S5 al catalogo cerrado de
    /// `UI_INVARIANTS.md`. `ChatView` pinta esta lista y no vuelve a decidir
    /// filas leyendo `conversacion.mensajes`.
    ///
    /// Reglas de mezcla (las mismas que tenia la vista, ahora en la capa de
    /// aplicacion): eventos sin ancla al principio, cada mensaje seguido de sus
    /// eventos anclados y los eventos huerfanos al final. La exclusion es por
    /// tipo: los mensajes de rol herramienta y los `toolCalls` de un mensaje de
    /// asistente no producen ningun elemento.
    func elementosVisiblesDelHilo() -> [ElementoHiloVisible] {
        let mensajes = conversacion.mensajes
        let ids = Set(mensajes.map(\.id))
        var resultado: [ElementoHiloVisible] = []

        // Divisores y lineas de memoria que no cuelgan de ningun mensaje.
        for evento in eventosVisuales where evento.trasMensaje == nil {
            if let elemento = elementoVisible(de: evento) {
                resultado.append(elemento)
            }
        }

        for mensaje in mensajes {
            switch mensaje.rol {
            case .usuario:
                resultado.append(.burbujaUsuario(texto: mensaje.texto))

            case .asistente:
                // Los toolCalls no son un artefacto visible. Si el mensaje no
                // trae prosa (solo pidio herramientas), no deja burbuja vacia.
                let segmentos = SegmentoRespuesta.segmentos(de: mensaje.texto)
                if !segmentos.isEmpty {
                    resultado.append(.burbujaAsistente(segmentos: segmentos))
                }

            case .herramienta, .sistema:
                // Un resultado de herramienta jamas es un elemento del hilo.
                // Los mensajes de sistema son contexto interno, no conversacion.
                break
            }

            for evento in eventosVisuales where evento.trasMensaje == mensaje.id {
                if let elemento = elementoVisible(de: evento) {
                    resultado.append(elemento)
                }
            }
        }

        // Un evento cuyo ancla desaparecio (por ejemplo, al regenerar) no se
        // pierde: se pinta al final para no ocultar informacion.
        let huerfanos = eventosVisuales.filter { evento in
            guard let ancla = evento.trasMensaje else { return false }
            return !ids.contains(ancla)
        }
        for evento in huerfanos {
            if let elemento = elementoVisible(de: evento) {
                resultado.append(elemento)
            }
        }

        if let propuesta = propuestaMemoriaSensible,
           propuesta.estado == .pendiente {
            // La hoja es el UNICO artefacto del turno mientras esta pendiente:
            // no se anade burbuja en curso ni error de turno a su lado.
            resultado.append(
                .hojaAprobacionMemoria(
                    texto: propuesta.texto,
                    categoriaSensible: propuesta.categoriaSensible,
                    estado: propuesta.estado
                )
            )
        } else {
            if enviando {
                resultado.append(.burbujaEnCurso(texto: textoEnCurso))
            }
            if !enviando, let error = errorDeTurno,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultado.append(.errorTurno(texto: error))
            }
        }

        return resultado
    }

    /// Traduce un evento visual a su elemento del catalogo.
    ///
    /// La traslacion es conservadora a proposito: un cambio de memoria sigue
    /// produciendo `.lineaMemoria` con el texto visible del cambio.
    private func elementoVisible(de evento: EventoVisual) -> ElementoHiloVisible? {
        if let cambio = evento.cambioMemoria {
            return .lineaMemoria(
                texto: cambio.textoDeLinea,
                puedeDeshacer: !evento.deshecho,
                deshecho: evento.deshecho
            )
        }
        return .divisor(texto: evento.texto)
    }

    /// Mensaje de origen de cada burbuja proyectada, por indice.
    ///
    /// La vista lo usa solo para metadatos que el catalogo no pinta (skills,
    /// pie de consumo y accion de ramificar). Las filas siguen saliendo de
    /// `elementosVisiblesDelHilo()`.
    func fuentesDeBurbujaVisibles(
        _ elementos: [ElementoHiloVisible]
    ) -> [Int: ChatMessage] {
        let visibles = conversacion.mensajes.filter { mensaje in
            switch mensaje.rol {
            case .usuario:
                return true
            case .asistente:
                return !SegmentoRespuesta.segmentos(de: mensaje.texto).isEmpty
            case .herramienta, .sistema:
                return false
            }
        }

        var fuentes: [Int: ChatMessage] = [:]
        var cursor = 0
        for (indice, elemento) in elementos.enumerated() {
            switch elemento {
            case .burbujaUsuario:
                while cursor < visibles.count,
                      visibles[cursor].rol != .usuario {
                    cursor += 1
                }
                if cursor < visibles.count {
                    fuentes[indice] = visibles[cursor]
                    cursor += 1
                }

            case .burbujaAsistente:
                while cursor < visibles.count,
                      visibles[cursor].rol != .asistente {
                    cursor += 1
                }
                if cursor < visibles.count {
                    fuentes[indice] = visibles[cursor]
                    cursor += 1
                }

            default:
                break
            }
        }
        return fuentes
    }

    /// Evento de memoria de cada linea proyectada, por indice.
    ///
    /// Permite que [Deshacer] actue sobre el cambio exacto sin que el UUID
    /// entre en el catalogo de elementos visibles.
    func eventosDeMemoriaVisibles(
        _ elementos: [ElementoHiloVisible]
    ) -> [Int: EventoVisual] {
        let mensajes = conversacion.mensajes
        let ids = Set(mensajes.map(\.id))
        var eventos = eventosVisuales.filter {
            $0.trasMensaje == nil && $0.cambioMemoria != nil
        }
        for mensaje in mensajes {
            eventos += eventosVisuales.filter {
                $0.trasMensaje == mensaje.id && $0.cambioMemoria != nil
            }
        }
        eventos += eventosVisuales.filter { evento in
            guard let ancla = evento.trasMensaje else { return false }
            return !ids.contains(ancla) && evento.cambioMemoria != nil
        }

        var memorias: [Int: EventoVisual] = [:]
        var cursor = 0
        for (indice, elemento) in elementos.enumerated() {
            if case .lineaMemoria = elemento, cursor < eventos.count {
                memorias[indice] = eventos[cursor]
                cursor += 1
            }
        }
        return memorias
    }

    /// Que se ve en la pantalla de una Tarea, en orden y sin efectos.
    ///
    /// Cabecera, tarjeta de plan y filas del libro. La vista de Tarea pintara
    /// esta lista igual que el Chat pinta la suya; el estado no cambia aqui.
    func elementosVisiblesDeTarea(_ tarea: Tarea) -> [ElementoTareaVisible] {
        var resultado: [ElementoTareaVisible] = []
        let total = tarea.pasos.count

        resultado.append(
            .cabeceraTarea(
                estado: estadoVisibleDeTarea(tarea),
                pasoActual: Self.pasoActualDe(tarea),
                pasosTotales: total,
                costoSellado: Decimal(tarea.costoAcumuladoUSD ?? 0)
            )
        )

        if let plan = tarea.plan {
            // La version vive en el plan (B3-A): el plan inicial es 1 y cada
            // ajuste o regeneracion la sube. Un plan viejo sin campo se lee
            // como 1 por la decodificacion tolerante de NodoCore.
            resultado.append(.tarjetaPlan(pasos: plan.pasos, version: plan.version))
        }

        for (indice, paso) in tarea.pasos.enumerated() {
            resultado.append(
                .filaPaso(
                    paso: indice + 1,
                    estado: Self.estadoVisibleDePaso(paso, tarea: tarea),
                    etiquetaDinamica: Self.etiquetaDinamicaDePaso(
                        paso,
                        indice: indice + 1
                    ),
                    duracion: Self.duracionDePaso(paso),
                    costo: paso.costoUSD.map { Decimal($0) }
                )
            )
        }

        return resultado
    }

    /// Que se ve en la pestana Chats para un termino de busqueda.
    ///
    /// Una fila se identifica por titulo y vista previa de texto, nunca por un
    /// identificador interno. Si no hay coincidencias se devuelve el estado
    /// vacio explicito: la pestana no queda en blanco sin explicacion.
    func elementosVisiblesDeBusqueda(
        _ termino: String,
        en conversaciones: [Conversation]? = nil
    ) -> [ElementoBusquedaVisible] {
        let lista = conversaciones ?? self.conversaciones
        let consulta = termino.trimmingCharacters(in: .whitespacesAndNewlines)
        let coincidentes = lista.filter {
            HistorialConversaciones.coincide($0, con: consulta)
        }

        guard !coincidentes.isEmpty else {
            return [.sinResultados(termino: consulta)]
        }

        return coincidentes.map { conversacion in
            .resultadoBusqueda(
                titulo: conversacion.titulo,
                vistaPrevia: Self.vistaPreviaDe(conversacion, termino: consulta)
            )
        }
    }

    /// Estado visible de la cabecera de una tarea.
    ///
    /// `planificando` y `aprobacionPendiente` existen para que el test de los
    /// 8 estados (B3-A) pueda fijar las dos condiciones que en produccion son
    /// transitorias, sin tocar el estado real de la app.
    func estadoVisibleDeTarea(
        _ tarea: Tarea,
        planificando: Bool? = nil,
        aprobacionPendiente: Bool? = nil
    ) -> ElementoTareaVisible.EstadoTarea {
        let estaPlanificando = planificando ?? (idTareaPlanificando == tarea.id)
        switch tarea.estado {
        case .borrador:
            return estaPlanificando ? .planificando : .nuevaTarea

        case .esperandoInicio:
            let tienePlan = !(tarea.plan?.pasos.isEmpty ?? true)
            return tienePlan ? .planPropuesto : .nuevaTarea

        case .enCurso:
            let esperaAprobacion = aprobacionPendiente
                ?? (solicitudAprobacion?.tareaID == tarea.id
                    || tarea.pasos.contains { $0.aprobacion == .pendiente })
            return esperaAprobacion ? .esperandoAprobacion : .enCurso

        case .detenida, .interrumpida:
            return .detenida

        case .completada:
            return .completada

        case .fallida:
            return .error
        }
    }

    /// Numero visible del paso en curso, o del siguiente pendiente.
    private static func pasoActualDe(_ tarea: Tarea) -> Int {
        guard !tarea.pasos.isEmpty else { return 0 }

        if let indice = tarea.pasos.firstIndex(where: { $0.estado == .enCurso }) {
            return indice + 1
        }

        let resueltos = tarea.pasos.filter { $0.estado.estaResuelto }.count
        return min(max(1, resueltos + 1), tarea.pasos.count)
    }

    /// Estado visible de una fila del libro.
    private static func estadoVisibleDePaso(
        _ paso: Paso,
        tarea: Tarea
    ) -> ElementoTareaVisible.EstadoPaso {
        if paso.aprobacion == .pendiente {
            return .esperandoAprobacion
        }

        switch paso.estado {
        case .pendiente:
            return .pendiente

        case .enCurso:
            if tarea.estado == .detenida || tarea.estado == .interrumpida {
                return .detenido
            }
            return .enCurso

        case .terminado:
            return .completado

        case .denegado:
            return .denegado

        case .fallido:
            return .error
        }
    }

    /// Rotulo humano de una fila. Nunca es el nombre tecnico de la herramienta
    /// ni sus argumentos crudos (que pueden traer un UUID).
    private static func etiquetaDinamicaDePaso(_ paso: Paso, indice: Int) -> String {
        if let fase = paso.etiquetaDeFase {
            return fase
        }

        if paso.herramienta == Memoria.nombreHerramientaTarea {
            if let accion = try? Memoria.accion(
                desdeArgumentos: paso.argumentos ?? ""
            ) {
                switch accion {
                case .guardar: return "Guardar en Memoria"
                case .actualizar: return "Actualizar en Memoria"
                case .borrar: return "Borrar de Memoria"
                }
            }
            return "Memoria"
        }

        if paso.herramienta == "traer_url" {
            return "Leer enlace"
        }

        return "Paso \(indice)"
    }

    /// Duracion de un paso, solo cuando el sello de cierre existe.
    private static func duracionDePaso(_ paso: Paso) -> TimeInterval? {
        guard let inicio = paso.fechaInicio, let fin = paso.fechaFin else {
            return nil
        }
        return max(0, fin.timeIntervalSince(inicio))
    }

    /// Vista previa de texto de una conversacion coincidente, sin ids.
    private static func vistaPreviaDe(
        _ conversacion: Conversation,
        termino: String
    ) -> String {
        let coincidente = conversacion.mensajes.first { mensaje in
            !termino.isEmpty
                && mensaje.texto.range(
                    of: termino,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
        }
        let primeroConTexto = conversacion.mensajes.first {
            !$0.texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let crudo = (coincidente ?? primeroConTexto)?.texto ?? ""
        let limpio = crudo
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !limpio.isEmpty else { return conversacion.titulo }
        if limpio.count <= 120 { return limpio }
        return String(limpio.prefix(120)) + "…"
    }

    // MARK: - Dictado (§4.5)

    /// Alterna el dictado: si esta grabando lo corta y, si no, lo arranca.
    ///
    /// El texto parcial se escribe en `borrador` conforme llega y se conserva
    /// si el dictado falla o se cancela. Nunca se envia solo: el dueno decide
    /// cuando pulsar Enviar, igual que con el texto tecleado.
    func alternarDictado() async {
        if dictando {
            detenerDictado()
            return
        }
        guard !compactando, !enviando, !generandoPlanChat else { return }

        avisoComando = nil
        // Se conserva lo que ya habia en la caja y solo se reemplaza la parte
        // dictada en esta sesion.
        prefijoDictado = borrador
        let sesion = UUID()
        generacionDictado = sesion

        let permitido = await dictado.solicitarPermisos()
        guard permitido else {
            restablecerDictado(
                aviso: "El dictado necesita permiso de micrófono y reconocimiento de voz."
            )
            return
        }

        do {
            try dictado.empezar(
                onParcial: { [weak self] texto in
                    Task { @MainActor in
                        self?.aplicarParcialDictado(texto, sesion: sesion)
                    }
                },
                onFallo: { [weak self] error in
                    Task { @MainActor in
                        self?.fallarDictado(error, sesion: sesion)
                    }
                }
            )
            dictando = true
        } catch {
            restablecerDictado(
                aviso: (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }

    /// Corta el dictado conservando lo dictado hasta ahora.
    func detenerDictado() {
        guard dictando else { return }
        // Se invalida la sesion ANTES de cortar: si el reconocedor avisa del
        // corte como error, ese aviso tardio ya no cuenta.
        generacionDictado = UUID()
        dictado.detener()
        dictando = false
        prefijoDictado = ""
    }

    /// Escribe una transcripcion parcial en la caja, conservando el prefijo.
    private func aplicarParcialDictado(_ parcial: String, sesion: UUID) {
        guard dictando, sesion == generacionDictado else { return }
        let separador = prefijoDictado.isEmpty
            || prefijoDictado.hasSuffix(" ")
            || prefijoDictado.hasSuffix("\n") ? "" : " "
        borrador = prefijoDictado + separador + parcial
        avisoComando = nil
    }

    /// Cierra la sesion ante un fallo del reconocedor sin perder lo dictado.
    private func fallarDictado(_ error: Error?, sesion: UUID) {
        guard dictando, sesion == generacionDictado else { return }
        dictado.detener()
        let detalle = (error as? LocalizedError)?.errorDescription
            ?? error?.localizedDescription
        restablecerDictado(aviso: detalle)
    }

    /// Deja el dictado inactivo. NO toca el borrador a proposito: el texto
    /// parcial ya escrito no se puede perder.
    private func restablecerDictado(aviso: String?) {
        dictando = false
        prefijoDictado = ""
        if let aviso {
            avisoComando = aviso
        }
    }

    /// Historial que se manda al modelo: el bloque de Memoria primero.
    ///
    /// La regla vive en NodoCore para poder probarla con `swift test`: en un
    /// chat sin memoria no se inyecta ni el bloque ni las entradas (§4.6). Los
    /// eventos visuales no forman parte de `conversacion.mensajes`, asi que
    /// jamas entran aqui.
    private func historialParaEnviar() -> [ChatMessage] {
        Historial.paraEnviar(
            conversacion: conversacion,
            memoria: config.memoria,
            // Respaldo persistido de COMP.2: Historial solo lo usa cuando la
            // conversacion no aporta el resumen por la via de la Memoria.
            resumenGuardado: resumenesCompactadosPorConversacion[
                conversacion.id.uuidString
            ],
            // B2.3: el interruptor decide SOLO la instruccion de disparo. El
            // conjunto de herramientas se decide mas abajo, en ejecutarTurno,
            // y es el mismo con ON y con OFF.
            disparoMemoria: config.memoriaInteligente
                ? .juicio
                : .ordenExplicita
        )
    }

    private func motorPara(proveedor: ProviderConfig, clave: String) -> ChatEngine {
        // Solo las capturas sustituyen el motor real; en produccion no cambia.
        if let estadoDePrueba {
            return MotorDePrueba(falla: estadoDePrueba.motorFalla)
        }

        switch proveedor.protocolo {
        case .chatCompletions:
            return ChatCompletionsClient(transporte: transporte, config: proveedor, clave: clave)
        case .anthropic:
            return AnthropicClient(transporte: transporte, config: proveedor, clave: clave)
        }
    }

    // MARK: - Servidor

    /// Prueba la conexion y devuelve las herramientas encontradas.
    func probarServidor() async -> (exito: Bool, mensaje: String) {
        guard config.servidor.estaConfigurado else {
            return (false, "Falta la direccion del servidor, o no empieza por https.")
        }

        do {
            let cliente = try MCPClient(
                transporte: transporte,
                config: config.servidor,
                token: tokenServidor
            )
            let (info, herramientas) = try await cliente.probar()
            let nombres = herramientas.map(\.nombre).joined(separator: ", ")
            let detalle = herramientas.isEmpty
                ? "No expone ninguna herramienta."
                : "\(herramientas.count) herramientas: \(nombres)"
            return (true, "Conectado a \(info.nombre) \(info.version). \(detalle)")
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }
    }

    // MARK: - Exportar e importar

    /// Texto legible de la conversacion abierta para /exportar (§4.2).
    ///
    /// No incluye eventos visuales (nunca fueron mensajes) ni instrucciones de
    /// skills (solo viajan en el payload de su turno). El resumen de una
    /// compactacion si se incluye, porque forma parte del contexto guardado.
    func exportarConversacion() -> String {
        var lineas: [String] = ["Conversación: \(conversacion.titulo)", ""]

        let resumenGuardado = (conversacion.resumenCompactado ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !resumenGuardado.isEmpty {
            lineas.append("Resumen de la conversación:")
            lineas.append(resumenGuardado)
            lineas.append("")
        }

        if conversacion.mensajes.isEmpty {
            lineas.append("Sin mensajes.")
            return lineas.joined(separator: "\n")
        }

        for mensaje in conversacion.mensajes {
            lineas.append("## \(nombreDeRol(mensaje.rol))")
            lineas.append(mensaje.texto)
            lineas.append("")
        }
        return lineas.joined(separator: "\n")
    }

    private func nombreDeRol(_ rol: ChatMessage.Rol) -> String {
        switch rol {
        case .usuario: return "Usuario"
        case .asistente: return "Asistente"
        case .sistema: return "Sistema"
        case .herramienta: return "Herramienta"
        }
    }
}

/// Resultado interno de una fase de la tuberia /boost.
///
/// Lleva el id del paso para poder anotar el parseo fallido y el texto para la
/// fase siguiente. El costo se sella al cerrar, no se recalcula despues.
private struct ResultadoFaseBoost {
    var pasoID: UUID
    var texto: String
    var costo: Double?
}

/// Errores propios de /boost, con mensaje visible para el dueno.
private enum ErrorBoost: LocalizedError {
    case sinAngulos
    case sinAngulosResueltos
    case sinCombos
    case respuestaVacia(fase: FaseBoost)

    var errorDescription: String? {
        switch self {
        case .sinAngulos:
            return "El orquestador no devolvió ningún ángulo."
        case .sinAngulosResueltos:
            return "Ningún ángulo se pudo resolver: no hay nada que sintetizar."
        case .sinCombos:
            return "No hay proveedores con precio para repartir los ángulos."
        case .respuestaVacia(let fase):
            return "La fase \(fase.titulo) devolvió una respuesta vacía."
        }
    }
}
