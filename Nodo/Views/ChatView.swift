import Foundation
import SwiftUI
import UIKit

import NodoCore

/// La pantalla de conversacion, empujada dentro de la pila de Chats.
///
/// Invariantes de presentacion: `UI_INVARIANTS.md` (raiz del repo) manda
/// sobre todo lo que se pinta aqui; esta vista no muestra nada fuera de su
/// catalogo (nada de UUIDs, roles de herramienta ni rotulos tecnicos).
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
    /// Lleva a Mi Contexto para revisar la Memoria (accion [Ver] de la tarjeta
    /// de evento de MEM.3).
    let alVerMemoria: () -> Void

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
            estado.detenerDictado()
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
            // ya tiene suficiente historial (§4.2). Es la unica lectura directa
            // de `mensajes` que queda en la vista: decide si el comando esta
            // disponible, no que filas se pintan (eso lo decide la proyeccion).
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

    /// Lo que se pinta en el hilo lo decide la proyeccion de `EstadoApp`.
    ///
    /// La vista no mezcla `mensajes` con `eventosVisuales` ni filtra roles: solo
    /// recorre `[ElementoHiloVisible]`. Las busquedas de abajo recuperan
    /// metadatos que el catalogo no pinta (pie de consumo, skills y el id del
    /// evento para [Deshacer]); no deciden que filas existen.
    private var contenido: some View {
        cuerpoPrincipal(estado.elementosVisiblesDelHilo())
    }

    @ViewBuilder
    private func cuerpoPrincipal(
        _ elementos: [ElementoHiloVisible]
    ) -> some View {
        if elementos.isEmpty && !estado.enviando {
            // La Tarjeta de Bienvenida sustituye al estado vacio generico y se
            // alimenta solo de la configuracion real (§3.2).
            TarjetaBienvenidaView(
                alEmpezar: { escribiendo = true },
                alEditarMemoria: { mostrarMemoriaRapida = true },
                alGestionarModelos: alGestionarModelos
            )
        } else {
            cuerpoDelHilo(elementos)
        }
    }

    /// Cuerpo desplazable del hilo, ya con la proyeccion resuelta.
    private func cuerpoDelHilo(
        _ elementos: [ElementoHiloVisible]
    ) -> some View {
        let fuentes = estado.fuentesDeBurbujaVisibles(elementos)
        let memorias = estado.eventosDeMemoriaVisibles(elementos)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(elementos.indices, id: \.self) { indice in
                        vistaDeElemento(
                            elementos[indice],
                            indice: indice,
                            fuentes: fuentes,
                            memorias: memorias
                        )
                        .id(Self.idDeElemento(indice))
                    }
                }
                .padding(.horizontal, Tema.margen)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // El desplazamiento sigue a la PROYECCION, no a los arreglos
            // internos: cualquier cambio visible (mensaje, evento, texto en
            // curso, error o fin de turno) llega por la misma via.
            .onChange(of: estado.elementosVisiblesDelHilo()) { _, _ in
                desplazarAlFinal(proxy)
            }
            .onAppear { desplazarAlFinal(proxy) }
        }
    }

    @ViewBuilder
    private func vistaDeElemento(
        _ elemento: ElementoHiloVisible,
        indice: Int,
        fuentes: [Int: ChatMessage],
        memorias: [Int: EventoVisual]
    ) -> some View {
        switch elemento {
        case .burbujaUsuario(let texto):
            BurbujaUsuarioProyectada(
                texto: texto,
                skills: fuentes[indice]?.skillsAplicadas ?? [],
                alRamificar: fuentes[indice].flatMap { accionRamificar($0) }
            )

        case .burbujaAsistente(let segmentos):
            BurbujaAsistenteProyectada(
                segmentos: segmentos,
                pie: fuentes[indice].flatMap { pieDe($0) },
                alRamificar: fuentes[indice].flatMap { accionRamificar($0) }
            )

        case .lineaMemoria(let texto, let puedeDeshacer, let deshecho):
            LineaMemoriaProyectada(
                texto: texto,
                puedeDeshacer: puedeDeshacer,
                deshecho: deshecho,
                alVer: alVerMemoria,
                alDeshacer: {
                    guard let evento = memorias[indice] else { return }
                    _ = estado.deshacerCambioDeMemoria(id: evento.id)
                }
            )

        case .divisor(let texto):
            Text(texto)
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .accessibilityLabel(texto)

        case .burbujaEnCurso(let texto):
            BurbujaEnCurso(texto: texto)

        case .errorTurno(let texto):
            BurbujaErrorTurno(
                texto: texto,
                otrosProveedores: otrosProveedores,
                nombreDeProveedor: { nombreDeModelo($0) },
                alReintentar: { estado.reintentar() },
                alCambiarModelo: { proveedor in
                    estado.cambiarProveedor(proveedor)
                    estado.reintentar()
                }
            )

        case .hojaAprobacionMemoria(let texto, let categoria, let estadoAprobacion):
            HojaAprobacionMemoriaProyectada(
                texto: texto,
                categoriaSensible: categoria,
                estado: estadoAprobacion
            )
        }
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

    private static func idDeElemento(_ indice: Int) -> String {
        "elemento-\(indice)"
    }

    private func desplazarAlFinal(_ proxy: ScrollViewProxy) {
        let elementos = estado.elementosVisiblesDelHilo()
        guard let ultimo = elementos.indices.last else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(Self.idDeElemento(ultimo), anchor: .bottom)
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
            // D2=B: la regla de "solo la ultima respuesta" vive en EstadoApp,
            // para poder probarla sin SwiftUI.
            puedeRegenerar: estado.puedeRegenerar(mensaje),
            otrosProveedores: otrosProveedores,
            nombreDeProveedor: { nombreDeModelo($0) },
            alRegenerar: { estado.regenerar() },
            alRegenerarCon: { estado.regenerarCon(proveedorID: $0.id) }
        )
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
            // La descripcion de selector manda cuando la skill la trae (las del
            // pack); una skill propia sin descripcion sigue mostrando su nombre.
            let escrita = (skill.descripcion ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "⚡ /\(skill.slug) — \(escrita.isEmpty ? skill.nombre : escrita)"
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
        case .plan:
            return "Propone un plan por pasos sin ejecutar nada."
        case .boost:
            return "Tubería multi-agente de 3 fases dentro de una Tarea."
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
        if estado.compactando { return "Compactando…" }
        if estado.generandoPlanChat { return "Generando plan…" }
        return "Escribe un mensaje"
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
            .disabled(estado.compactando || estado.generandoPlanChat)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .foregroundStyle(.white)
            .accessibilityIdentifier("caja-mensaje")

            // Micrófono a la izquierda del botón Enviar. Rojo mientras dicta.
            Button {
                Task { await estado.alternarDictado() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(estado.dictando ? Color.red : Tema.superficieAlta)
                    .clipShape(Circle())
            }
            .disabled(estado.compactando || estado.enviando || estado.generandoPlanChat)
            .accessibilityLabel(estado.dictando ? "Detener dictado" : "Dictar")
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
        guard !estado.compactando, !estado.generandoPlanChat else { return false }
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
        if estado.dictando {
            estado.detenerDictado()
        }
        estado.enviarTextoActual()
    }

    // MARK: - Dictado

    // El estado del dictado (grabando, parciales y fallos) vive en EstadoApp
    // para poder probarlo sin SwiftUI ni hardware.
}

/// Burbuja de usuario construida desde la proyeccion.
///
/// Pinta solo el texto que entrega `.burbujaUsuario`. Las skills y la accion
/// de ramificar son metadatos de la fuente y no cambian que fila se pinta.
private struct BurbujaUsuarioProyectada: View {
    let texto: String
    let skills: [String]
    let alRamificar: (() -> Void)?

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            burbuja
        }
    }

    @ViewBuilder
    private var burbuja: some View {
        if let alRamificar {
            contenido.contextMenu {
                Button(action: alRamificar) {
                    Label(
                        "🔀 Ramificar chat desde aquí",
                        systemImage: "arrow.triangle.branch"
                    )
                }
            }
        } else {
            contenido
        }
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !skills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(skills, id: \.self) { nombre in
                        Text("⚡ \(nombre)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Tema.acento)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Tema.acento.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                .accessibilityIdentifier("skills-aplicadas")
            }

            Text(texto)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Tema.acento.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }
}

