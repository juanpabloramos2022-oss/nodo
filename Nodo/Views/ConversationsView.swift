import Foundation
import SwiftUI

import NodoCore

/// Lista de conversaciones guardadas: raiz de la pestana Chats.
///
/// Cada fila es un `NavigationLink` por valor (`id`): la raiz declara el
/// destino y es quien sincroniza la conversacion abierta. Crear un chat se
/// sigue delegando en la raiz.
///
/// La lista NO ordena ni filtra por su cuenta: el orden (fijadas primero y,
/// dentro de cada grupo, actividad reciente) y el segmento Activos/Archivados
/// salen de NodoCore. La vista solo decide que segmento esta seleccionado y
/// pinta los datos ya resueltos de cada fila.
struct ConversationsView: View {
    @EnvironmentObject private var estado: EstadoApp
    let alNuevo: (Bool) -> Void

    @State private var aBorrar: Conversation?
    @State private var aRenombrar: Conversation?
    @State private var tituloEditado = ""
    @State private var busqueda = ""
    /// Segmento visible de la lista. Cambiarlo no toca `busqueda`: el buscador
    /// sigue filtrando dentro del segmento elegido (§3.1/§5.2).
    @State private var segmento: SegmentoChats = .activos
    /// Marca temporal del ultimo "mantener pulsado + Nuevo". Evita que el
    /// toque normal del mismo boton cree ademas un chat con memoria.
    @State private var ultimaPulsacionLarga: Date?

    /// Conversaciones del segmento activo, ya filtradas por la busqueda y
    /// ordenadas por el nucleo (fijadas arriba, luego actividad reciente).
    private var conversacionesVisibles: [Conversation] {
        let coincidentes = estado.conversaciones.filter {
            HistorialConversaciones.coincide($0, con: busqueda)
        }
        let delSegmento = HistorialConversaciones.enSegmento(
            segmento,
            de: coincidentes
        )
        return HistorialConversaciones.ordenar(delSegmento)
    }

    var body: some View {
        VStack(spacing: 0) {
            // El segmento vive fuera de la lista para que siga visible aunque
            // la lista se desplace o el buscador tenga el teclado abierto.
            selectorSegmento

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

    /// Segmento Activos | Archivados, siempre bajo el buscador.
    private var selectorSegmento: some View {
        Picker("Segmento", selection: $segmento) {
            ForEach(SegmentoChats.allCases) { valor in
                Text(valor.titulo).tag(valor)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Tema.margen)
        .padding(.vertical, 8)
        .background(Tema.fondo)
        .accessibilityIdentifier("segmento-chats")
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
            ForEach(conversacionesVisibles) { conversacion in
                filaConAcciones(conversacion)
            }

            if conversacionesVisibles.isEmpty {
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
    private func filaConAcciones(_ conversacion: Conversation) -> some View {
        NavigationLink(value: conversacion.id) {
            fila(conversacion)
        }
        .listRowBackground(Tema.superficie)
        // Deslizar a la derecha: Fijar/Desfijar. Renombrar vive en la
        // pulsacion larga, no en el deslizamiento.
        .swipeActions(edge: .leading) {
            Button {
                alternarFijado(conversacion)
            } label: {
                Label(
                    conversacion.fijada ? "Desfijar" : "Fijar",
                    systemImage: conversacion.fijada ? "pin.slash" : "pin"
                )
            }
            .tint(.orange)
        }
        // Deslizar a la izquierda: Archivar/Desarchivar y Borrar.
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                aBorrar = conversacion
            } label: {
                Label("Borrar", systemImage: "trash")
            }

            Button {
                alternarArchivado(conversacion)
            } label: {
                Label(
                    conversacion.archivada ? "Desarchivar" : "Archivar",
                    systemImage: conversacion.archivada
                        ? "tray.and.arrow.up"
                        : "archivebox"
                )
            }
            .tint(.gray)
        }
        // Pulsacion larga: el menu completo de la fila (§3.1/§5.3).
        .contextMenu {
            menuDeFila(conversacion)
        }
    }

    @ViewBuilder
    private func menuDeFila(_ conversacion: Conversation) -> some View {
        Button {
            alternarFijado(conversacion)
        } label: {
            Label(
                conversacion.fijada ? "Desfijar" : "Fijar",
                systemImage: conversacion.fijada ? "pin.slash" : "pin"
            )
        }

        Button {
            tituloEditado = conversacion.titulo
            aRenombrar = conversacion
        } label: {
            Label("Renombrar", systemImage: "pencil")
        }

        Button {
            alternarArchivado(conversacion)
        } label: {
            Label(
                conversacion.archivada ? "Desarchivar" : "Archivar",
                systemImage: conversacion.archivada
                    ? "tray.and.arrow.up"
                    : "archivebox"
            )
        }

        Divider()

        Button(role: .destructive) {
            aBorrar = conversacion
        } label: {
            Label("Borrar", systemImage: "trash")
        }
    }

    private func alternarFijado(_ conversacion: Conversation) {
        if conversacion.fijada {
            estado.desfijar(conversacion)
        } else {
            estado.fijar(conversacion)
        }
    }

    private func alternarArchivado(_ conversacion: Conversation) {
        if conversacion.archivada {
            estado.desarchivar(conversacion)
        } else {
            estado.archivar(conversacion)
        }
    }

    /// Fila en dos lineas: titulo + pastilla de costo, y vista previa + ultimo
    /// modelo usado. Los datos salen de `datosFila` del nucleo; la vista no
    /// calcula costos ni deduce modelos.
    private func fila(_ conversacion: Conversation) -> some View {
        let datos = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: estado.config.proveedores
        )
        let vistaPrevia = datos.vistaPrevia.isEmpty
            ? (conversacion.mensajes.isEmpty ? "Sin mensajes" : "…")
            : datos.vistaPrevia

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if estado.conversacion.id == conversacion.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Tema.acento)
                }

                Text(conversacion.titulo)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)

                if conversacion.fijada {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Fijado")
                        .accessibilityIdentifier("fijado-fila")
                }

                Spacer(minLength: 8)

                // Solo se pinta la pastilla cuando el nucleo pudo resolver el
                // costo con los precios del proveedor de ESTE chat.
                if let costo = datos.costo {
                    Text("≈$\(String(format: "%.4f", costo))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Tema.acento)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Tema.acento.opacity(0.15))
                        .clipShape(Capsule())
                        .layoutPriority(2)
                        .accessibilityIdentifier("costo-fila")
                }
            }

            HStack(spacing: 8) {
                Text(vistaPrevia)
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                // Etiqueta del ultimo modelo usado en esta conversacion, con
                // el nombre limpio que ya resolvio el nucleo.
                if !datos.modelo.isEmpty {
                    Text(datos.modelo)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Tema.acento.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Tema.acento.opacity(0.12))
                        .clipShape(Capsule())
                        .layoutPriority(2)
                        .accessibilityIdentifier("modelo-fila")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
