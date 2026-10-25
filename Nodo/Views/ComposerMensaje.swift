import SwiftUI

/// Composer unico de la app: Chat y Tarea envian con EL MISMO componente.
///
/// POR QUE se extrajo de ChatView: la spec de B3-A exige que el hilo de Tarea
/// use el mismo composer que Chat (R38), no una copia parecida. Todo lo que
/// cambia entre los dos espacios entra por parametro; el comportamiento de la
/// caja (lineas, dictado, boton Enviar/Detener, barra Listo) es identico.
struct ComposerMensaje: View {
    @Binding var texto: String
    let placeholder: String
    /// Deshabilita la caja y el micro (compactando, generando plan de chat).
    var deshabilitado: Bool = false
    /// Bloquea solo el envio: la caja sigue escribible (plan en vuelo).
    var bloqueoEnvio: Bool = false
    /// Muestra Detener en lugar de Enviar y llama a `alDetener`.
    var enviando: Bool = false
    var dictando: Bool = false
    var alEnviar: () -> Void
    var alDetener: (() -> Void)?
    var alDictar: (() -> Void)?
    @FocusState.Binding var enfocado: Bool

    private var puedeEnviar: Bool {
        guard !deshabilitado, !bloqueoEnvio else { return false }
        return enviando
            || !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                placeholder,
                text: $texto,
                axis: .vertical
            )
            .lineLimit(1...5)
            .focused($enfocado)
            .disabled(deshabilitado)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .foregroundStyle(.white)
            .accessibilityIdentifier("caja-mensaje")

            // Micrófono a la izquierda del botón Enviar. Rojo mientras dicta.
            if let alDictar {
                Button(action: alDictar) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(dictando ? Color.red : Tema.superficieAlta)
                        .clipShape(Circle())
                }
                .disabled(deshabilitado || enviando)
                .accessibilityLabel(dictando ? "Detener dictado" : "Dictar")
                .accessibilityIdentifier("boton-dictado")
            }

            Button(action: accion) {
                Image(systemName: enviando ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(puedeEnviar ? Tema.acento : Tema.superficieAlta)
                    .clipShape(Circle())
            }
            .disabled(!puedeEnviar)
            .accessibilityLabel(enviando ? "Detener" : "Enviar")
            .accessibilityIdentifier("enviar-mensaje")
        }
        .padding(.horizontal, Tema.margen)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Tema.fondo)
    }

    private func accion() {
        if enviando {
            alDetener?()
            return
        }
        alEnviar()
    }
}
