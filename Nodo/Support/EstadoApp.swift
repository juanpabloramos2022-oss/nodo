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

    private let llavero: AlmacenClaves
    private let transporte = TransporteURLSession()
    private var store: ConversationStore?
    private var tareaActual: Task<Void, Never>?

    private static let claveConfig = "nodo.config.v1"

    init(llavero: AlmacenClaves = LlaveroAlmacen()) {
        self.llavero = llavero

        if let datos = UserDefaults.standard.data(forKey: Self.claveConfig),
           let cargada = try? AppConfig.desde(json: datos) {
            self.config = cargada
        } else {
            self.config = .inicial()
        }

        self.conversacion = Conversation()

        var almacen: ConversationStore?
        do {
            let directorio = try ConversationStore.directorioPorDefecto()
            almacen = try ConversationStore(directorio: directorio)
        } catch {
            self.error = "No se pudo abrir el almacen de conversaciones."
        }
        self.store = almacen
        self.conversaciones = almacen?.listar() ?? []
    }

    // MARK: - Configuracion

    private func guardarConfig() {
        guard let datos = try? config.json() else { return }
        UserDefaults.standard.set(datos, forKey: Self.claveConfig)
    }

    func clave(para proveedor: ProviderConfig) -> String? {
        llavero.leer(proveedor.claveKeychain)
    }

    func guardarClave(_ clave: String, para proveedor: ProviderConfig) {
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
        llavero.leer(ServerConfig.tokenKeychain)
    }

    func guardarTokenServidor(_ token: String) {
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

    func anadirProveedor() {
        let nuevo = ProviderConfig(
            nombre: "Proveedor",
            protocolo: .chatCompletions,
            baseURL: "https://",
            modelo: ""
        )
        config.proveedores.append(nuevo)
        config.proveedorActivo = nuevo.id
    }

    func actualizarProveedor(_ proveedor: ProviderConfig) {
        guard let indice = config.proveedores.firstIndex(where: { $0.id == proveedor.id }) else {
            return
        }
        config.proveedores[indice] = proveedor
    }

    func borrarProveedor(_ proveedor: ProviderConfig) {
        config.proveedores.removeAll { $0.id == proveedor.id }
        try? llavero.borrar(proveedor.claveKeychain)

        if config.proveedorActivo == proveedor.id {
            config.proveedorActivo = config.proveedores.first?.id
        }
    }

    // MARK: - Conversaciones

    func recargarConversaciones() {
        conversaciones = store?.listar() ?? []
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
            persistirActual()

            if resultado.seAgotoElLimite {
                error = "Se alcanzo el limite de \(bucle.maxIteraciones) vueltas de herramientas."
            }
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
