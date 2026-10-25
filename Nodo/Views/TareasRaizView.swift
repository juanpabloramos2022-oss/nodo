import Foundation
import SwiftUI

import NodoCore

/// Raiz de la pestana Tareas: lista y detalle en la misma pila.
///
/// Las tareas no se mezclan con los chats. La lista es la raiz y el detalle se
/// empuja con `navigationDestination`, igual que Chats, para que el boton de
/// volver diga "Tareas" y el gesto de borde izquierdo funcione.
struct TareasRaizView: View {
    @EnvironmentObject private var estado: EstadoApp

    /// La ruta guarda ids, no tareas: la lista se refresca desde `EstadoApp`.
    @State private var ruta: [UUID] = []
    @State private var aBorrar: Tarea?

    var body: some View {
        NavigationStack(path: $ruta) {
            contenido
                .navigationTitle("Tareas")
                .navigationDestination(for: UUID.self) { id in
                    if estado.tareas.contains(where: { $0.id == id }) {
                        TareaView(tareaID: id)
                    } else {
                        EstadoVacio(
                            icono: "checklist",
                            titulo: "Tarea no disponible",
                            detalle: "Vuelve a Tareas para abrir otra."
                        )
                        .background(Tema.fondo.ignoresSafeArea())
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // B3-A: + Nueva tarea abre el hilo vacio. El
                            // encargo se escribe en el composer inferior, no
                            // en una hoja de formulario.
                            let tarea = estado.crearTarea()
                            ruta.append(tarea.id)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Nueva tarea")
                        .accessibilityIdentifier("nueva-tarea")
                    }
                }
        }
        .confirmationDialog(
            "¿Borrar esta tarea?",
            isPresented: Binding(
                get: { aBorrar != nil },
                set: { presentado in
                    if !presentado { aBorrar = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Borrar", role: .destructive) {
                if let aBorrar {
                    estado.borrarTarea(id: aBorrar.id)
                }
                aBorrar = nil
            }
            Button("Cancelar", role: .cancel) {
                aBorrar = nil
            }
        }
        // La barra Listo se declara una sola vez en la raiz de esta jerarquia.
        .conBarraTecladoListo()
    }

    @ViewBuilder
    private var contenido: some View {
        if estado.tareas.isEmpty {
            EstadoVacio(
                icono: "checklist",
                titulo: "Sin tareas",
                detalle: "Crea una tarea, revisa su plan y pulsa Empezar."
            )
            .background(Tema.fondo.ignoresSafeArea())
        } else {
            List {
                ForEach(estado.tareas) { tarea in
                    NavigationLink(value: tarea.id) {
                        fila(tarea)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            aBorrar = tarea
                        } label: {
                            Label("Borrar", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Tema.fondo)
        }
    }

    /// Fila con instruccion, estado y progreso.
    ///
    /// El progreso solo se pinta cuando hay libro (`progreso != nil`). Si solo
    /// existe el plan se dice cuantos pasos propone, sin fingir ejecucion.
    private func fila(_ tarea: Tarea) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tarea.titulo)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Text(tarea.estado.titulo)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(colorDe(tarea.estado))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(colorDe(tarea.estado).opacity(0.15))
                    .clipShape(Capsule())
                    .layoutPriority(2)
            }

            HStack(spacing: 8) {
                Text(progresoDe(tarea))
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(fechaDe(tarea.fechaActualizacion))
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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

    private func fechaDe(_ fecha: Date) -> String {
        let formateador = DateFormatter()
        formateador.locale = Locale(identifier: "es_ES")
        formateador.dateStyle = .short
        formateador.timeStyle = .short
        return formateador.string(from: fecha)
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
}
