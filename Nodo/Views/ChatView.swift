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

    /// Lleva a la pestana Ajustes para gestionar modelos.
    let alGestionarModelos: () -> Void
    /// Vuelve a la lista cuando se borra el chat abierto.
    let alVolverALista: () -> Void

    @State private var borrador = ""
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

            resumenDelChat
            tiraFina
            filaHerramientaEnCurso
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
        // Volver (boton o gesto) cierra el teclado en la transicion.
        .onDisappear { bajarTeclado() }
        .sheet(isPresented: $mostrarEstadoChat) {
            HojaEstadoChatView()
        }
        .sheet(isPresented: $mostrarMemoriaRapida) {
            HojaMemoriaRapidaView()
        }
        .sheet(item: $estado.aprobacionPendiente) { aprobacion in
            HojaAprobacionView(aprobacion: aprobacion) { aprobada in
                estado.resolverAprobacion(aprobada)
            }
            .interactiveDismissDisabled(true)
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
            ForEach(estado.config.proveedores) { proveedor in
                Button {
                    estado.cambiarProveedor(proveedor)
                } label: {
                    if esActivo(proveedor) {
                        Label(nombreDeModelo(proveedor), systemImage: "checkmark")
                    } else {
                        Text(nombreDeModelo(proveedor))
                    }
                }
            }

            Divider()

            Button {
                alGestionarModelos()
            } label: {
                Label("Gestionar modelos…", systemImage: "slider.horizontal.3")
            }
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
            && !estado.config.systemPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    private var costoAcumulado: Double? {
        guard let proveedor = estado.config.proveedorSeleccionado else { return nil }
        return CostoEstimado.acumulado(
            mensajes: estado.conversacion.mensajes,
            precioEntrada: proveedor.precioEntradaPorMillon,
            precioSalida: proveedor.precioSalidaPorMillon
        )
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
        if estado.conversacion.mensajes.isEmpty && !estado.enviando {
            EstadoVacio(
                icono: "bubble.left.and.bubble.right",
                titulo: "Nodo",
                detalle: "Escribe abajo para empezar. Tus claves se quedan en este telefono."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filas) { fila in
                            filaDeHilo(fila)
                                .id(fila.id)
                        }

                        if puedeRegenerar {
                            botonRegenerar
                                .id(Self.marcaRegenerar)
                        }

                        if estado.enviando {
                            BurbujaEnCurso(texto: estado.textoEnCurso)
                                .id(Self.marcaEnCurso)
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
                .onAppear { desplazarAlFinal(proxy) }
            }
        }
    }

    @ViewBuilder
    private func filaDeHilo(_ fila: FilaHilo) -> some View {
        switch fila {
        case .mensaje(let mensaje):
            if estado.conversacion.modoTarea {
                filaDeMensajeEnTarea(mensaje)
            } else {
                filaDeMensajeNormal(mensaje)
            }

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
        VStack(alignment: .leading, spacing: 2) {
            BurbujaMensaje(mensaje: mensaje)

            if mensaje.rol == .asistente,
               let linea = lineaDeConsumo(mensaje) {
                Text(linea)
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                    .padding(.leading, 14)
            }
        }
    }

    /// En modo Tarea los mensajes internos se leen como pasos plegables.
    ///
    /// La fila del paso la pone el mensaje del asistente que pidio la llamada;
    /// el mensaje de herramienta solo aporta el resultado y se pliega dentro de
    /// esa misma fila, sin pintar una burbuja duplicada. Un mensaje de
    /// herramienta huerfano (sin llamada que lo explique) se pinta igual como
    /// paso para no perder su texto.
    @ViewBuilder
    private func filaDeMensajeEnTarea(_ mensaje: ChatMessage) -> some View {
        if mensaje.rol == .herramienta {
            if !esHerramientaYaRepresentada(mensaje) {
                PasoHerramienta(
                    nombre: nombreDeHerramienta(para: mensaje.toolCallId) ?? "herramienta",
                    resultado: mensaje.texto
                )
            }
        } else if mensaje.rol == .asistente, !mensaje.toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !mensaje.texto.isEmpty {
                    BurbujaMensaje(mensaje: mensaje)
                }

                ForEach(mensaje.toolCalls, id: \.id) { llamada in
                    PasoHerramienta(
                        nombre: llamada.nombre,
                        resultado: resultadoDeHerramienta(para: llamada.id)
                    )
                }

                if let linea = lineaDeConsumo(mensaje) {
                    Text(linea)
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                        .padding(.leading, 14)
                }
            }
        } else {
            filaDeMensajeNormal(mensaje)
        }
    }

    private func esHerramientaYaRepresentada(_ mensaje: ChatMessage) -> Bool {
        guard let id = mensaje.toolCallId else { return false }
        return estado.conversacion.mensajes.contains { otro in
            otro.rol == .asistente && otro.toolCalls.contains { $0.id == id }
        }
    }

    private func resultadoDeHerramienta(para id: String) -> String {
        estado.conversacion.mensajes.first {
            $0.rol == .herramienta && $0.toolCallId == id
        }?.texto ?? ""
    }

    private func nombreDeHerramienta(para id: String?) -> String? {
        guard let id else { return nil }
        for mensaje in estado.conversacion.mensajes {
            if let llamada = mensaje.toolCalls.first(where: { $0.id == id }) {
                return llamada.nombre
            }
        }
        return nil
    }

    private static let marcaEnCurso = "nodo-en-curso"
    private static let marcaRegenerar = "nodo-regenerar"

    private func desplazarAlFinal(_ proxy: ScrollViewProxy) {
        let destino: String?
        if estado.enviando {
            destino = Self.marcaEnCurso
        } else if puedeRegenerar {
            destino = Self.marcaRegenerar
        } else {
            destino = filas.last?.id
        }

        guard let destino else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(destino, anchor: .bottom)
        }
    }

    /// Solo se puede regenerar la ultima respuesta cuando el turno ya termino.
    private var puedeRegenerar: Bool {
        !estado.enviando && estado.conversacion.mensajes.last?.rol == .asistente
    }

    /// Boton bajo la ultima respuesta para volver a generarla.
    private var botonRegenerar: some View {
        Button {
            estado.regenerar()
        } label: {
            Label("Regenerar", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Tema.textoSuave)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Tema.superficie)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Regenerar la ultima respuesta")
    }

    // MARK: - Consumo

    /// Consumo acumulado del chat, si algun mensaje trae cifras.
    private var usoDelChat: UsoTokens? {
        CostoEstimado.usoAcumulado(de: estado.conversacion.mensajes)
    }

    /// Fila fina con el acumulado del chat, encima de la tira y la caja.
    @ViewBuilder
    private var resumenDelChat: some View {
        if let uso = usoDelChat {
            HStack {
                Text(textoResumen(uso))
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tema.margen)
            .padding(.top, 6)
        }
    }

    private func textoResumen(_ uso: UsoTokens) -> String {
        var texto = "Chat: \(uso.total) tokens"
        if let costo = costoDe(uso) {
            texto += " · " + textoCosto(costo)
        }
        return texto
    }

    /// Linea discreta bajo una respuesta: tokens y, si hay precios, costo.
    private func lineaDeConsumo(_ mensaje: ChatMessage) -> String? {
        guard let uso = mensaje.uso else { return nil }
        var linea = "\(uso.entrada) de entrada · \(uso.salida) de salida"
        if let costo = costoDe(uso) {
            linea += " · " + textoCosto(costo)
        }
        return linea
    }

    private func costoDe(_ uso: UsoTokens) -> Double? {
        let proveedor = estado.config.proveedorSeleccionado
        return CostoEstimado.costo(
            uso: uso,
            precioEntrada: proveedor?.precioEntradaPorMillon,
            precioSalida: proveedor?.precioSalidaPorMillon
        )
    }

    private func textoCosto(_ costo: Double) -> String {
        "≈$\(String(format: "%.4f", costo)) estimado"
    }

    // MARK: - Tira fina y caja de texto

    /// Fila fina sobre la caja: modo Chat | Tarea y acceso rapido a la Memoria.
    private var tiraFina: some View {
        HStack(spacing: 10) {
            Picker(
                "Modo",
                selection: Binding(
                    get: { estado.conversacion.modoTarea },
                    set: { estado.cambiarModoTarea($0) }
                )
            ) {
                Text("Chat").tag(false)
                Text("Tarea").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 160)
            .accessibilityLabel("Modo del chat")
            .accessibilityIdentifier("modo-chat")

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

    /// Fila fina sobre la caja mientras una herramienta se esta ejecutando.
    @ViewBuilder
    private var filaHerramientaEnCurso: some View {
        if estado.conversacion.modoTarea,
           let nombre = estado.herramientaEnCurso {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Ejecutando \(nombre)…")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tema.margen)
            .padding(.top, 6)
            .accessibilityIdentifier("paso-en-curso")
        }
    }

    private var barraDeEntrada: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Escribe un mensaje", text: $borrador, axis: .vertical)
                .lineLimit(1...6)
                .focused($escribiendo)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Tema.superficie)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .foregroundStyle(.white)

            Button(action: accion) {
                Image(systemName: estado.enviando ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(botonActivo ? Tema.acento : Tema.superficieAlta)
                    .clipShape(Circle())
            }
            .disabled(!botonActivo)
        }
        .padding(.horizontal, Tema.margen)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Tema.fondo)
    }

    private var botonActivo: Bool {
        estado.enviando || !borrador.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func accion() {
        if estado.enviando {
            estado.cancelar()
            return
        }
        let texto = borrador
        borrador = ""
        estado.enviar(texto)
    }
}

