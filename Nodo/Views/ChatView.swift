import Foundation
import SwiftUI

import NodoCore

/// La pantalla de conversacion, empujada dentro de la pila de Chats.
///
/// La cabecera se construye con el `.toolbar` nativo de NavigationStack: el
/// boton de volver lo pone el sistema y por eso el gesto de borde izquierdo
/// sigue funcionando (ley n. 1). Solo hay tres elementos: volver, pildora y •••.
struct ChatView: View {
    @EnvironmentObject private var estado: EstadoApp

    /// Lleva a la pestana Conexiones para gestionar modelos.
    let alGestionarModelos: () -> Void
    /// Vuelve a la lista cuando se borra el chat abierto.
    let alVolverALista: () -> Void

    @State private var dictando = false
    @State private var textoAntesDeDictar = ""
    @State private var textoParaCompartir: String?
    @FocusState private var escribiendo: Bool
    @State private var mostrarEstadoChat = false
    @State private var mostrarMemoriaRapida = false
    @State private var confirmarBorrado = false

    var body: some View {
        VStack(spacing: 0) {
            contenido

            if let error = estado.error {
                AvisoError(texto: error) { estado.error = nil }
                    .padding(.bottom, 8)
            }

            franjaTope
            tiraFina
            filaCompactando
            franjaAvisoComando
            selectorSugerencias
            barraDeEntrada
        }
        .background(Tema.fondo.ignoresSafeArea())
        .navigationTitle(estado.conversacion.titulo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                pildora
            }
            ToolbarItem(placement: .topBarTrailing) {
                menuAcciones
            }
        }
        // Al entrar en una conversacion las pestanas se ocultan; la cabecera
        // nativa queda clavada y el gesto de borde sigue disponible.
        .toolbar(.hidden, for: .tabBar)
        // La barra Listo no se hereda de la raiz de la pila: cada pantalla
        // activa declara la suya. Aqui cubre la caja de texto del chat.
        .conBarraTecladoListo()
        // Volver (boton o gesto) cierra el teclado y corta el dictado.
        .onDisappear {
            detenerDictado()
            bajarTeclado()
        }
        .onChange(of: estado.textoParaCompartirSolicitado) { _, nuevo in
            guard let nuevo else { return }
            textoParaCompartir = nuevo
        }
        .sheet(isPresented: $mostrarEstadoChat) {
            HojaEstadoChatView()
        }
        .sheet(isPresented: $mostrarMemoriaRapida) {
            HojaMemoriaRapidaView()
        }
        .sheet(isPresented: $estado.mostrarHojaModelos) {
            HojaModelosView(alGestionarModelos: alGestionarModelos)
        }
        .sheet(isPresented: Binding(
            get: { textoParaCompartir != nil },
            set: { presentado in
                if !presentado {
                    textoParaCompartir = nil
                    estado.textoParaCompartirSolicitado = nil
                }
            }
        )) {
            HojaCompartir(texto: textoParaCompartir ?? "")
        }
        .confirmationDialog(
            "Borrar esta conversacion?",
            isPresented: $confirmarBorrado,
            titleVisibility: .visible
        ) {
            Button("Borrar", role: .destructive) { borrar() }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // MARK: - Cabecera: pildora central

    /// Pildora con el modelo activo y su subtitulo.
    ///
    /// Toque 1 abre el menu nativo; toque 2 elige otro modelo sin salir de la
    /// conversacion ni perder lo escrito (SPEC §3.2).
    private var pildora: some View {
        Menu {
            listaModelos(
                proveedores: estado.config.proveedores,
                activo: estado.config.proveedorSeleccionado?.id,
                alElegir: { estado.cambiarProveedor($0) },
                alGestionar: alGestionarModelos
            )
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(modeloLimpio)
                        .font(.footnote.weight(.bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }

                HStack(spacing: 4) {
                    Text(subtituloPildora)
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(1)
                    indicadorMemoria
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 200)
        }
        .accessibilityLabel("Modelo \(modeloLimpio). \(proveedorLimpio)")
        .accessibilityHint("Abre el menu para cambiar de modelo")
        .accessibilityIdentifier("pildora-modelo")
    }

    /// 🧠 con punto verde solo cuando la Memoria tiene texto y el chat la usa.
    ///
    /// El 🧠 se queda visible tambien en un chat sin memoria; lo que desaparece
    /// es el punto verde, que es la senal de que la Memoria se esta inyectando
    /// (§4.6).
    private var indicadorMemoria: some View {
        HStack(spacing: 2) {
            Text("🧠")
                .font(.caption2)
            if memoriaActiva {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var modeloLimpio: String {
        guard let proveedor = estado.config.proveedorSeleccionado else {
            return "Sin modelo"
        }
        let limpio = NombresLimpios.modelo(proveedor.modelo)
        return limpio.isEmpty ? "Sin modelo" : limpio
    }

    private var proveedorLimpio: String {
        guard let proveedor = estado.config.proveedorSeleccionado else {
            return "Sin proveedor"
        }
        return NombresLimpios.proveedor(
            nombre: proveedor.nombre,
            baseURL: proveedor.baseURL
        )
    }

    /// Subtitulo de la pildora: proveedor · costo acumulado (si hay precios).
    private var subtituloPildora: String {
        var partes = [proveedorLimpio]
        if let costo = costoAcumulado {
            // En la pildora la cifra va compacta; el detalle con "estimado"
            // sigue estando en el resumen y en el pie de cada respuesta.
            partes.append("≈$\(String(format: "%.4f", costo))")
        }
        return partes.joined(separator: " · ")
    }

    private var memoriaActiva: Bool {
        !estado.conversacion.sinMemoria
            && !estado.textoMemoria
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    private var costoAcumulado: Double? {
        estado.costoAcumuladoDelChat
    }

    private func nombreDeModelo(_ proveedor: ProviderConfig) -> String {
        let limpio = NombresLimpios.modelo(proveedor.modelo)
        guard limpio.isEmpty else { return limpio }
        return NombresLimpios.proveedor(
            nombre: proveedor.nombre,
            baseURL: proveedor.baseURL
        )
    }

    private func esActivo(_ proveedor: ProviderConfig) -> Bool {
        estado.config.proveedorSeleccionado?.id == proveedor.id
    }

    // MARK: - Cabecera: menu •••

    /// Menu de acciones con solo lo que existe en esta fase.
    private var menuAcciones: some View {
        Menu {
            Button {
                mostrarEstadoChat = true
            } label: {
                Label("Estado del chat", systemImage: "chart.bar.xaxis")
            }

            Button {
                alternarFijado()
            } label: {
                Label(
                    estado.conversacion.fijada ? "Desfijar" : "Fijar",
                    systemImage: estado.conversacion.fijada ? "pin.slash" : "pin"
                )
            }

            Button {
                estado.archivar(estado.conversacion)
            } label: {
                Label("Archivar", systemImage: "archivebox")
            }

            Button {
                estado.alternarSinMemoria()
            } label: {
                if estado.conversacion.sinMemoria {
                    Label("Chat sin memoria", systemImage: "checkmark")
                } else {
                    Text("Chat sin memoria")
                }
            }

            Button {
                estado.compactar()
            } label: {
                Label("Compactar", systemImage: "rectangle.compress.vertical")
            }
            // Compactar entra al menu en esta fase, pero solo cuando el hilo
            // ya tiene suficiente historial (§4.2).
            .disabled(
                estado.conversacion.mensajes.count < 6
                    || estado.compactando
                    || estado.enviando
            )

            Divider()

            Button(role: .destructive) {
                confirmarBorrado = true
            } label: {
                Label("Borrar", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel("Mas acciones del chat")
        .accessibilityIdentifier("menu-chat")
    }

    private func alternarFijado() {
        if estado.conversacion.fijada {
            estado.desfijar(estado.conversacion)
        } else {
            estado.fijar(estado.conversacion)
        }
    }

    private func borrar() {
        // Primero se sale de la pila y despues se borra: la ruta no llega a
        // apuntar a una conversacion que ya no existe.
        let conversacion = estado.conversacion
        alVolverALista()
        estado.borrar(conversacion)
    }

    // MARK: - Hilo

    /// Una fila del hilo: un mensaje real o un evento puramente visual.
    private enum FilaHilo: Identifiable {
        case mensaje(ChatMessage)
        case evento(EventoVisual)

        var id: String {
            switch self {
            case .mensaje(let mensaje):
                return "mensaje-\(mensaje.id.uuidString)"
            case .evento(let evento):
                return "evento-\(evento.id.uuidString)"
            }
        }
    }

    /// Mensajes con los divisores intercalados en su punto exacto.
    ///
    /// Los eventos se guardan aparte de `mensajes`, asi que esta mezcla es solo
    /// de pintado: el payload sigue construyendose con `Historial` (SPEC §2.6).
    private var filas: [FilaHilo] {
        let mensajes = estado.conversacion.mensajes
        let ids = Set(mensajes.map(\.id))
        var resultado: [FilaHilo] = []

        resultado.append(
            contentsOf: estado.eventosVisuales
                .filter { $0.trasMensaje == nil }
                .map(FilaHilo.evento)
        )

        for mensaje in mensajes {
            resultado.append(.mensaje(mensaje))
            resultado.append(
                contentsOf: estado.eventosVisuales
                    .filter { $0.trasMensaje == mensaje.id }
                    .map(FilaHilo.evento)
            )
        }

        // Un evento cuyo ancla desaparecio (por ejemplo, al regenerar) no se
        // pierde: se pinta al final para no ocultar informacion.
        let huerfanos = estado.eventosVisuales.filter { evento in
            guard let ancla = evento.trasMensaje else { return false }
            return !ids.contains(ancla)
        }
        resultado.append(contentsOf: huerfanos.map(FilaHilo.evento))

        return resultado
    }

    @ViewBuilder
    private var contenido: some View {
        if estado.conversacion.mensajes.isEmpty
            && estado.eventosVisuales.isEmpty
            && !estado.enviando {
            // La Tarjeta de Bienvenida sustituye al estado vacio generico y se
            // alimenta solo de la configuracion real (§3.2).
            TarjetaBienvenidaView(
                alEmpezar: { escribiendo = true },
                alEditarMemoria: { mostrarMemoriaRapida = true },
                alGestionarModelos: alGestionarModelos
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filas) { fila in
                            filaDeHilo(fila)
                                .id(fila.id)
                        }

                        if estado.enviando {
                            BurbujaEnCurso(texto: estado.textoEnCurso)
                                .id(Self.marcaEnCurso)
                        }

                        if !estado.enviando, let error = estado.errorDeTurno {
                            BurbujaErrorTurno(
                                texto: error,
                                otrosProveedores: otrosProveedores,
                                nombreDeProveedor: { nombreDeModelo($0) },
                                alReintentar: { estado.reintentar() },
                                alCambiarModelo: { proveedor in
                                    estado.cambiarProveedor(proveedor)
                                    estado.reintentar()
                                }
                            )
                            .id(Self.marcaError)
                        }
                    }
                    .padding(.horizontal, Tema.margen)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: estado.conversacion.mensajes.count) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onChange(of: estado.eventosVisuales.count) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onChange(of: estado.textoEnCurso) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onChange(of: estado.enviando) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onChange(of: estado.errorDeTurno) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onAppear { desplazarAlFinal(proxy) }
            }
        }
    }

    @ViewBuilder
    private func filaDeHilo(_ fila: FilaHilo) -> some View {
        switch fila {
        case .mensaje(let mensaje):
            filaDeMensajeNormal(mensaje)

        case .evento(let evento):
            Text(evento.texto)
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .accessibilityLabel(evento.texto)
        }
    }

    @ViewBuilder
    private func filaDeMensajeNormal(_ mensaje: ChatMessage) -> some View {
        BurbujaMensaje(
            mensaje: mensaje,
            pie: pieDe(mensaje),
            alRamificar: accionRamificar(mensaje)
        )
    }

    /// La pulsacion larga de una burbuja de usuario o asistente ofrece
    /// "Ramificar chat desde aqui" (§5.4). Las burbujas internas de
    /// herramienta no son un punto de corte util.
    private func accionRamificar(_ mensaje: ChatMessage) -> (() -> Void)? {
        guard mensaje.rol == .usuario || mensaje.rol == .asistente else {
            return nil
        }
        return { estado.ramificar(desde: mensaje) }
    }

    private static let marcaEnCurso = "nodo-en-curso"
    private static let marcaError = "nodo-error-turno"

    private func desplazarAlFinal(_ proxy: ScrollViewProxy) {
        let destino: String?
        if estado.enviando {
            destino = Self.marcaEnCurso
        } else if estado.errorDeTurno != nil {
            destino = Self.marcaError
        } else {
            destino = filas.last?.id
        }

        guard let destino else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(destino, anchor: .bottom)
        }
    }

    // MARK: - Consumo y pie de respuesta

    /// Pie de la respuesta: se pinta bajo TODAS las respuestas del asistente
    /// con consumo. La parte informativa y Copiar van en todas; el boton de
    /// regenerar solo en la ultima, porque regenerar actua sobre ella.
    private func pieDe(_ mensaje: ChatMessage) -> PieRespuesta? {
        guard mensaje.rol == .asistente, let uso = mensaje.uso else { return nil }

        return PieRespuesta(
            uso: uso,
            costo: costoDe(mensaje),
            textoParaCopiar: mensaje.texto,
            puedeRegenerar: esUltimaRespuesta(mensaje) && !estado.enviando,
            otrosProveedores: otrosProveedores,
            nombreDeProveedor: { nombreDeModelo($0) },
            alRegenerar: { estado.regenerar() },
            alRegenerarCon: { estado.regenerarCon(proveedorID: $0.id) }
        )
    }

    /// Regenerar actua siempre sobre la ultima respuesta del hilo; por eso el
    /// pie de las respuestas anteriores no ofrece el boton.
    private func esUltimaRespuesta(_ mensaje: ChatMessage) -> Bool {
        estado.conversacion.mensajes.last?.id == mensaje.id
    }

    /// Los demas modelos configurados, para "Regenerar con…" y "Cambiar modelo".
    private var otrosProveedores: [ProviderConfig] {
        estado.config.proveedores.filter { !esActivo($0) }
    }

    /// Costo con el proveedor que genero ESTE mensaje, no con el activo.
    private func costoDe(_ mensaje: ChatMessage) -> Double? {
        estado.costo(de: mensaje)
    }

    // MARK: - Tira fina y caja de texto

    /// Franja ámbar de tope, justo sobre la tira fina y la caja (§3.3).
    ///
    /// "Subir tope" solo ofrece escalones POR ENCIMA del actual (máximo 4) y
    /// actualiza el tope global; "Seguir igual" silencia solo este chat.
    @ViewBuilder
    private var franjaTope: some View {
        if estado.topeSuperado {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)

                    Text("Este chat ya supera tu tope de aviso ($\(textoTopeActual))")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Menu {
                        ForEach(escalonesDeTope, id: \.self) { valor in
                            Button("$\(String(format: "%.2f", valor))") {
                                estado.fijarTopeAviso(valor)
                            }
                        }
                    } label: {
                        Text("Subir tope")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.25))
                            .clipShape(Capsule())
                    }
                    .disabled(escalonesDeTope.isEmpty)
                    .accessibilityIdentifier("subir-tope")

                    Button {
                        estado.ignorarTopeEnEsteChat()
                    } label: {
                        Text("Seguir igual")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Tema.superficieAlta)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("seguir-igual")
                }
            }
            .padding(.horizontal, Tema.margen)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.14))
            .accessibilityIdentifier("franja-tope")
        }
    }

    private var textoTopeActual: String {
        String(format: "%.2f", estado.config.topeAvisoCostoEfectivo)
    }

    /// Escalera de topes por encima del vigente, recortada a 4 opciones.
    private var escalonesDeTope: [Double] {
        let actual = estado.config.topeAvisoCostoEfectivo
        let escalera: [Double] = [0.25, 0.50, 1.00, 2.00, 5.00, 10.00]
        return Array(escalera.filter { $0 > actual + 0.000_000_1 }.prefix(4))
    }

    /// Fila fina sobre la caja: solo el acceso rapido a la Memoria.
    ///
    /// El conmutador Chat | Tarea se demolió: todos los chats son normales y
    /// no ofrecen herramientas, asi que no queda ningun modo que elegir.
    private var tiraFina: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            Button {
                mostrarMemoriaRapida = true
            } label: {
                HStack(spacing: 3) {
                    Text("🧠")
                    if memoriaActiva {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Tema.superficie)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                memoriaActiva
                    ? "Memoria activa en este chat"
                    : "Memoria apagada en este chat"
            )
            .accessibilityHint("Edita la Memoria sin salir de la conversacion")
            .accessibilityIdentifier("memoria-rapida")
        }
        .padding(.horizontal, Tema.margen)
        .padding(.top, 6)
    }

    /// Mientras /compact pide el resumen, la caja queda bloqueada y se dice.
    @ViewBuilder
    private var filaCompactando: some View {
        if estado.compactando {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Compactando…")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tema.margen)
            .padding(.top, 6)
            .accessibilityIdentifier("compactando")
        }
    }

    /// Aviso pequeno del parser: superficie alta y sin botones, distinto de la
    /// franja ambar de tope. Se limpia al editar o al enviar con exito.
    @ViewBuilder
    private var franjaAvisoComando: some View {
        if let aviso = estado.avisoComando {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)

                Text(aviso)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Tema.superficieAlta)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, Tema.margen)
            .padding(.top, 6)
            .accessibilityIdentifier("aviso-comando")
        }
    }

    // MARK: - Selector flotante de "/"

    /// Una fila del selector: un comando integrado o una skill resuelta.
    private enum Sugerencia: Identifiable {
        case comando(ComandoIntegrado)
        case skill(SkillResuelta)

        var id: String {
            switch self {
            case .comando(let comando):
                return "comando-\(comando.rawValue)"
            case .skill(let skill):
                return "skill-\(skill.slug)"
            }
        }
    }

    /// Lo tecleado en el primer token, o nil si ya no toca mostrar el selector.
    ///
    /// Basta con que aparezca un espacio: el usuario ya esta escribiendo el
    /// mensaje y la lista dejaria de ser util.
    private var consultaSelector: String? {
        let sinIzquierda = estado.borrador.drop(while: { $0.isWhitespace })
        guard sinIzquierda.hasPrefix("/") else { return nil }

        let cuerpo = sinIzquierda.dropFirst()
        guard !cuerpo.contains(where: { $0.isWhitespace }) else { return nil }
        return String(cuerpo)
    }

    /// Skills primero y comandos abajo, como pide §4.2, con tope de 6 filas.
    private var sugerencias: [Sugerencia] {
        guard let consulta = consultaSelector,
              !estado.enviando,
              !estado.compactando
        else {
            return []
        }

        let buscado = AnalizadorComandos.normalizarSlug(consulta)
        let comandos = ComandoIntegrado.allCases.filter { comando in
            buscado.isEmpty || comando.rawValue.hasPrefix(buscado)
        }
        let skills = estado.skillsParaSelector(consulta).map(Sugerencia.skill)

        return Array(
            (skills + comandos.map(Sugerencia.comando)).prefix(6)
        )
    }

    @ViewBuilder
    private var selectorSugerencias: some View {
        let lista = sugerencias

        if !lista.isEmpty {
            VStack(spacing: 0) {
                ForEach(lista) { sugerencia in
                    Button {
                        elegir(sugerencia)
                    } label: {
                        HStack(spacing: 6) {
                            Text(textoDe(sugerencia))
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sugerencia-\(sugerencia.id)")

                    if sugerencia.id != lista.last?.id {
                        Divider()
                            .overlay(Tema.borde)
                    }
                }
            }
            .background(Tema.superficieAlta)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, Tema.margen)
            .padding(.top, 6)
            .accessibilityIdentifier("selector-sugerencias")
        }
    }

    private func textoDe(_ sugerencia: Sugerencia) -> String {
        switch sugerencia {
        case .comando(let comando):
            return "/\(comando.rawValue) — \(descripcionDe(comando))"
        case .skill(let skill):
            return "⚡ /\(skill.slug) — \(skill.nombre)"
        }
    }

    private func descripcionDe(_ comando: ComandoIntegrado) -> String {
        switch comando {
        case .compact:
            return "Resume la conversación y conserva lo último."
        case .costo:
            return "Muestra tokens y costo de este chat."
        case .modelos:
            return "Cambia el modelo activo."
        case .nuevo:
            return "Crea una conversación nueva."
        case .exportar:
            return "Comparte esta conversación como texto."
        }
    }

    /// Los integrados se ejecutan al tocarlos porque no llevan texto; una skill
    /// solo completa el borrador y espera el mensaje.
    private func elegir(_ sugerencia: Sugerencia) {
        switch sugerencia {
        case .comando(let comando):
            estado.borrador = "/\(comando.rawValue)"
            estado.avisoComando = nil
            estado.enviarTextoActual()

        case .skill(let skill):
            estado.borrador = "/\(skill.slug) "
            estado.avisoComando = nil
            escribiendo = true
        }
    }

    // MARK: - Caja de texto

    /// El borrador vive en EstadoApp: los comandos y el dictado lo comparten.
    private var enlaceBorrador: Binding<String> {
        Binding(
            get: { estado.borrador },
            set: { nuevo in
                estado.borrador = nuevo
                estado.avisoComando = nil
            }
        )
    }

    private var placeholderCaja: String {
        estado.compactando ? "Compactando…" : "Escribe un mensaje"
    }

    private var barraDeEntrada: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                placeholderCaja,
                text: enlaceBorrador,
                axis: .vertical
            )
            .lineLimit(1...5)
            .focused($escribiendo)
            .disabled(estado.compactando)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .foregroundStyle(.white)
            .accessibilityIdentifier("caja-mensaje")

            // Micrófono a la izquierda del botón Enviar. Rojo mientras dicta.
            Button(action: alternarDictado) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(dictando ? Color.red : Tema.superficieAlta)
                    .clipShape(Circle())
            }
            .disabled(estado.compactando || estado.enviando)
            .accessibilityLabel(dictando ? "Detener dictado" : "Dictar")
            .accessibilityIdentifier("boton-dictado")

            Button(action: accion) {
                Image(systemName: estado.enviando ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(botonActivo ? Tema.acento : Tema.superficieAlta)
                    .clipShape(Circle())
            }
            .disabled(!botonActivo)
            .accessibilityLabel(estado.enviando ? "Detener" : "Enviar")
            .accessibilityIdentifier("enviar-mensaje")
        }
        .padding(.horizontal, Tema.margen)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Tema.fondo)
    }

    private var botonActivo: Bool {
        guard !estado.compactando else { return false }
        return estado.enviando
            || !estado.borrador.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func accion() {
        if estado.enviando {
            estado.cancelar()
            return
        }

        // Tocar Enviar tambien termina el dictado: el texto parcial ya esta en
        // la caja y se envia tal cual.
        if dictando {
            detenerDictado()
        }
        estado.enviarTextoActual()
    }

    // MARK: - Dictado

    private func alternarDictado() {
        if dictando {
            detenerDictado()
            return
        }

        Task { @MainActor in
            let permitido = await estado.dictado.solicitarPermisos()
            guard permitido else {
                estado.avisoComando =
                    "El dictado necesita permiso de micrófono y reconocimiento de voz."
                return
            }

            // Se conserva lo que ya habia en la caja y solo se reemplaza la
            // parte dictada en esta sesion.
            textoAntesDeDictar = estado.borrador
            do {
                try estado.dictado.empezar { parcial in
                    Task { @MainActor in
                        aplicarDictado(parcial)
                    }
                }
                dictando = true
            } catch {
                dictando = false
                estado.avisoComando = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func aplicarDictado(_ parcial: String) {
        let prefijo = textoAntesDeDictar
        let separador = prefijo.isEmpty
            || prefijo.hasSuffix(" ")
            || prefijo.hasSuffix("\n") ? "" : " "
        estado.borrador = prefijo + separador + parcial
        estado.avisoComando = nil
    }

    private func detenerDictado() {
        guard dictando else { return }
        estado.dictado.detener()
        dictando = false
    }
}

/// Burbuja de error en linea al final del hilo (§3.7).
///
/// El mensaje del usuario sigue en su sitio; desde aqui se puede reintentar el
/// mismo turno o cambiar de modelo y reintentar, sin volver a escribirlo.
private struct BurbujaErrorTurno: View {
    let texto: String
    let otrosProveedores: [ProviderConfig]
    let nombreDeProveedor: (ProviderConfig) -> String
    let alReintentar: () -> Void
    let alCambiarModelo: (ProviderConfig) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.red.opacity(0.9))
                    Text(texto)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        alReintentar()
                    } label: {
                        Text("Reintentar")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Tema.acento)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reintentar-turno")

                    if !otrosProveedores.isEmpty {
                        Menu {
                            ForEach(otrosProveedores) { proveedor in
                                Button {
                                    alCambiarModelo(proveedor)
                                } label: {
                                    Text(nombreDeProveedor(proveedor))
                                }
                            }
                        } label: {
                            Text("Cambiar modelo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Tema.superficieAlta)
                                .clipShape(Capsule())
                        }
                        .accessibilityIdentifier("cambiar-modelo-error")
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                    .stroke(Color.red.opacity(0.25), lineWidth: 1)
            }

            Spacer(minLength: 48)
        }
        .accessibilityIdentifier("error-turno")
    }
}