/// Burbuja del asistente construida desde los segmentos de la proyeccion.
///
/// El contenido se pinta tal como lo entrega `.burbujaAsistente`: prosa y
/// bloques de codigo ya separados. El pie de consumo sigue pegado a la burbuja.
private struct BurbujaAsistenteProyectada: View {
    let segmentos: [SegmentoRespuesta]
    let pie: PieRespuesta?
    let alRamificar: (() -> Void)?

    var body: some View {
        HStack {
            burbuja
            Spacer(minLength: 48)
        }
    }

    @ViewBuilder
    private var burbuja: some View {
        if let alRamificar {
            contenido.contextMenu {
                Button(action: alRamificar) {
                    Label(
                        "🔀 Ramificar chat desde aquí",
                        systemImage: "arrow.triangle.branch"
                    )
                }
            }
        } else {
            contenido
        }
    }

    private var contenido: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segmentos.indices, id: \.self) { indice in
                    vistaDeSegmento(segmentos[indice])
                }
            }

            if let pie {
                pie
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
    }

    @ViewBuilder
    private func vistaDeSegmento(_ segmento: SegmentoRespuesta) -> some View {
        switch segmento {
        case .texto(let texto):
            Text(texto)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

        case .codigo(let lenguaje, let textoCrudo):
            BloqueCodigoProyectado(
                lenguaje: lenguaje,
                textoCrudo: textoCrudo
            )
        }
    }
}