/// Paso plegable de una herramienta dentro de una conversacion en modo Tarea.
///
/// La fila siempre se ve; el resultado solo aparece al tocarla. Asi el hilo no
/// se llena de texto tecnico, pero nada queda escondido sin salida.
private struct PasoHerramienta: View {
    let nombre: String
    let resultado: String

    @State private var desplegado = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    desplegado.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text("Paso · \(nombre)")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: desplegado ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Tema.acento)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Tema.superficie)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Paso \(nombre)")
            .accessibilityHint(
                desplegado ? "Toca para plegar el resultado" : "Toca para ver el resultado"
            )
            .accessibilityIdentifier("paso-herramienta")

            if desplegado {
                Text(resultado.isEmpty ? "Sin resultado." : resultado)
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Tema.superficie.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// Hoja de aprobacion de una herramienta con consecuencias.
///
/// Solo tiene dos salidas, Aprobar y Rechazar, y no se cierra por arrastre ni
/// por accidente: la decision es obligatoria (CONTRATO §2.2).
private struct HojaAprobacionView: View {
    let aprobacion: AprobacionPendiente
    let decidir: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Aprobar herramienta")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(aprobacion.nombreHerramienta)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(
                    aprobacion.resumenArgumentos.isEmpty
                        ? "Sin argumentos."
                        : aprobacion.resumenArgumentos
                )
                .font(.footnote.monospaced())
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(6)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Esta herramienta puede tener consecuencias. Nada se ejecuta hasta que decidas.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    decidir(false)
                } label: {
                    Text("Rechazar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    decidir(true)
                } label: {
                    Text("Aprobar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Tema.margen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tema.fondo)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
        .accessibilityIdentifier("hoja-aprobacion")
    }
}
