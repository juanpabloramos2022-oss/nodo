import Foundation
import SwiftUI

import NodoCore

/// Lista de conversaciones guardadas: raiz de la pestana Chats.
///
/// Cada fila es un `NavigationLink` por valor (`id`): la raiz declara el
/// destino y es quien sincroniza la conversacion abierta. Crear un chat se
/// sigue delegando en la raiz.
struct ConversationsView: View {
    @EnvironmentObject private var estado: EstadoApp
    let alNuevo: (Bool) -> Void

    @State private var aBorrar: Conversation?
    @State private var aRenombrar: Conversation?
    @State private var tituloEditado = ""
    @State private var busqueda = ""
    /// Marca temporal del ultimo "mantener pulsado + Nuevo". Evita que el
    /// toque normal del mismo boton cree ademas un chat con memoria.
    @State private var ultimaPulsacionLarga: Date?

    /// Secciones ya ordenadas y filtradas por las reglas de NodoCore.
    private var secciones: SeccionesHistorial {
        HistorialConversaciones.secciones(de: estado.conversaciones, busqueda: busqueda)
    }

    var body: some View {
        Group {
            if estado.conversaciones.isEmpty {
                EstadoVacio(
                    icono: "bubble.left.and.bubble.right",
                    titulo: "Sin chats",
                    detalle: "Las conversaciones se guardan solas en el telefono."
                )
            } else {
                lista
            }
        }
        .background(Tema.fondo.ignoresSafeArea())
        .navigationTitle("Chats")
        .searchable(
            text: $busqueda,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Buscar en tus conversaciones"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                botonNuevo
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

    /// Boton + Nuevo: un toque crea un chat normal; mantener pulsado lo crea ya
    /// sin memoria (§4.6). El gesto largo vive en el mismo boton.
    private var botonNuevo: some View {
        Button {
            if let fecha = ultimaPulsacionLarga,
               Date().timeIntervalSince(fecha) < 0.8 {
                ultimaPulsacionLarga = nil
                return
            }
            alNuevo(false)
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityIdentifier("nuevo-chat")
        .accessibilityLabel("Nuevo chat")
        .accessibilityHint("Manten pulsado para crear un chat sin memoria")
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                ultimaPulsacionLarga = Date()
                alNuevo(true)
                // La marca se limpia sola por si el toque normal del boton no
                // llega a ejecutarse despues de la pulsacion larga.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    ultimaPulsacionLarga = nil
                }
            }
        )
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
        // Arrastrar la lista hacia abajo esconde el teclado del buscador sin
        // cerrar la pantalla ni perder lo escrito.
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func filaConAcciones(_ conversacion: Conversation, archivada: Bool) -> some View {
        NavigationLink(value: conversacion.id) {
            fila(conversacion)
        }
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
