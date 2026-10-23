import SwiftUI

import NodoCore

/// La pantalla de conversacion.
struct ChatView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var borrador = ""
    @FocusState private var escribiendo: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contenido

                if let error = estado.error {
                    AvisoError(texto: error) { estado.error = nil }
                        .padding(.bottom, 8)
                }

                barraDeEntrada
            }
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle(estado.conversacion.titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    selectorDeProveedor
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        estado.nuevaConversacion()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
    }

    /// Etiqueta con el proveedor activo.
    ///
    /// En la barra solo cabe el nombre; el modelo completo se lee al abrir el
    /// menu. Con un unico proveedor no hay menu: no hay nada que cambiar.
    @ViewBuilder
    private var selectorDeProveedor: some View {
        if let activo = estado.config.proveedorSeleccionado {
            if estado.config.proveedores.count > 1 {
                Menu {
                    ForEach(estado.config.proveedores) { proveedor in
                        Button {
                            estado.config.proveedorActivo = proveedor.id
                        } label: {
                            if proveedor.id == activo.id {
                                Label(textoDe(proveedor), systemImage: "checkmark")
                            } else {
                                Text(textoDe(proveedor))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(nombreDe(activo))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("Proveedor \(textoDe(activo))")
                .accessibilityHint("Cambia el proveedor para el proximo mensaje")
            } else {
                Text(nombreDe(activo))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityLabel("Proveedor \(textoDe(activo))")
            }
        } else {
            Text("Sin proveedor")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Nombre del proveedor, con un texto de reserva si esta sin poner.
    private func nombreDe(_ proveedor: ProviderConfig) -> String {
        let nombre = proveedor.nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        return nombre.isEmpty ? "Proveedor" : nombre
    }

    /// Nombre y modelo completos, solo para las filas del menu.
    private func textoDe(_ proveedor: ProviderConfig) -> String {
        let modelo = proveedor.modelo.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelo.isEmpty ? nombreDe(proveedor) : "\(nombreDe(proveedor)) · \(modelo)"
    }

    @ViewBuilder
    private var contenido: some View {
        if estado.conversacion.mensajes.isEmpty && !estado.enviando {
            EstadoVacio(
                icono: "bubble.left.and.bubble.right",
                titulo: "Nodo",
                detalle: "Escribe abajo para empezar. Tus claves se quedan en este telefono."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(estado.conversacion.mensajes) { mensaje in
                            BurbujaMensaje(mensaje: mensaje)
                                .id(mensaje.id.uuidString)
                        }

                        if puedeRegenerar {
                            botonRegenerar
                                .id(Self.marcaRegenerar)
                        }

                        if estado.enviando {
                            BurbujaEnCurso(texto: estado.textoEnCurso)
                                .id(Self.marcaEnCurso)
                        }
                    }
                    .padding(.horizontal, Tema.margen)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: estado.conversacion.mensajes.count) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onChange(of: estado.textoEnCurso) { _, _ in
                    desplazarAlFinal(proxy)
                }
                .onAppear { desplazarAlFinal(proxy) }
            }
        }
    }

    private static let marcaEnCurso = "nodo-en-curso"
    private static let marcaRegenerar = "nodo-regenerar"

    private func desplazarAlFinal(_ proxy: ScrollViewProxy) {
        let destino: String?
        if estado.enviando {
            destino = Self.marcaEnCurso
        } else if puedeRegenerar {
            destino = Self.marcaRegenerar
        } else {
            destino = estado.conversacion.mensajes.last?.id.uuidString
        }

        guard let destino else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(destino, anchor: .bottom)
        }
    }

    /// Solo se puede regenerar la ultima respuesta cuando el turno ya termino.
    private var puedeRegenerar: Bool {
        !estado.enviando && estado.conversacion.mensajes.last?.rol == .asistente
    }

    /// Boton bajo la ultima respuesta para volver a generarla.
    private var botonRegenerar: some View {
        Button {
            estado.regenerar()
        } label: {
            Label("Regenerar", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Tema.textoSuave)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Tema.superficie)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Regenerar la ultima respuesta")
    }

    private var barraDeEntrada: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Escribe un mensaje", text: $borrador, axis: .vertical)
                .lineLimit(1...6)
                .focused($escribiendo)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Tema.superficie)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .foregroundStyle(.white)

            Button(action: accion) {
                Image(systemName: estado.enviando ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(botonActivo ? Tema.acento : Tema.superficieAlta)
                    .clipShape(Circle())
            }
            .disabled(!botonActivo)
        }
        .padding(.horizontal, Tema.margen)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Tema.fondo)
    }

    private var botonActivo: Bool {
        estado.enviando || !borrador.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func accion() {
        if estado.enviando {
            estado.cancelar()
            return
        }
        let texto = borrador
        borrador = ""
        estado.enviar(texto)
    }
}
