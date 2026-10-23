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
    /// True mientras /plan pide el plan dentro de un chat.
    @Published private(set) var generandoPlanChat = false
    /// Error propio de la pantalla de Tareas, separado del error del chat.
    @Published var errorTarea: String?

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
    /// Se pinta en linea al final del hilo (§3.7) en vez de en el aviso
    /// generico: asi el mensaje del usuario sigue a la vista y se puede
    /// reintentar sin volver a escribirlo.
    @Published var errorDeTurno: String?

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
        directorioTareas: URL? = nil
    ) {
        self.llavero = llavero
        self.estadoDePrueba = estadoDePrueba
        self.persistir = estadoDePrueba == nil
        self.transporte = transporte
        self.defaults = defaults
        // En capturas el dictado es un doble que inyecta una transcripcion fija
        // sin pedir permisos ni tocar el microfono. El resto del flujo es el
        // mismo que en el iPhone real.
        if estadoDePrueba == nil {
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

    /// Texto plano de la Memoria para la hoja rapida del chat (H6.3) y para
    /// medir su peso.
    ///
    /// Mi Contexto ya edita por entradas (MEM.4), pero la hoja rapida sigue
    /// trabajando con el bloque completo: su conversion es H6.3 y no se mezcla
    /// con esta tarea. El payload NO usa esto: `Historial` manda el bloque con
    /// las entradas y sus ids.
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

    /// Anade una entrada escrita a mano desde Mi Contexto (MEM.4).
    ///
    /// Aqui no hay tarjeta ni Deshacer: el dueno esta en la pantalla de edicion
    /// y el cambio es directo. La tarjeta es para los cambios que ordena al
    /// modelo dentro de un chat.
    @discardableResult
    func agregarEntradaMemoria(_ texto: String) -> EntradaMemoria? {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty else { return nil }

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

    /// Aplica una accion de `memoria_chat` sobre la configuracion y deja la
    /// tarjeta de evento en el hilo donde se dio la orden.
    ///
    /// Se llama desde la herramienta, ya en el MainActor. La lista se escribe
    /// una sola vez y solo cuando la accion se aplico: un id desconocido no
    /// toca nada.
    private func aplicarAccionDeMemoria(
        _ accion: AccionMemoria,
        idConversacion: UUID
    ) -> ResultadoAccionMemoria {
        var entradas = config.memoria
        let resultado = Memoria.aplicar(accion, en: &entradas)
        guard case .aplicada(let cambio) = resultado else {
            return resultado
        }

        config.memoria = entradas

        // La tarjeta se ancla al ultimo mensaje visible: la orden del dueno ya
        // esta en el hilo y la confirmacion del modelo aun no ha llegado.
        // Si el dueno cambio de chat mientras el modelo respondia, el cambio
        // de Memoria sigue siendo real (es global), pero su tarjeta no debe
        // aparecer en otro hilo.
        if conversacion.id == idConversacion {
            eventosVisuales.append(
                EventoVisual(
                    trasMensaje: conversacion.mensajes.last?.id,
                    texto: cambio.textoDeTarjeta,
                    cambioMemoria: cambio
                )
            )
        }

        return .aplicada(cambio)
    }

    /// Revierte exactamente el cambio de una tarjeta de Memoria (MEM.3).
    ///
    /// Devuelve false si la tarjeta no existe, no es de Memoria o ya se habia
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

    /// Suma a los contadores y al libro de gasto el costo de un uso recibido.
    ///
    /// Es el punto UNICO de alimentacion: lo llaman los turnos normales
    /// (envios y regeneraciones) y la llamada de resumen de /compact. El
    /// contador vive en `AppConfig`, asi que borrar un chat no lo resta; el
    /// libro de COST.2 anota la misma llamada en su dia y su mes.
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
        // son un hecho. Sin precios, el USD queda en cero en vez de inventarse.
        config.usoApp.registrar(uso: uso, usd: costo ?? 0, fecha: fecha)
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
        var copia = otra
        copia.titulo = titulo
        try? store?.guardar(copia)
        reemplazarEnMemoria(copia)
        recargarConversaciones()
    }

    /// Fija o desfija una conversacion sin tocar la que este abierta.
    func fijar(_ otra: Conversation, fijada: Bool = true) {
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

    private func guardarActual() {
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
        let tarea = Tarea(
            instruccion: limpia,
            conversacionID: conversacionID,
            proveedorID: config.proveedorSeleccionado?.id
        )
        guardarTarea(tarea)
        return tarea
    }

    /// Borra una tarea y su archivo. El plan y el libro se van con ella.
    func borrarTarea(id: UUID) {
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
    func generarPlan(id: UUID, instruccion: String? = nil) async {
        guard !generandoPlan else { return }
        guard let indice = tareas.firstIndex(where: { $0.id == id }) else { return }

        let limpia = (instruccion ?? tareas[indice].instruccion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpia.isEmpty else {
            errorTarea = "Escribe una instrucción para generar el plan."
            return
        }
        guard tareas[indice].admiteEdicion else {
            errorTarea = "La tarea ya empezó: el plan no se puede cambiar."
            return
        }

        // La instruccion editada se guarda antes de salir a la red. Si la
        // llamada falla, el dueno no pierde lo que escribio.
        tareas[indice].instruccion = limpia
        tareas[indice].plan = nil
        tareas[indice].estado = .borrador
        tareas[indice].fechaActualizacion = Date()
        guardarTarea(tareas[indice])

        // `guardarTarea` recarga la lista ordenada: se vuelve a buscar la tarea
        // por id en vez de reutilizar el indice anterior.
        guard let tareaParaPlan = tareas.first(where: { $0.id == id }),
              let (proveedor, clave) = proveedorYClaveParaTarea(tareaParaPlan)
        else {
            return
        }

        generandoPlan = true
        errorTarea = nil
        defer { generandoPlan = false }

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

            let plan = PlanTarea.desde(
                texto: respuesta.texto,
                proveedorID: proveedor.id
            )
            guard !plan.pasos.isEmpty else {
                errorTarea = "El modelo devolvió un plan vacío. Inténtalo de nuevo."
                return
            }

            // La tarea pudo borrarse o empezar mientras llegaba la respuesta:
            // en ese caso el plan ya no se publica.
            guard let actual = tareas.firstIndex(where: { $0.id == id }),
                  tareas[actual].admiteEdicion
            else {
                return
            }
            tareas[actual].instruccion = limpia
            tareas[actual].plan = plan
            tareas[actual].estado = .esperandoInicio
            tareas[actual].proveedorID = proveedor.id
            tareas[actual].fechaActualizacion = Date()
            guardarTarea(tareas[actual])
        } catch is CancellationError {
            // Cambiar de pantalla o borrar la tarea no deja un error falso.
        } catch {
            let detalle = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorTarea = "No se pudo generar el plan: \(detalle)"
        }
    }

    /// Autoriza la ejecucion: deja la tarea `enCurso` y nada mas.
    ///
    /// TASK.2 termina aqui. TASK.3 conecta el libro de pasos y las herramientas;
    /// hasta entonces Empezar no inventa pasos ni llama a ninguna herramienta.
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

        tareas[indice].estado = .enCurso
        tareas[indice].fechaActualizacion = Date()
        guardarTarea(tareas[indice])
        return true
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
        }
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
        guard conversacion.mensajes.last?.rol == .asistente else { return }

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

        let tipo = turnoFallido
        limpiarErrorDeTurno()

        switch tipo {
        case .regeneracion:
            regenerar()
        case .envio, .none:
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
        // usa Memoria, el payload lleva bloque y memoria_chat; si no, ni uno ni
        // otro. Se captura antes de lanzar la tarea para que un cambio de chat
        // a mitad de turno no mezcle dos contextos.
        let usaMemoria = !conversacion.sinMemoria
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
            // excepcion es la Memoria: si el chat la usa, se ofrece memoria_chat
            // y se ejecuta de verdad (MEM.3). En un chat sin memoria no se
            // ofrece nada.
            var herramientas: [Herramienta] = []
            if usaMemoria {
                herramientas = [
                    HerramientaMemoriaChat { [weak self] accion in
                        guard let self else {
                            return .rechazada(
                                "la Memoria no esta disponible en este turno."
                            )
                        }
                        // La lista vive en el estado de la app: el salto al
                        // MainActor se hace aqui, en la costura, y el nucleo
                        // sigue sin conocer SwiftUI ni el hilo.
                        return await MainActor.run {
                            self.aplicarAccionDeMemoria(
                                accion,
                                idConversacion: idConversacion
                            )
                        }
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
            persistirActual()
        } catch let fallo {
            textoEnCurso = ""
            alFracasar()
            errorDeTurno = (fallo as? LocalizedError)?.errorDescription
                ?? fallo.localizedDescription
            turnoFallido = tipo
            persistirActual()
        }
    }

    func cancelar() {
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
            ]
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
