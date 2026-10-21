import SwiftUI

import NodoCore

/// Lista de conversaciones guardadas.
struct ConversationsView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var aBorrar: Conversation?

    var body: some View {
        NavigationStack {
            Group {
                if estado.conversaciones.isEmpty {
                    EstadoVacio(
                        icono: "clock",
                        titulo: "Sin historial",
                        detalle: "Las conversaciones se guardan solas en el telefono."
                    )
                } else {
                    List {
                        ForEach(estado.conversaciones) { conversacion in
                            Button {
                                estado.abrir(conversacion)
                            } label: {
                                fila(conversacion)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Tema.superficie)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    aBorrar = conversacion
                                } label: {
                                    Label("Borrar", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Historial")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        estado.nuevaConversacion()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .confirmationDialog(
                "Borrar esta conversacion?",
                isPresented: Binding(
                    get: { aBorrar != nil },
                    set: { if !$0 { aBorrar = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Borrar", role: .destructive) {
                    if let aBorrar { estado.borrar(aBorrar) }
                    aBorrar = nil
                }
                Button("Cancelar", role: .cancel) { aBorrar = nil }
            }
        }
    }

    private func fila(_ conversacion: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if estado.conversacion.id == conversacion.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Tema.acento)
                }
                Text(conversacion.titulo)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Text("\(conversacion.mensajes.count) mensajes")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
