import Foundation
import SwiftUI

import NodoCore

/// Pantalla de una tarea: instruccion, plan, libro en vivo y autorizacion.
///
/// TASK.2 deja el flujo plan-primero. TASK.3 conecta Empezar con el ToolLoop y
/// pinta el libro real; TASK.4 anade la hoja de aprobacion de `proponer_memoria`.
struct TareaView: View {
    let tareaID: UUID

    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    @State private var instruccion = ""
    @State private var cargada = false

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
        .onAppear(perform: cargarSiHaceFalta)
        // Al abrir un borrador con instruccion, la app pide el plan sola. Es
        // el mismo punto que usa el boton Regenerar; no hay dos caminos.
        .task(id: tareaID) {
            await generarPlanSiHaceFalta()
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cabecera(tarea)
                seccionInstruccion(tarea)
                seccionPlan(tarea)
                seccionTrabajo(tarea)
                seccionRespuestaFinal(tarea)
                acciones(tarea)
                fronteraIOs

                if let mensaje = estado.errorTarea {
                    AvisoError(texto: mensaje) {
                        estado.errorTarea = nil
                    }
                    // AvisoError ya trae su margen horizontal; se compensa el
                    // margen del VStack para que no quede doble.
                    .padding(.horizontal, -Tema.margen)
                }
            }
            .padding(Tema.margen)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Estado y progreso, siempre visibles antes del plan.
    private func cabecera(_ tarea: Tarea) -> some View {
        HStack(spacing: 10) {
            Text(tarea.estado.titulo)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorDe(tarea.estado))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(colorDe(tarea.estado).opacity(0.15))
                .clipShape(Capsule())
                .accessibilityIdentifier("estado-tarea")

            Spacer(minLength: 8)

            Text(progresoDe(tarea))
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .accessibilityIdentifier("progreso-tarea")
        }
    }

    /// Instruccion editable solo antes de autorizar la ejecucion.
    private func seccionInstruccion(_ tarea: Tarea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instrucción")
                .font(.headline)

            TextEditor(text: $instruccion)
                .frame(minHeight: 120)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Tema.superficie)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
                .disabled(!tarea.admiteEdicion)
                .opacity(tarea.admiteEdicion ? 1 : 0.6)
                .accessibilityIdentifier("instruccion-tarea")

            if tarea.admiteEdicion {
                HStack(spacing: 12) {
                    Button("Guardar instrucción") {
                        estado.actualizarInstruccionTarea(
                            id: tarea.id,
                            instruccion: instruccion
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(instruccionLimpia.isEmpty || instruccionLimpia == tarea.instruccion)

                    Spacer(minLength: 0)

                    Button {
                        Task {
                            await estado.generarPlan(
                                id: tarea.id,
                                instruccion: instruccion
                            )
                        }
                    } label: {
                        Label("Regenerar plan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(instruccionLimpia.isEmpty || estado.generandoPlan)
                    .accessibilityIdentifier("regenerar-plan")
                }
            }
        }
    }

    /// Lista visible del plan, con su estado de generacion.
    private func seccionPlan(_ tarea: Tarea) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Plan")
                    .font(.headline)

                Spacer(minLength: 0)

                if estado.generandoPlan {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("generando-plan")
                }
            }

            if estado.generandoPlan {
                Text("Generando el plan en modo solo-texto, sin herramientas…")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let plan = tarea.plan {
                if plan.pasos.isEmpty {
                    Text(plan.texto)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(plan.pasos) { paso in
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
            } else {
                Text("Todavía no hay plan. Escribe la instrucción y pulsa Regenerar plan.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Panel de trabajo: libro en vivo, enlaces traidos, aprobaciones y costo.
    ///
    /// No es una copia decorativa del plan: cada fila sale del libro que el
    /// ToolLoop acaba de persistir, asi que un paso "En curso" es una llamada
    /// real y no una promesa.
    private func seccionTrabajo(_ tarea: Tarea) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Trabajo")
                    .font(.headline)

                Spacer(minLength: 0)

                if let costo = tarea.costoAcumuladoUSD {
                    Text("≈$\(String(format: "%.6f", costo))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("costo-tarea")
                } else if !tarea.pasos.isEmpty {
                    Text("Costo no medido")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .accessibilityIdentifier("costo-tarea")
                }
            }

            if let costoBoost = tarea.costoBoostUSD {
                Text("Boost (fases): ≈$\(String(format: "%.6f", costoBoost))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityIdentifier("costo-boost-tarea")
            }

            if tarea.pasos.isEmpty {
                Text(
                    tarea.estado == .enCurso
                        ? "Ejecutando. Los pasos aparecerán aquí en cuanto ocurran."
                        : "Todavía no hay pasos ejecutados."
                )
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(tarea.pasos) { paso in
                    filaPaso(paso)
                }
            }

            if !enlacesDe(tarea).isEmpty {
                Divider()
                    .overlay(Tema.borde)

                Text("Enlaces traídos")
                    .font(.subheadline.weight(.semibold))

                ForEach(enlacesDe(tarea)) { paso in
                    if let crudo = paso.url, let url = URL(string: crudo) {
                        VStack(alignment: .leading, spacing: 4) {
                            Link(destination: url) {
                                Text(crudo)
                                    .font(.footnote)
                                    .foregroundStyle(Tema.acento)
                                    .lineLimit(2)
                            }

                            if let resumen = paso.resultadoResumido(limite: 160) {
                                Text(resumen)
                                    .font(.caption)
                                    .foregroundStyle(Tema.textoSuave)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let solicitud = estado.solicitudAprobacion,
               solicitud.tareaID == tarea.id {
                Divider()
                    .overlay(Tema.borde)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Esperando aprobación", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                    Text(solicitud.descripcion)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button("Denegar", role: .destructive) {
                            estado.denegarSolicitud()
                        }
                        .buttonStyle(.bordered)

                        Button("Aprobar") {
                            estado.aprobarSolicitud()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .accessibilityIdentifier("aprobacion-pendiente-tarea")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("panel-trabajo-tarea")
    }

    /// Respuesta final de la tarea, con su marca de verificacion cruzada.
    ///
    /// La marca es una frontera honesta: dice que la sintesis de /boost cruzo
    /// los angulos, no que se hayan ejecutado pruebas. Se pinta junto al texto
    /// para que no se lea como una garantia mayor de la que es.
    @ViewBuilder
    private func seccionRespuestaFinal(_ tarea: Tarea) -> some View {
        if let resultado = tarea.resultado,
           !resultado.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Respuesta final")
                        .font(.headline)

                    Spacer(minLength: 0)

                    if tarea.verificadoPorCruce {
                        Label("Verificado por cruce", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("verificado-por-cruce")
                    }
                }

                Text(resultado)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                if tarea.verificadoPorCruce {
                    Text("Verificación cruzada entre modelos: contraste crítico, no pruebas ejecutadas.")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("respuesta-final-tarea")
        }
    }

    private func filaPaso(_ paso: Paso) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconoDe(paso.estado))
                .font(.caption)
                .foregroundStyle(colorDe(paso.estado))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(paso.descripcion)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Text(paso.estado.titulo)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(colorDe(paso.estado))
                        .lineLimit(1)
                }

                if let etiqueta = paso.etiquetaDeFase {
                    HStack(spacing: 6) {
                        Text(etiqueta)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Tema.acento)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Tema.acento.opacity(0.18))
                            .clipShape(Capsule())

                        if let proveedor = paso.proveedorNombre {
                            Text(proveedor)
                                .font(.caption2)
                                .foregroundStyle(Tema.textoSuave)
                                .lineLimit(1)
                        }

                        if let costo = paso.costoUSD {
                            Text("≈$\(String(format: "%.6f", costo))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Tema.textoSuave)
                        }
                    }
                    .accessibilityIdentifier("fase-paso-tarea")
                }

                if let resumen = paso.resultadoResumido() {
                    Text(
                        paso.estado == .denegado
                            ? "Denegado por el dueño: no se escribió nada."
                            : resumen
                    )
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func enlacesDe(_ tarea: Tarea) -> [Paso] {
        tarea.pasos.filter { paso in
            guard let url = paso.url else { return false }
            return !url.isEmpty
        }
    }

    private func iconoDe(_ estado: EstadoPaso) -> String {
        switch estado {
        case .pendiente: return "circle"
        case .enCurso: return "arrow.triangle.2.circlepath"
        case .terminado: return "checkmark.circle.fill"
        case .fallido: return "xmark.octagon.fill"
        case .denegado: return "hand.raised.fill"
        }
    }

    private func colorDe(_ estado: EstadoPaso) -> Color {
        switch estado {
        case .pendiente: return Tema.textoSuave
        case .enCurso: return Tema.acento
        case .terminado: return .green
        case .fallido: return .red
        case .denegado: return .orange
        }
    }

    /// Accion principal segun el estado. Empezar ya ejecuta (TASK.3).
    @ViewBuilder
    private func acciones(_ tarea: Tarea) -> some View {
        switch tarea.estado {
        case .borrador, .esperandoInicio:
            Button {
                estado.empezarTarea(id: tarea.id)
            } label: {
                Label("Empezar", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tarea.plan == nil || estado.generandoPlan)
            .accessibilityIdentifier("empezar-tarea")

            if tarea.plan == nil {
                Text("Genera el plan antes de empezar.")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
            }

        case .enCurso:
            VStack(alignment: .leading, spacing: 10) {
                Label("En curso", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tema.acento)

                Text(
                    tarea.pasos.isEmpty
                        ? "La ejecución acaba de empezar. Los pasos se verán aquí."
                        : "\(progresoDe(tarea))."
                )
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    estado.detenerTarea(id: tarea.id)
                } label: {
                    Label("Detener", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detener-tarea")
            }
            .accessibilityIdentifier("tarea-en-curso")

        case .interrumpida:
            VStack(alignment: .leading, spacing: 10) {
                Text("La app se cerró con la tarea en curso. Por eso quedó Interrumpida.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)

                botonReanudar(tarea)
            }

        case .detenida:
            VStack(alignment: .leading, spacing: 10) {
                Text("La tarea está detenida. Los pasos anteriores siguen intactos.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)

                botonReanudar(tarea)
            }

        case .completada:
            Text("La tarea terminó.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)

        case .fallida:
            Text("La tarea falló.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
        }
    }

    private func botonReanudar(_ tarea: Tarea) -> some View {
        Button {
            estado.reanudarTarea(id: tarea.id)
        } label: {
            Label("Reanudar", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(tarea.plan == nil)
        .accessibilityIdentifier("reanudar-tarea")
    }

    /// Frontera honesta de iOS, visible siempre en la pantalla de la tarea.
    private var fronteraIOs: some View {
        Text("Si cierras la app, la tarea se marca Interrumpida: iOS no ejecuta en segundo plano.")
            .font(.footnote)
            .foregroundStyle(Tema.textoSuave)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("frontera-ios-tarea")
    }

    private var instruccionLimpia: String {
        instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func progresoDe(_ tarea: Tarea) -> String {
        if let progreso = tarea.progreso {
            return "\(progreso.terminados)/\(progreso.total) pasos"
        }
        if let plan = tarea.plan {
            return "\(plan.pasos.count) pasos planificados"
        }
        return "Sin plan todavía"
    }

    private func colorDe(_ estado: EstadoTarea) -> Color {
        switch estado {
        case .borrador:
            return Tema.textoSuave
        case .esperandoInicio:
            return .orange
        case .enCurso:
            return Tema.acento
        case .detenida:
            return .yellow
        case .interrumpida:
            return .orange
        case .completada:
            return .green
        case .fallida:
            return .red
        }
    }

    private func cargarSiHaceFalta() {
        guard !cargada, let tarea else { return }
        instruccion = tarea.instruccion
        cargada = true
    }

    /// Dispara el plan automatico solo en el caso plan-primero.
    ///
    /// No reintenta en cada redibujado: `.task(id:)` corre una vez por tarea.
    /// Si falla, el dueno tiene el boton Regenerar plan.
    private func generarPlanSiHaceFalta() async {
        guard let tarea,
              tarea.estado == .borrador,
              tarea.plan == nil,
              !tarea.instruccion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !estado.generandoPlan
        else {
            return
        }
        await estado.generarPlan(id: tarea.id)
    }
}
