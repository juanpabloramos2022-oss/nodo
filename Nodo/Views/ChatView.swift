import Foundation
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

                resumenDelChat

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
                            VStack(alignment: .leading, spacing: 2) {
                                BurbujaMensaje(mensaje: mensaje)

                                if mensaje.rol == .asistente,
                                   let linea = lineaDeConsumo(mensaje) {
                                    Text(linea)
                                        .font(.caption2)
                                        .foregroundStyle(Tema.textoSuave)
                                        .padding(.leading, 14)
                                }
                            }
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

    /// Consumo acumulado del chat, si algun mensaje trae cifras.
    private var usoDelChat: UsoTokens? {
        CostoEstimado.usoAcumulado(de: estado.conversacion.mensajes)
    }

    /// Fila fina con el acumulado del chat, encima de la barra de entrada.
    @ViewBuilder
    private var resumenDelChat: some View {
        if let uso = usoDelChat {
            HStack {
                Text(textoResumen(uso))
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tema.margen)
            .padding(.top, 6)
        }
    }

    private func textoResumen(_ uso: UsoTokens) -> String {
        var texto = "Chat: \(uso.total) tokens"
        if let costo = costoDe(uso) {
            texto += " · " + textoCosto(costo)
        }
        return texto
    }

    /// Linea discreta bajo una respuesta: tokens y, si hay precios, costo.
    private func lineaDeConsumo(_ mensaje: ChatMessage) -> String? {
        guard let uso = mensaje.uso else { return nil }
        var linea = "\(uso.entrada) de entrada · \(uso.salida) de salida"
        if let costo = costoDe(uso) {
            linea += " · " + textoCosto(costo)
        }
        return linea
    }

    private func costoDe(_ uso: UsoTokens) -> Double? {
        let proveedor = estado.config.proveedorSeleccionado
        return CostoEstimado.costo(
            uso: uso,
            precioEntrada: proveedor?.precioEntradaPorMillon,
            precioSalida: proveedor?.precioSalidaPorMillon
        )
    }

    private func textoCosto(_ costo: Double) -> String {
        "≈$\(String(format: "%.4f", costo)) estimado"
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
