import Foundation
import SwiftUI

import NodoCore

/// Aprobacion que espera la decision del usuario antes de ejecutar una
/// herramienta con consecuencias en modo Tarea.
///
/// Lleva la llamada original (para devolverla al bucle) y un resumen legible
/// con el nombre y los argumentos recortados, que es lo unico que se pinta en
/// la hoja de aprobacion.
struct AprobacionPendiente: Identifiable, Equatable {
    let id: UUID
    let llamada: ToolCall
    let nombreHerramienta: String
    let resumenArgumentos: String

    init(id: UUID = UUID(), llamada: ToolCall) {
        self.id = id
        self.llamada = llamada
        self.nombreHerramienta = llamada.nombre

        let plano = llamada.argumentos
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plano.count > 160 {
            self.resumenArgumentos = String(plano.prefix(160)) + "…"
        } else {
            self.resumenArgumentos = plano
        }
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
    /// Aprobacion pendiente del usuario, o nil si no hay ninguna.
    @Published var aprobacionPendiente: AprobacionPendiente?
    /// Nombre de la herramienta que se esta ejecutando ahora mismo. nil fuera
    /// de una ejecucion; alimenta la fila "Ejecutando..." de la conversacion.
    @Published private(set) var herramientaEnCurso: String?
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
    private var usoResumidoPorConversacion: [String: UsoTokens] = [:] {
        didSet { guardarUsosResumidos() }
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
    private var tareaActual: Task<Void, Never>?
    /// Tarea de resumen de /compact, para poder cancelarla al cambiar de chat.
    private var tareaCompactado: Task<Void, Never>?
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
    /// Continuacion que mantiene el turno suspendido mientras la hoja de
    /// aprobacion espera. Se resuelve una sola vez por aprobacion.
    private var continuacionAprobacion: CheckedContinuation<Bool, Never>?
    /// La carga inicial del diccionario no debe escribir nada: se activa al
    /// terminar el init normal y se queda apagada en modo de prueba.
    private var puedeGuardarVentanas = false
    private var puedeGuardarUsosResumidos = false

    private static let claveConfig = "nodo.config.v1"
    private static let claveVentanas = "nodo.ventanas.v1"
    private static let claveUsosResumidos = "nodo.usos-resumidos.v1"

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
        directorioStore: URL? = nil
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
        self.puedeGuardarVentanas = true
        self.puedeGuardarUsosResumidos = true
        sincronizarSkills()
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

    private static func usosResumidosGuardados(de defaults: UserDefaults) -> [String: UsoTokens] {
        guard let datos = defaults.data(forKey: claveUsosResumidos),
              let usos = try? JSONDecoder().decode([String: UsoTokens].self, from: datos)
        else {
            return [:]
        }
        return usos
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
            total = total?.sumando(resumido) ?? resumido
        }
        return total
    }

    /// Costo acumulado del chat abierto, con los precios del proveedor activo.
    ///
    /// Sin precios configurados no hay cifra: no se inventa un costo.
    var costoAcumuladoDelChat: Double? {
        guard let proveedor = config.proveedorSeleccionado,
              let uso = usoAcumuladoDelChat
        else {
            return nil
        }
        return CostoEstimado.costo(
            uso: uso,
            precioEntrada: proveedor.precioEntradaPorMillon,
            precioSalida: proveedor.precioSalidaPorMillon
        )
    }

    // MARK: - Memoria

    /// Peso estimado de la Memoria: caracteres / 4, minimo 1 (§3.5).
    ///
    /// Es la misma heuristica de la Hoja Memoria rapida; vive aqui para que las
    /// dos caras de la Memoria ensenen siempre la misma cifra.
    var pesoEstimadoMemoria: Int {
        max(1, config.systemPrompt.count / 4)
    }

    /// Costo estimado de mandar la Memoria en un envio.
    ///
    /// Usa solo el precio de entrada del proveedor activo y devuelve tambien su
    /// nombre limpio para rotularlo. Sin precio de entrada no hay cifra.
    var costoEstimadoDeMemoria: (costo: Double, modelo: String)? {
        let memoria = config.systemPrompt
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
        let limpio = NombresLimpios.modelo(proveedor.modelo)
        let modelo = limpio.isEmpty
            ? NombresLimpios.proveedor(
                nombre: proveedor.nombre,
                baseURL: proveedor.baseURL
            )
            : limpio
        return (costo, modelo)
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

    /// Suma a los contadores globales el costo de un uso recibido.
    ///
    /// Es el punto unico de alimentacion: lo llaman los turnos normales (envios,
    /// regeneraciones y modo Tarea) y la llamada de resumen de /compact. El
    /// contador vive en `AppConfig`, asi que borrar un chat no lo resta.
    private func registrarGasto(uso: UsoTokens?, proveedor: ProviderConfig) {
        guard let uso,
              let costo = CostoEstimado.costo(
                  uso: uso,
                  precioEntrada: proveedor.precioEntradaPorMillon,
                  precioSalida: proveedor.precioSalidaPorMillon
              ),
              costo > 0
        else {
            return
        }
        config.gasto.registrar(costo: costo, hoy: Self.hoyComoClave())
    }

    /// Fecha local de hoy en el formato que guarda `ContadoresGasto`.
    private static func hoyComoClave() -> String {
        let formateador = DateFormatter()
        formateador.calendar = Calendar(identifier: .gregorian)
        formateador.locale = Locale(identifier: "en_US_POSIX")
        formateador.dateFormat = "yyyy-MM-dd"
        return formateador.string(from: Date())
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

    /// Cambia el modo Chat/Tarea. En esta fase solo se persiste el flag.
    func cambiarModoTarea(_ activo: Bool) {
        guard conversacion.modoTarea != activo else { return }
        conversacion.modoTarea = activo
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
                texto: eventosVisuales[indice].texto
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

    // MARK: - Envio

    /// Ruta unica de la caja: analiza el borrador y despacha comandos, skills
    /// o el mensaje normal (§4.2).
    ///
    /// ChatView ya no llama a `enviar()` directamente. Los comandos locales
    /// limpian el borrador; un token desconocido o una skill sin mensaje lo
    /// dejan intacto y publican `avisoComando`.
    func enviarTextoActual() {
        guard !enviando, !compactando else { return }

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
        }
    }

    /// Texto de /costo con el consumo real y el tope vigente (§2.4).
    ///
    /// Si no hay precios configurados no se inventa un costo; si el tope es 0
    /// (aviso desactivado) se omite la frase del tope.
    private func textoDeCosto() -> String {
        let proveedor = config.proveedorSeleccionado
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

        if let usoReal,
           let costo = CostoEstimado.costo(
               uso: usoReal,
               precioEntrada: proveedor?.precioEntradaPorMillon,
               precioSalida: proveedor?.precioSalidaPorMillon
           ) {
            // Mismo formato que el pie y el subtitulo de la pildora.
            texto += " · ≈ $\(String(format: "%.4f", costo)) con \(modelo)"
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
    /// La conversacion solo se toca cuando el resumen llega bien: si la llamada
    /// falla, el hilo queda intacto y el error se publica en `error`.
    func compactar() {
        guard !compactando, !enviando else { return }

        let total = conversacion.mensajes.count
        guard total >= 6 else {
            avisoComando = "Todavía no hace falta compactar: la conversación es corta."
            return
        }

        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }

        let idConversacion = conversacion.id
        let mensajes = conversacion.mensajes
        let resumidos = max(0, total - 6)

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
                let peticion = [ChatMessage(
                    rol: .sistema,
                    texto: Self.instruccionesCompactar
                )] + mensajes

                // Sin herramientas y sin streaming: es una llamada de resumen,
                // no un turno de conversacion.
                let respuesta = try await motor.responder(
                    mensajes: peticion,
                    herramientas: [],
                    alRecibirTexto: nil
                )
                try Task.checkCancellation()

                // La llamada de resumen tambien consume: cuenta para el
                // acumulador global aunque luego se descarte el resumen.
                self.registrarGasto(uso: respuesta.uso, proveedor: proveedor)

                guard self.conversacion.id == idConversacion,
                      self.generacionCompactado == generacion
                else {
                    return
                }

                let resumen = respuesta.texto
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resumen.isEmpty else {
                    self.error = "No se pudo compactar: el modelo devolvió un resumen vacío."
                    return
                }

                let mensajesResumidos = Array(
                    self.conversacion.mensajes.prefix(resumidos)
                )
                // La factura conserva el consumo de los mensajes que salen y
                // tambien el de la propia llamada de resumen.
                var usoHistorico = CostoEstimado.usoAcumulado(
                    de: mensajesResumidos
                ) ?? UsoTokens()
                if let usoResumen = respuesta.uso {
                    usoHistorico = usoHistorico.sumando(usoResumen)
                }
                if usoHistorico.total > 0 {
                    let acumulado = self.usoResumidoPorConversacion[
                        idConversacion.uuidString
                    ] ?? UsoTokens()
                    self.usoResumidoPorConversacion[idConversacion.uuidString] =
                        acumulado.sumando(usoHistorico)
                }

                let idsResumidos = Set(mensajesResumidos.map(\.id))
                self.conversacion.mensajes = Array(
                    self.conversacion.mensajes.suffix(6)
                )
                self.conversacion.resumenCompactado = resumen
                self.conversacion.usoTrasCompactar = respuesta.uso

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
        conversacion.proveedorID = proveedor.id

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
        guard conversacion.mensajes.last?.rol == .asistente else { return }

        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }

        conversacion.proveedorID = proveedor.id

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

    /// Regenera la ultima respuesta con otro proveedor configurado.
    ///
    /// Primero cambia el activo por la ruta normal —con su divisor de cambio de
    /// modelo— y despues reutiliza la maquinaria de `regenerar()`. Si el
    /// proveedor ya era el activo, el cambio no hace nada y se regenera igual.
    func regenerarCon(proveedorID: UUID) {
        guard !enviando else { return }
        guard let proveedor = config.proveedores.first(where: { $0.id == proveedorID }) else {
            return
        }
        cambiarProveedor(proveedor)
        regenerar()
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
        conversacion.proveedorID = proveedor.id

        enviando = true
        textoEnCurso = ""
        herramientaEnCurso = nil
        aprobacionPendiente = nil
        error = nil

        var historial = historialParaEnviar()
        if !instrucciones.isEmpty {
            historial = Historial.insertarInstrucciones(
                historial,
                instrucciones: instrucciones
            )
        }
        let modoTarea = conversacion.modoTarea

        tareaActual = Task { [weak self] in
            guard let self else { return }

            await self.ejecutarTurno(
                proveedor: proveedor,
                clave: clave,
                historial: historial,
                modoTarea: modoTarea,
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
        modoTarea: Bool,
        tipo: TipoTurnoFallido,
        alFracasar: () -> Void
    ) async {
        do {
            let motor = motorPara(proveedor: proveedor, clave: clave)
            let herramientas: [Herramienta]
            if modoTarea {
                herramientas = await herramientasDisponibles()
            } else {
                herramientas = []
            }
            let bucle = buclePara(
                motor: motor,
                herramientas: herramientas,
                modoTarea: modoTarea
            )

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

            // Si el usuario pulso Detener mientras esperaba una aprobacion o
            // una herramienta, el turno no se publica aunque el bucle haya
            // alcanzado a devolver un resultado.
            try Task.checkCancellation()

            textoEnCurso = ""
            conversacion.mensajes.append(contentsOf: resultado.mensajesNuevos)
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

    /// Monta el bucle del turno segun el modo.
    ///
    /// En Chat no se ofrece ninguna herramienta y no hay ganchos: el turno es
    /// solo streaming y consumo, igual que antes. En Tarea se ofrecen las
    /// herramientas reales y se cablea la aprobacion por llamada.
    private func buclePara(
        motor: ChatEngine,
        herramientas: [Herramienta],
        modoTarea: Bool
    ) -> ToolLoop {
        guard modoTarea else {
            return ToolLoop(motor: motor, herramientas: herramientas)
        }

        let exentas = config.herramientasSinAprobacion ?? []

        return ToolLoop(
            motor: motor,
            herramientas: herramientas,
            alIniciarHerramienta: { [weak self] llamada in
                Task { @MainActor [weak self] in
                    guard let self, self.enviando else { return }
                    self.herramientaEnCurso = llamada.nombre
                }
            },
            alTerminarHerramienta: { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.herramientaEnCurso = nil
                }
            },
            aprobador: { [weak self] llamada in
                guard let self else { return false }
                return await self.pedirAprobacion(llamada)
            },
            requiereAprobacion: { llamada in
                // Hoy la unica herramienta propia es "traer_url" y solo hace
                // GET. Todo lo demas llega envuelto desde MCP.
                let esTraerURL = llamada.nombre == "traer_url"
                return PoliticaAprobacion.requiereAprobacion(
                    esMCP: !esTraerURL,
                    metodoHTTP: esTraerURL ? "GET" : nil,
                    nombreHerramienta: llamada.nombre,
                    exentas: exentas
                )
            }
        )
    }

    /// Suspende el turno hasta que el usuario decida en la hoja.
    ///
    /// La continuacion se guarda para que `resolverAprobacion` la cierre
    /// exactamente una vez; si ya habia otra pendiente, se rechaza para no
    /// dejar nunca un turno colgado.
    private func pedirAprobacion(_ llamada: ToolCall) async -> Bool {
        // Si Detener llego justo antes de pedir la aprobacion, no se abre una
        // hoja que ya nadie va a poder resolver.
        guard !Task.isCancelled else { return false }

        if let anterior = continuacionAprobacion {
            continuacionAprobacion = nil
            aprobacionPendiente = nil
            anterior.resume(returning: false)
        }

        return await withCheckedContinuation { continuacion in
            continuacionAprobacion = continuacion
            aprobacionPendiente = AprobacionPendiente(llamada: llamada)
        }
    }

    /// Cierra la aprobacion pendiente con la decision del usuario.
    ///
    /// Tambien limpia el estado que pinta la hoja, de modo que la vista se
    /// cierra sola. Sin continuacion pendiente solo se limpia la hoja.
    func resolverAprobacion(_ aprobada: Bool) {
        guard let continuacion = continuacionAprobacion else {
            aprobacionPendiente = nil
            return
        }

        continuacionAprobacion = nil
        aprobacionPendiente = nil
        continuacion.resume(returning: aprobada)
    }

    func cancelar() {
        tareaActual?.cancel()
        tareaActual = nil
        tareaCompactado?.cancel()
        tareaCompactado = nil
        generacionCompactado = UUID()
        compactando = false
        if continuacionAprobacion != nil {
            resolverAprobacion(false)
        }
        aprobacionPendiente = nil
        herramientaEnCurso = nil
        enviando = false
        textoEnCurso = ""
    }

    /// Historial que se manda al modelo: el prompt de sistema primero.
    ///
    /// La regla vive en NodoCore para poder probarla con `swift test`: en un
    /// chat sin memoria el prompt no se inyecta (§4.6). Los eventos visuales no
    /// forman parte de `conversacion.mensajes`, asi que jamas entran aqui.
    private func historialParaEnviar() -> [ChatMessage] {
        Historial.paraEnviar(
            conversacion: conversacion,
            promptSistema: config.systemPrompt
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

    /// Herramientas disponibles: la de red siempre, y las del servidor si esta
    /// configurado y responde.
    ///
    /// Se descubren al vuelo, antes de enviar, porque el modelo necesita los
    /// nombres y argumentos reales para poder usarlas. Si el servidor no
    /// responde se sigue sin ellas: conversar no debe depender de el.
    private func herramientasDisponibles() async -> [Herramienta] {
        // La costura de capturas devuelve una unica herramienta con
        // consecuencias, para que la hoja de aprobacion y el paso en vivo sean
        // deterministas y no dependan de la red.
        if estadoDePrueba != nil {
            return [HerramientaDePrueba()]
        }

        var lista: [Herramienta] = [HttpFetchTool(transporte: transporte)]

        guard config.servidor.estaConfigurado,
              let cliente = try? MCPClient(
                  transporte: transporte,
                  config: config.servidor,
                  token: tokenServidor
              )
        else {
            return lista
        }

        do {
            _ = try await cliente.inicializar()
            let remotas = try await cliente.listarHerramientas()
            lista.append(contentsOf: remotas.map {
                HerramientaMCP(cliente: cliente, definicion: $0)
            })
        } catch {
            // Sin servidor se sigue igual; no es un error que deba cortar el chat.
        }

        return lista
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
