import Foundation
import SwiftUI

import NodoCore

/// Pantalla de una tarea: instruccion, plan por pasos y autorizacion.
///
/// TASK.2 es plan-primero: la vista pide el plan al abrir un borrador, deja
/// editarlo/regenerarlo y solo convierte la tarea en `enCurso` cuando el dueno
/// pulsa Empezar. No ejecuta herramientas: la ejecucion y el libro de pasos
/// llegan en TASK.3.
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

    /// Accion principal segun el estado. Empezar no ejecuta nada en TASK.2.
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
            VStack(alignment: .leading, spacing: 6) {
                Label("En curso", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tema.acento)

                // Honestidad de TASK.2: la ejecucion de pasos no existe aqui.
                // Se declara el estado sin inventar llamadas ni resultados.
                Text(
                    tarea.pasos.isEmpty
                        ? "Sin pasos todavía. La ejecución de pasos llega en TASK.3."
                        : "\(progresoDe(tarea))."
                )
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("tarea-en-curso")

        case .interrumpida:
            Text("La app se cerró con la tarea en curso. Por eso quedó Interrumpida.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)

        case .detenida:
            Text("La tarea está detenida.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)

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
