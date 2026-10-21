import SwiftUI

import NodoCore

/// Colores y medidas compartidas.
///
/// Se definen aqui y no en cada pantalla para que el tono no se vaya
/// desviando a medida que se anaden vistas.
enum Tema {
    static let fondo = Color(red: 0.05, green: 0.055, blue: 0.075)
    static let superficie = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let superficieAlta = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let acento = Color(red: 0.42, green: 0.63, blue: 1.0)
    static let textoSuave = Color.white.opacity(0.62)
    static let borde = Color.white.opacity(0.09)

    static let radio: CGFloat = 16
    static let margen: CGFloat = 16
}

/// Burbuja de un mensaje.
struct BurbujaMensaje: View {
    let mensaje: ChatMessage

    var esDelUsuario: Bool { mensaje.rol == .usuario }
    var esHerramienta: Bool { mensaje.rol == .herramienta }

    var body: some View {
        HStack {
            if esDelUsuario { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 6) {
                if esHerramienta {
                    etiquetaHerramienta
                }

                if !mensaje.texto.isEmpty {
                    Text(mensaje.texto)
                        .font(.body)
                        .textSelection(.enabled)
                        .foregroundStyle(esHerramienta ? Tema.textoSuave : Color.white)
                }

                if !mensaje.toolCalls.isEmpty {
                    ForEach(mensaje.toolCalls, id: \.id) { llamada in
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.caption2)
                            Text(llamada.nombre)
                                .font(.caption.monospaced())
                        }
                        .foregroundStyle(Tema.acento)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(fondo)
            .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))

            if !esDelUsuario { Spacer(minLength: 48) }
        }
    }

    private var etiquetaHerramienta: some View {
        Text("herramienta")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Tema.acento.opacity(0.8))
    }

    private var fondo: Color {
        if esDelUsuario { return Tema.acento.opacity(0.22) }
        if esHerramienta { return Tema.superficie.opacity(0.7) }
        return Tema.superficie
    }
}

/// Texto que se esta escribiendo ahora mismo, con el cursor al final.
struct BurbujaEnCurso: View {
    let texto: String

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                if texto.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(texto.isEmpty ? "Pensando..." : texto)
                    .font(.body)
                    .foregroundStyle(texto.isEmpty ? Tema.textoSuave : Color.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))

            Spacer(minLength: 48)
        }
    }
}

/// Aviso de error, con boton para cerrarlo.
struct AvisoError: View {
    let texto: String
    let cerrar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(texto)
                .font(.footnote)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: cerrar) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Tema.margen)
    }
}

/// Pantalla vacia con un mensaje.
struct EstadoVacio: View {
    let icono: String
    let titulo: String
    let detalle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icono)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tema.acento.opacity(0.7))
            Text(titulo)
                .font(.headline)
            Text(detalle)
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
