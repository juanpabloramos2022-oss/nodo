import Foundation
import SwiftUI

import NodoCore

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
    /// En modo capturas no se escribe nada en el almacenamiento del telefono:
    /// el estado llega sembrado en memoria y las capturas no deben ensuciar
    /// los datos de quien use la app de verdad.
    private let persistir: Bool
    private let transporte = TransporteURLSession()
    private var store: ConversationStore?
    private var tareaActual: Task<Void, Never>?
    /// La carga inicial del diccionario no debe escribir nada: se activa al
    /// terminar el init normal y se queda apagada en modo de prueba.
    private var puedeGuardarVentanas = false

    private static let claveConfig = "nodo.config.v1"
    private static let claveVentanas = "nodo.ventanas.v1"

    init(llavero: AlmacenClaves = LlaveroAlmacen(), estadoDePrueba: EstadoPrueba? = nil) {
        self.llavero = llavero
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
            }
        } catch {
            self.error = error.localizedDescription
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

    func nuevaConversacion() {
        cancelar()
        conversacion = Conversation()
    }

    func abrir(_ otra: Conversation) {
        cancelar()
        conversacion = otra
    }

    func borrar(_ otra: Conversation) {
        try? store?.borrar(id: otra.id)
        if conversacion.id == otra.id {
            conversacion = Conversation()
        }
        recargarConversaciones()
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
        recargarConversaciones()
    }

    func desarchivar(_ otra: Conversation) {
        archivar(otra, archivada: false)
    }

    private func persistirActual() {
        conversacion.actualizada = Date()
        try? store?.guardar(conversacion)
        recargarConversaciones()
    }

    // MARK: - Envio

    /// Manda el mensaje y va pintando la respuesta segun llega.
    func enviar(_ texto: String) {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty, !enviando else { return }

        if let problema = problemaDeConfiguracion() {
            error = problema
            return
        }

        guard let proveedor = config.proveedorSeleccionado,
              let clave = clave(para: proveedor)
        else {
            error = "Falta la configuracion del proveedor."
            return
        }

        conversacion.mensajes.append(ChatMessage(rol: .usuario, texto: limpio))
        if conversacion.titulo == "Conversacion" {
            conversacion.titulo = conversacion.tituloSugerido
        }
        persistirActual()

        enviando = true
        textoEnCurso = ""
        error = nil

        let historial = historialParaEnviar()

        tareaActual = Task { [weak self] in
            guard let self else { return }

            await self.ejecutarTurno(
                proveedor: proveedor,
                clave: clave,
                historial: historial,
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

        if let problema = problemaDeConfiguracion() {
            error = problema
            return
        }

        guard let proveedor = config.proveedorSeleccionado,
              let clave = clave(para: proveedor)
        else {
            error = "Falta la configuracion del proveedor."
            return
        }

        let turnoDescartado = conversacion.descartarUltimoTurno()
        guard !turnoDescartado.isEmpty else { return }
        persistirActual()

        enviando = true
        textoEnCurso = ""
        error = nil

        let historial = historialParaEnviar()

        tareaActual = Task { [weak self] in
            guard let self else { return }

            await self.ejecutarTurno(
                proveedor: proveedor,
                clave: clave,
                historial: historial,
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
        alFracasar: () -> Void
    ) async {
        do {
            let motor = motorPara(proveedor: proveedor, clave: clave)
            let herramientas = await herramientasDisponibles()
            let bucle = ToolLoop(motor: motor, herramientas: herramientas)

            let resultado = try await bucle.ejecutar(
                historial: historial,
                alRecibirTexto: { fragmento in
                    Task { @MainActor [weak self] in
                        if let self { self.textoEnCurso += fragmento }
                    }
                }
            )

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
        enviando = false
        textoEnCurso = ""
    }

    /// Historial que se manda al modelo: el prompt de sistema primero.
    ///
    /// No se guarda dentro de la conversacion a proposito, para que cambiarlo en
    /// ajustes afecte tambien a las conversaciones ya abiertas.
    private func historialParaEnviar() -> [ChatMessage] {
        var historial: [ChatMessage] = []
        let prompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            historial.append(ChatMessage(rol: .sistema, texto: prompt))
        }
        historial.append(contentsOf: conversacion.mensajes)
        return historial
    }

    private func motorPara(proveedor: ProviderConfig, clave: String) -> ChatEngine {
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
