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
///
/// B4-BUS: la busqueda tampoco se resuelve aqui. El campo escribe en `busqueda`
/// y la vista pinta lo que devuelve la proyeccion de la app
/// (`EstadoApp.filasDeBusqueda`), que es la misma consulta de solo lectura que
/// usa `elementosVisiblesDeBusqueda`. Con el campo vacio esa proyeccion es la
/// lista completa de siempre, en su orden habitual.
struct ConversationsView: View {
    @EnvironmentObject private var estado: EstadoApp
    let alNuevo: (Bool) -> Void
    /// Abre un hilo de Chat Temporal (B2.2) con UN toque desde la lista (R41).
    let alTemporal: () -> Void

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

    /// Filas del segmento activo ya proyectadas: la consulta de busqueda
    /// (solo lectura) mas el segmento y el orden del nucleo. Cada fila trae su
    /// elemento visible (titulo + vista previa) y la conversacion que abre.
    private var filasVisibles: [FilaBusquedaVisible] {
        estado.filasDeBusqueda(busqueda, segmento: segmento)
    }

    /// Proyeccion visible de la busqueda. Se usa para el estado vacio
    /// explicito, que es un elemento del catalogo (`SearchEmptyState`), no un
    /// texto suelto de la vista.
    private var proyeccionBusqueda: [ElementoBusquedaVisible] {
        estado.elementosVisiblesDeBusqueda(busqueda, segmento: segmento)
    }

    /// Termino del estado vacio, o nil si hay filas que pintar.
    private var terminoSinResultados: String? {
        guard let primero = proyeccionBusqueda.first,
              case .sinResultados(let termino) = primero
        else {
            return nil
        }
        return termino
    }

    /// Termino escrito, ya recortado, tal como lo ve la proyeccion.
    private var terminoEscrito: String {
        busqueda.trimmingCharacters(in: .whitespacesAndNewlines)
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
                botonTemporal
            }
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

    /// Boton «Chat temporal»: UN toque desde la pantalla principal (R41).
    ///
    /// Abre un hilo que no se guarda en la lista, no usa la Memoria y lo
    /// declara en su cabecera. Es la entrada propia del modo temporal (B2.2);
    /// el chat normal conserva su camino de siempre (el + y su pulsacion
    /// larga sin memoria, sin cambios).
    private var botonTemporal: some View {
        Button {
            alTemporal()
        } label: {
            Image(systemName: "timer")
        }
        .accessibilityIdentifier("nuevo-chat-temporal")
        .accessibilityLabel("Chat temporal")
        .accessibilityHint(
            "Abre un chat que no se guarda en la lista ni usa tu memoria"
        )
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
            ForEach(filasVisibles, id: \.conversacion.id) { fila in
                filaConAcciones(fila.conversacion, elemento: fila.elemento)
            }

            // Sin coincidencias la pestana no queda en blanco: se pinta el
            // estado vacio de la proyeccion con el termino buscado.
            if let termino = terminoSinResultados {
                SearchEmptyState(termino: termino)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Arrastrar la lista hacia abajo esconde el teclado del buscador sin
        // cerrar la pantalla ni perder lo escrito.
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func filaConAcciones(
        _ conversacion: Conversation,
        elemento: ElementoBusquedaVisible
    ) -> some View {
        NavigationLink(value: conversacion.id) {
            fila(conversacion, elemento: elemento)
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
    /// modelo usado.
    ///
    /// El texto visible (titulo y vista previa) sale del elemento proyectado;
    /// con el campo vacio la proyeccion devuelve la vista previa de siempre
    /// (ultimo mensaje, 80 caracteres), asi que la lista sin busqueda se ve
    /// exactamente igual que antes. Con un termino escrito la vista previa es
    /// la del mensaje que coincide, para que el resultado se explique solo.
    /// El costo y el modelo los resuelve `datosFila` del nucleo: la vista no
    /// calcula costos ni deduce modelos.
    private func fila(
        _ conversacion: Conversation,
        elemento: ElementoBusquedaVisible
    ) -> some View {
        let datos = HistorialConversaciones.datosFila(
            de: conversacion,
            proveedores: estado.config.proveedores
        )
        let vistaPrevia: String
        let titulo: String

        if case .resultadoBusqueda(let tituloProyectado, let previaProyectada) = elemento,
           !terminoEscrito.isEmpty {
            titulo = tituloProyectado
            vistaPrevia = previaProyectada.isEmpty
                ? Self.previstaDeRespaldo(conversacion)
                : previaProyectada
        } else {
            titulo = conversacion.titulo
            vistaPrevia = datos.vistaPrevia.isEmpty
                ? Self.previstaDeRespaldo(conversacion)
                : datos.vistaPrevia
        }

        return SearchResultRow(
            titulo: titulo,
            vistaPrevia: vistaPrevia,
            fijada: conversacion.fijada,
            costo: datos.costo,
            modelo: datos.modelo,
            esActual: estado.conversacion.id == conversacion.id
        )
    }

    /// Texto de respaldo de la segunda linea cuando no hay vista previa.
    private static func previstaDeRespaldo(_ conversacion: Conversation) -> String {
        conversacion.mensajes.isEmpty ? "Sin mensajes" : "…"
    }
}