/// Bloque de codigo de una respuesta, con su cabecera y su boton Copiar.
///
/// La cabecera dice «Código» cuando la cerca no declaro lenguaje. El texto se
/// pinta exacto, sin las cercas de Markdown.
private struct BloqueCodigoProyectado: View {
    let lenguaje: String?
    let textoCrudo: String

    private var titulo: String {
        guard let lenguaje, !lenguaje.isEmpty else { return "Código" }
        return lenguaje
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(titulo)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    UIPasteboard.general.string = textoCrudo
                } label: {
                    Label("Copiar código", systemImage: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(Tema.acento)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copiar código")
                .accessibilityIdentifier("copiar-codigo")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(textoCrudo)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficieAlta)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Linea de memoria construida desde la proyeccion.
///
/// Mantiene la tarjeta actual de MEM.3 (texto, [Ver] y [Deshacer]) hasta que
/// B1.2 cambie el componente visual. No recibe el nombre de la herramienta ni
/// un id: el texto es el de `CambioMemoria.textoDeTarjeta`.
private struct LineaMemoriaProyectada: View {
    let texto: String
    let puedeDeshacer: Bool
    let deshecho: Bool
    let alVer: () -> Void
    let alDeshacer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundStyle(Tema.acento)

                Text(texto)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: alVer) {
                    Text("Ver")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Tema.superficieAlta)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memoria-evento-ver")

                if deshecho {
                    Text("Deshecho")
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("memoria-evento-deshecho")
                } else if puedeDeshacer {
                    Button(action: alDeshacer) {
                        Text("Deshacer")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Tema.acento.opacity(0.22))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("memoria-evento-deshacer")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficieAlta.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Tema.acento.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memoria-evento")
    }
}

/// Hoja de aprobacion de una escritura sensible, tal como la proyecta P0.2.
///
/// Muestra el texto exacto que se guardaria y la categoria tipada. No hay
/// campo para el nombre de la herramienta ni para un id.
private struct HojaAprobacionMemoriaProyectada: View {
    let texto: String
    let categoriaSensible: CategoriaSensible
    let estado: EstadoAprobacion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Aprobación necesaria", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)

            Text(texto)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("aprobacion-memoria-texto")

            HStack(spacing: 8) {
                Text(categoriaSensible.etiquetaVisible)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tema.acento)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tema.acento.opacity(0.15))
                    .clipShape(Capsule())

                Text(estado.titulo)
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                .stroke(Tema.acento.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aprobacion-memoria")
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
