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
        didSet { guardarConfig() }
    }

    @Published private(set) var conversaciones: [Conversation] = []
    @Published var conversacion: Conversation
    @Published private(set) var enviando = false
    @Published private(set) var textoEnCurso = ""
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

    /// Ventana de contexto de cada modelo, en tokens.
    ///
    /// La clave es el identificador crudo del modelo (`vendedor/modelo`), no el
    /// nombre limpio: asi la tabla sigue valiendo aunque cambie como se pinta.
    /// Vive fuera de `AppConfig` a proposito, porque el formato exportable de
    /// la configuracion no cambia en esta tarea.
    @Published var ventanasPorModelo: [String: Int] = [:] {
        didSet { guardarVentanas() }
    }

    private let llavero: AlmacenClaves
    /// Estado sembrado por `-CapturasPrueba`, o nil en un arranque normal.
    /// Ademas de no persistir, activa el motor y la herramienta deterministas.
    private let estadoDePrueba: EstadoPrueba?
    /// En modo capturas no se escribe nada en el almacenamiento del telefono:
    /// el estado llega sembrado en memoria y las capturas no deben ensuciar
    /// los datos de quien use la app de verdad.
    private let persistir: Bool
    private let transporte = TransporteURLSession()
    private var store: ConversationStore?
    private var tareaActual: Task<Void, Never>?
    /// Continuacion que mantiene el turno suspendido mientras la hoja de
    /// aprobacion espera. Se resuelve una sola vez por aprobacion.
    private var continuacionAprobacion: CheckedContinuation<Bool, Never>?
    /// La carga inicial del diccionario no debe escribir nada: se activa al
    /// terminar el init normal y se queda apagada en modo de prueba.
    private var puedeGuardarVentanas = false

    private static let claveConfig = "nodo.config.v1"
    private static let claveVentanas = "nodo.ventanas.v1"

    init(llavero: AlmacenClaves = LlaveroAlmacen(), estadoDePrueba: EstadoPrueba? = nil) {
        self.llavero = llavero
        self.estadoDePrueba = estadoDePrueba
        self.persistir = estadoDePrueba == nil

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
            return
        }

        if let datos = UserDefaults.standard.data(forKey: Self.claveConfig),
           let cargada = try? AppConfig.desde(json: datos) {
            self.config = cargada
        } else {
            self.config = .inicial()
        }

        self.conversacion = Conversation()
        self.ventanasPorModelo = Self.ventanasGuardadas()

        var almacen: ConversationStore?
        do {
            let directorio = try ConversationStore.directorioPorDefecto()
            almacen = try ConversationStore(directorio: directorio)
        } catch {
            self.error = "No se pudo abrir el almacen de conversaciones."
        }
        self.store = almacen
        self.conversaciones = almacen?.listar() ?? []
        self.puedeGuardarVentanas = true
    }

    // MARK: - Configuracion

    private func guardarConfig() {
        guard persistir, let datos = try? config.json() else { return }
        UserDefaults.standard.set(datos, forKey: Self.claveConfig)
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
        UserDefaults.standard.set(datos, forKey: Self.claveVentanas)
    }

    private static func ventanasGuardadas() -> [String: Int] {
        guard let datos = UserDefaults.standard.data(forKey: claveVentanas),
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

    /// El identificador crudo se recorta, pero no se transforma: la tabla debe
    /// seguir apuntando al mismo modelo que envia el proveedor.
    private static func claveDeModelo(_ modelo: String) -> String {
        modelo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clave(para proveedor: ProviderConfig) -> String? {
        guard persistir else { return nil }
        return llavero.leer(proveedor.claveKeychain)
    }

    func guardarClave(_ clave: String, para proveedor: ProviderConfig) {
        guard persistir else { return }
        let limpia = clave.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if limpia.isEmpty {
                try llavero.borrar(proveedor.claveKeychain)
            } else {
                try llavero.guardar(limpia, para: proveedor.claveKeychain)
                propagarClave(limpia, desde: proveedor)
            }
        } catch {
            self.error = error.localizedDescription
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
        conversacion = Conversation(sinMemoria: sinMemoria)
    }

    func abrir(_ otra: Conversation) {
        cancelar()
        limpiarEventosVisuales()
        conversacion = otra
    }

    func borrar(_ otra: Conversation) {
        if conversacion.id == otra.id {
            cancelar()
        }
        try? store?.borrar(id: otra.id)
        if conversacion.id == otra.id {
            limpiarEventosVisuales()
            conversacion = Conversation()
        }
        recargarConversaciones()
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

    private func registrarEventoVisual(_ texto: String, tras mensaje: UUID?) {
        eventosVisuales.append(EventoVisual(trasMensaje: mensaje, texto: texto))
    }

    func renombrar(_ otra: Conversation, titulo: String) {
        var copia = otra
        copia.titulo = titulo
        try? store?.guardar(copia)
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

    /// Manda el mensaje y va pintando la respuesta segun llega.
    func enviar(_ texto: String) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, !enviando else { return }

        guard let (proveedor, clave) = proveedorYClaveParaEnviar() else { return }

        conversacion.mensajes.append(ChatMessage(rol: .usuario, texto: limpio))
        if conversacion.titulo == "Conversacion" {
            conversacion.titulo = conversacion.tituloSugerido
        }
        persistirActual()

        enviando = true
        textoEnCurso = ""
        herramientaEnCurso = nil
        aprobacionPendiente = nil
        error = nil

        let historial = historialParaEnviar()
        let modoTarea = conversacion.modoTarea

        tareaActual = Task { [weak self] in
            guard let self else { return }

            await self.ejecutarTurno(
                proveedor: proveedor,
                clave: clave,
                historial: historial,
                modoTarea: modoTarea,
                alFracasar: {}
            )

            self.enviando = false
            self.tareaActual = nil
        }
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

        let turnoDescartado = conversacion.descartarUltimoTurno()
        guard !turnoDescartado.isEmpty else { return }
        persistirActual()

        enviando = true
        textoEnCurso = ""
        herramientaEnCurso = nil
        aprobacionPendiente = nil
        error = nil

        let historial = historialParaEnviar()
        let modoTarea = conversacion.modoTarea

        tareaActual = Task { [weak self] in
            guard let self else { return }

            await self.ejecutarTurno(
                proveedor: proveedor,
                clave: clave,
                historial: historial,
                modoTarea: modoTarea,
                alFracasar: {
                    self.conversacion.mensajes.append(contentsOf: turnoDescartado)
                }
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
    /// error.
    private func ejecutarTurno(
        proveedor: ProviderConfig,
        clave: String,
        historial: [ChatMessage],
        modoTarea: Bool,
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

            // Si el usuario pulso Detener mientras esperaba una aprobacion o
            // una herramienta, el turno no se publica aunque el bucle haya
            // alcanzado a devolver un resultado.
            try Task.checkCancellation()

            textoEnCurso = ""
            conversacion.mensajes.append(contentsOf: resultado.mensajesNuevos)

            if resultado.seAgotoElLimite {
                error = "Se alcanzo el limite de \(bucle.maxIteraciones) vueltas de herramientas."
            }

            revisarAvisoCosto(proveedor: proveedor)
            persistirActual()
        } catch is CancellationError {
            textoEnCurso = ""
            alFracasar()
            persistirActual()
        } catch let fallo {
            textoEnCurso = ""
            alFracasar()
            self.error = (fallo as? LocalizedError)?.errorDescription
                ?? fallo.localizedDescription
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

    /// Avisa una sola vez si el acumulado estimado del chat cruzo el tope.
    ///
    /// Se calcula con los precios del proveedor que acaba de responder y solo
    /// despues de un turno nuevo: abrir un chat viejo no dispara el aviso.
    private func revisarAvisoCosto(proveedor: ProviderConfig) {
        guard !conversacion.avisoCostoMostrado else { return }
        guard error == nil else { return }

        guard let costo = CostoEstimado.acumulado(
            mensajes: conversacion.mensajes,
            precioEntrada: proveedor.precioEntradaPorMillon,
            precioSalida: proveedor.precioSalidaPorMillon
        ) else {
            return
        }

        let tope = config.topeAvisoCostoEfectivo
        guard tope > 0, costo >= tope else { return }

        conversacion.avisoCostoMostrado = true
        error = "Este chat ya paso de $\(String(format: "%.2f", tope)) estimados"
    }

    func cancelar() {
        tareaActual?.cancel()
        tareaActual = nil
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
        if estadoDePrueba != nil {
            return MotorDePrueba()
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

    func exportarConfig() -> String? {
        guard let datos = try? config.json() else { return nil }
        return String(data: datos, encoding: .utf8)
    }

    func importarConfig(_ texto: String) -> Bool {
        guard let datos = texto.data(using: .utf8),
              let nueva = try? AppConfig.desde(json: datos)
        else {
            error = "El texto no es una configuracion valida."
            return false
        }
        config = nueva
        return true
    }
}
