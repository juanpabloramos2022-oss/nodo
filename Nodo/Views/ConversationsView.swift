import SwiftUI

import NodoCore

/// Lista de conversaciones guardadas.
struct ConversationsView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var aBorrar: Conversation?
    @State private var aRenombrar: Conversation?
    @State private var tituloEditado = ""
    @State private var busqueda = ""

    /// Secciones ya ordenadas y filtradas por las reglas de NodoCore.
    private var secciones: SeccionesHistorial {
        HistorialConversaciones.secciones(de: estado.conversaciones, busqueda: busqueda)
    }

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
                    lista
                }
            }
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Historial")
            .searchable(
                text: $busqueda,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Buscar por titulo o mensaje"
            )
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
            .alert(
                "Renombrar conversacion",
                isPresented: Binding(
                    get: { aRenombrar != nil },
                    set: { if !$0 { aRenombrar = nil } }
                )
            ) {
                TextField("Titulo", text: $tituloEditado)
                Button("Guardar") {
                    if let aRenombrar {
                        let limpio = tituloEditado.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !limpio.isEmpty {
                            estado.renombrar(aRenombrar, titulo: limpio)
                        }
                    }
                    aRenombrar = nil
                }
                Button("Cancelar", role: .cancel) { aRenombrar = nil }
            }
        }
    }

    private var lista: some View {
        List {
            if !secciones.fijadas.isEmpty {
                Section("Fijados") {
                    ForEach(secciones.fijadas) { conversacion in
                        filaConAcciones(conversacion, archivada: false)
                    }
                }
            }

            if !secciones.recientes.isEmpty {
                Section {
                    ForEach(secciones.recientes) { conversacion in
                        filaConAcciones(conversacion, archivada: false)
                    }
                }
            }

            if !secciones.archivadas.isEmpty {
                Section("Archivados") {
                    ForEach(secciones.archivadas) { conversacion in
                        filaConAcciones(conversacion, archivada: true)
                    }
                }
            }

            if secciones.vacia {
                Text("Sin resultados")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func filaConAcciones(_ conversacion: Conversation, archivada: Bool) -> some View {
        Button {
            estado.abrir(conversacion)
        } label: {
            fila(conversacion)
        }
        .buttonStyle(.plain)
        .listRowBackground(Tema.superficie)
        .swipeActions(edge: .leading) {
            if archivada {
                Button {
                    estado.desarchivar(conversacion)
                } label: {
                    Label("Desarchivar", systemImage: "tray.and.arrow.up")
                }
                .tint(Tema.acento)
            } else {
                Button {
                    if conversacion.fijada {
                        estado.desfijar(conversacion)
                    } else {
                        estado.fijar(conversacion)
                    }
                } label: {
                    Label(
                        conversacion.fijada ? "Desfijar" : "Fijar",
                        systemImage: conversacion.fijada ? "pin.slash" : "pin"
                    )
                }
                .tint(.orange)

                Button {
                    tituloEditado = conversacion.titulo
                    aRenombrar = conversacion
                } label: {
                    Label("Renombrar", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                aBorrar = conversacion
            } label: {
                Label("Borrar", systemImage: "trash")
            }

            if !archivada {
                Button {
                    estado.archivar(conversacion)
                } label: {
                    Label("Archivar", systemImage: "archivebox")
                }
                .tint(.gray)
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
