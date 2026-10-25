import Foundation
import SwiftUI

import NodoCore

/// Hilo conversacional de una Tarea (B3-A).
///
/// Demuele el formulario de la v0.3.1: el encargo ya no vive en una caja de
/// texto con su propio boton de guardado, ni en secciones estaticas de plan y
/// trabajo. El encargo es un mensaje en el composer (el MISMO de Chat), el
/// plan es una tarjeta del hilo con [Empezar] y [Ajustar / Regenerar], y el
/// estado y el costo sellado viven en una cabecera fija que no se va con el
/// scroll.
///
/// Invariantes: `UI_INVARIANTS.md` (raiz del repo). La vista pinta solo lo que
/// el ViewModel del hilo entrega; no hay UUIDs, JSON crudo ni rótulos técnicos.
struct TareaView: View {
    let tareaID: UUID

    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss
    @StateObject private var hilo = HiloTareaViewModel()
    @FocusState private var escribiendo: Bool

    private var tarea: Tarea? {
        estado.tareas.first { $0.id == tareaID }
    }

    var body: some View {
        Group {
            if let tarea {
                contenido(tarea)
            } else {
                EstadoVacio(
                    icono: "checklist",
                    titulo: "Tarea no disponible",
                    detalle: "Vuelve a Tareas para abrir otra."
                )
            }
        }
        .background(Tema.fondo.ignoresSafeArea())
        .navigationTitle("Tarea")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                menuTarea
            }
        }
        // La tarea es un espacio propio: al entrar se oculta la barra de
        // pestanas y se sale con el boton nativo de volver a Tareas.
        .toolbar(.hidden, for: .tabBar)
        .conBarraTecladoListo()
        .task(id: tareaID) { sincronizar() }
        .onChange(of: estado.tareas) { _, _ in sincronizar() }
        .onChange(of: estado.idTareaPlanificando) { _, _ in sincronizar() }
    }

    @ViewBuilder
    private var menuTarea: some View {
        if let tarea {
            Menu {
                Button(role: .destructive) {
                    estado.borrarTarea(id: tarea.id)
                    dismiss()
                } label: {
                    Label("Borrar tarea", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Acciones de la tarea")
            .accessibilityIdentifier("menu-tarea")
        }
    }

    private func contenido(_ tarea: Tarea) -> some View {
        VStack(spacing: 0) {
            cabeceraFija(tarea)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(hilo.elementos.indices, id: \.self) { indice in
                            vistaDeElemento(
                                hilo.elementos[indice],
                                tarea: tarea
                            )
                            .id(indice)
                        }

                        if estado.idTareaPlanificando == tarea.id {
                            filaPlanificando
                        }
                    }
                    .padding(.horizontal, Tema.margen)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: hilo.elementos.count) { _, cuantos in
                    guard cuantos > 0 else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(cuantos - 1, anchor: .bottom)
                    }
                }
            }

            ComposerMensaje(
                texto: $estado.borrador,
                placeholder: "Escribe el encargo o un ajuste",
                bloqueoEnvio: estado.idTareaPlanificando != nil
                    || tarea.estado == .enCurso,
                dictando: estado.dictando,
                alEnviar: { enviar(tarea) },
                alDictar: { Task { await estado.alternarDictado() } },
                enfocado: $escribiendo
            )
        }
        .accessibilityIdentifier("hilo-tarea")
    }

    // MARK: - Cabecera fija (R20)

    /// Estado, costo sellado y [Detener] siempre visibles, sin scroll.
    ///
    /// Colapsable por el dueno: al colapsar se oculta el detalle de progreso,
    /// nunca la cabecera entera ni el costo ni el boton de detener.
    private func cabeceraFija(_ tarea: Tarea) -> some View {
        let cab = hilo.cabecera
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Tarea")
                    .font(.headline)

                Text(cab.estado.titulo)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colorDeCabecera(cab.estado))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(colorDeCabecera(cab.estado).opacity(0.15))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("estado-tarea")

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hilo.colapsada.toggle()
                    }
                } label: {
                    Image(
                        systemName: hilo.colapsada
                            ? "chevron.down"
                            : "chevron.up"
                    )
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    hilo.colapsada
                        ? "Mostrar el detalle de la tarea"
                        : "Ocultar el detalle de la tarea"
                )
                .accessibilityIdentifier("colapsar-cabecera-tarea")
            }

            HStack(spacing: 10) {
                Text(costoSellado(cab.costoSellado))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityIdentifier("costo-tarea")

                if !hilo.colapsada, cab.pasosTotales > 0 {
                    Text("Paso \(cab.pasoActual)/\(cab.pasosTotales)")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("progreso-tarea")
                }

                Spacer(minLength: 8)

                if cab.estado == .enCurso || cab.estado == .esperandoAprobacion {
                    Button(role: .destructive) {
                        estado.detenerTarea(id: tarea.id)
                    } label: {
                        Label("Detener", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detener-tarea")
                }
            }
        }
        .padding(.horizontal, Tema.margen)
        .padding(.vertical, 8)
        .background(Tema.superficie)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Tema.borde)
                .frame(height: 1)
        }
    }

    // MARK: - Elementos del hilo

    @ViewBuilder
    private func vistaDeElemento(
        _ elemento: HiloTareaViewModel.Elemento,
        tarea: Tarea
    ) -> some View {
        switch elemento {
        case .burbujaUsuario(let texto):
            burbujaUsuario(texto)

        case .tarjetaPlan(let pasos, let version, let acciones):
            tarjetaPlan(
                pasos: pasos,
                version: version,
                acciones: acciones,
                tarea: tarea
            )

        case .filaPaso(
            let paso,
            let estado,
            let etiqueta,
            let duracion,
            let costo
        ):
            filaDePaso(
                paso: paso,
                estado: estado,
                etiqueta: etiqueta,
                duracion: duracion,
                costo: costo
            )

        case .errorEnLinea(let texto):
            errorEnLinea(texto)

        case .resultadoFinal(let texto):
            resultadoFinal(texto, tarea: tarea)
        }
    }

    private func burbujaUsuario(_ texto: String) -> some View {
        HStack {
            Spacer(minLength: 48)

            Text(texto)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Tema.acento.opacity(0.22))
                .clipShape(
                    RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                )
        }
        .accessibilityIdentifier("burbuja-encargo-tarea")
    }

    private func tarjetaPlan(
        pasos: [PasoPlan],
        version: Int,
        acciones: [HiloTareaViewModel.AccionPlan],
        tarea: Tarea
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(acciones.isEmpty ? "Plan" : "Plan propuesto")
                    .font(.subheadline.weight(.semibold))

                Text("v\(version)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tema.acento)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tema.acento.opacity(0.18))
                    .clipShape(Capsule())

                Spacer(minLength: 0)
            }

            if pasos.isEmpty {
                Text("El plan llegó vacío. Pide un ajuste para regenerarlo.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(pasos) { paso in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(paso.orden).")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Tema.acento)
                            .frame(width: 22, alignment: .trailing)

                        Text(paso.texto)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !acciones.isEmpty {
                HStack(spacing: 12) {
                    if acciones.contains(.empezar) {
                        Button {
                            estado.empezarTarea(id: tarea.id)
                        } label: {
                            Label("Empezar", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("empezar-tarea")
                    }

                    if acciones.contains(.ajustar) {
                        Button {
                            Task {
                                await estado.regenerarPlanTarea(id: tarea.id)
                            }
                        } label: {
                            Label(
                                "Ajustar / Regenerar",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("ajustar-plan")
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .accessibilityIdentifier("tarjeta-plan-tarea")
    }

    private func filaDePaso(
        paso: Int,
        estado visible: ElementoTareaVisible.EstadoPaso,
        etiqueta: String,
        duracion: TimeInterval?,
        costo: Decimal?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconoDePaso(visible))
                .font(.caption)
                .foregroundStyle(colorDePaso(visible))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(paso). \(etiqueta)")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Text(visible.titulo)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(colorDePaso(visible))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let duracion {
                        Text(String(format: "%.1f s", duracion))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Tema.textoSuave)
                    }

                    if let costo {
                        Text(costoSellado(costo))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Tema.textoSuave)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("fila-paso-tarea")
    }

    private func errorEnLinea(_ texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(texto)
                .font(.footnote)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("error-en-linea-tarea")
    }

    private func resultadoFinal(_ texto: String, tarea: Tarea) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Resultado")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)

                if tarea.verificadoPorCruce {
                    Label("Verificado por cruce", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("verificado-por-cruce")
                }
            }

            Text(texto)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if tarea.verificadoPorCruce {
                Text(
                    "Verificación cruzada entre modelos: contraste crítico, "
                        + "no pruebas ejecutadas."
                )
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .accessibilityIdentifier("resultado-final-tarea")
    }

    /// Indicador de E1: el plan se esta generando. Es estado transitorio y no
    /// un elemento del catalogo; no entra en la traza.
    private var filaPlanificando: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Generando el plan…")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("generando-plan")
    }

    // MARK: - Acciones

    private func enviar(_ tarea: Tarea) {
        let texto = estado.borrador
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else { return }
        estado.borrador = ""
        Task {
            await estado.enviarMensajeTarea(id: tarea.id, texto: texto)
        }
    }

    private func sincronizar() {
        guard let tarea else { return }
        hilo.reconstruir(
            con: tarea,
            proyeccion: estado.elementosVisiblesDeTarea(tarea)
        )
    }

    // MARK: - Presentacion

    private func costoSellado(_ valor: Decimal) -> String {
        let numero = NSDecimalNumber(decimal: valor).doubleValue
        return String(format: "≈$%.6f", numero)
    }

    private func colorDeCabecera(
        _ estado: ElementoTareaVisible.EstadoTarea
    ) -> Color {
        switch estado {
        case .nuevaTarea: return Tema.textoSuave
        case .planificando: return Tema.acento
        case .planPropuesto: return .orange
        case .esperandoAprobacion: return .orange
        case .enCurso: return Tema.acento
        case .detenida: return .yellow
        case .error: return .red
        case .completada: return .green
        }
    }

    private func iconoDePaso(
        _ estado: ElementoTareaVisible.EstadoPaso
    ) -> String {
        switch estado {
        case .pendiente: return "circle"
        case .enCurso: return "arrow.triangle.2.circlepath"
        case .esperandoAprobacion: return "hand.raised.fill"
        case .completado: return "checkmark.circle.fill"
        case .denegado: return "hand.raised.fill"
        case .detenido: return "stop.circle"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func colorDePaso(
        _ estado: ElementoTareaVisible.EstadoPaso
    ) -> Color {
        switch estado {
        case .pendiente: return Tema.textoSuave
        case .enCurso: return Tema.acento
        case .esperandoAprobacion: return .orange
        case .completado: return .green
        case .denegado: return .orange
        case .detenido: return .yellow
        case .error: return .red
        }
    }
}
