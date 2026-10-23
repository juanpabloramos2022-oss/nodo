import SwiftUI
import UIKit

import NodoCore

/// Tarjeta de Bienvenida del Motor en un chat sin mensajes (§3.2).
///
/// Se alimenta SOLO de la configuracion real: proveedor y modelo activos, si
/// hay clave guardada y el flag de Memoria de este chat. Sustituye al estado
/// vacio generico y desaparece en cuanto entra el primer mensaje.
struct TarjetaBienvenidaView: View {
    @EnvironmentObject private var estado: EstadoApp

    /// "Empezar a chatear" solo enfoca la caja; no envia nada.
    let alEmpezar: () -> Void
    let alEditarMemoria: () -> Void
    let alGestionarModelos: () -> Void

    /// Aviso local del portapapeles, bajo la tarjeta.
    @State private var aviso: String?

    private var proveedor: ProviderConfig? {
        estado.config.proveedorSeleccionado
    }

    private var proveedorLimpio: String {
        guard let proveedor else { return "Sin proveedor" }
        return NombresLimpios.proveedor(
            nombre: proveedor.nombre,
            baseURL: proveedor.baseURL
        )
    }

    private var modeloLimpio: String {
        guard let proveedor else { return "Sin modelo" }
        let limpio = NombresLimpios.modelo(proveedor.modelo)
        return limpio.isEmpty ? "Sin modelo" : limpio
    }

    /// Sin clave guardada la tarjeta no puede fingir que hay conexion.
    private var faltaClave: Bool {
        guard let proveedor else { return true }
        return (estado.clave(para: proveedor) ?? "").isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                tarjeta

                if let aviso {
                    Text(aviso)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("aviso-portapapeles")
                }
            }
            .padding(Tema.margen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("tarjeta-bienvenida")
    }

    private var tarjeta: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Este chat usa \(proveedorLimpio) · \(modeloLimpio)")
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if faltaClave {
                Text("⚠️ Falta la clave de este proveedor")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    pegarClave()
                } label: {
                    Text("📋 Pegar clave desde el portapapeles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Tema.acento)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pegar-clave")
            } else {
                Button {
                    alEmpezar()
                } label: {
                    Text("Empezar a chatear")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Tema.acento)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("empezar-chatear")
            }

            Divider()
                .overlay(Tema.borde)

            HStack(spacing: 10) {
                Menu {
                    listaModelos(
                        proveedores: estado.config.proveedores,
                        activo: estado.config.proveedorSeleccionado?.id,
                        alElegir: { estado.cambiarProveedor($0) },
                        alGestionar: alGestionarModelos
                    )
                } label: {
                    etiquetaAccion("Cambiar modelo")
                }
                .accessibilityIdentifier("cambiar-modelo-tarjeta")

                Button {
                    alEditarMemoria()
                } label: {
                    etiquetaAccion("Ver o editar mi memoria")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memoria-tarjeta")
            }

            Toggle(
                isOn: Binding(
                    get: { !estado.conversacion.sinMemoria },
                    set: { _ in estado.alternarSinMemoria() }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memoria en este chat")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(estado.conversacion.sinMemoria ? "Apagada" : "Activa")
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                }
            }
            .tint(Tema.acento)
            .accessibilityIdentifier("memoria-toggle-tarjeta")
        }
        .padding(16)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                .stroke(Tema.borde, lineWidth: 1)
        }
    }

    private func etiquetaAccion(_ texto: String) -> some View {
        Text(texto)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Tema.superficieAlta)
            .clipShape(Capsule())
    }

    /// Lee el portapapeles y guarda la clave con la regla de host (§3.7).
    ///
    /// `guardarClave` ya propaga a los companeros del mismo host. Si el texto
    /// esta vacio no se toca nada: se avisa bajo la tarjeta.
    private func pegarClave() {
        guard let proveedor else {
            aviso = "No hay ningún proveedor configurado."
            return
        }

        let texto = (UIPasteboard.general.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else {
            aviso = "El portapapeles está vacío o no contiene una clave."
            return
        }

        if estado.guardarClave(texto, para: proveedor) {
            aviso = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            aviso = "No se pudo guardar la clave."
        }
    }
}
