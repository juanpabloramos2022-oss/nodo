import Combine
import SwiftUI
import UIKit

import NodoCore

/// Costura del portapapeles del sistema.
///
/// Existe para que el boton [Copiar] del bloque se pruebe con un doble: el
/// test comprueba que lo que se entrega es el crudo exacto y nada mas, sin
/// depender del `UIPasteboard` del simulador.
protocol Portapapeles {
    func escribir(_ texto: String)
}

/// Portapapeles real de iOS.
struct PortapapelesSistema: Portapapeles {
    func escribir(_ texto: String) {
        UIPasteboard.general.string = texto
    }
}

/// Estado del boton [Copiar] de UN bloque de codigo.
///
/// Copia siempre `textoCrudo`, sin cercas, sin nombre de lenguaje y sin la
/// prosa que rodea al bloque. Tras copiar deja `copiado = true` durante unos
/// segundos y vuelve solo a `false`; un toque nuevo reinicia la confirmacion.
final class CopiadorCodigo: ObservableObject {
    @Published private(set) var copiado = false

    let textoCrudo: String
    private let portapapeles: Portapapeles
    private let duracionConfirmacion: TimeInterval
    /// Numero de toques: una confirmacion vieja no apaga la de un toque nuevo.
    private var generacion = 0

    init(
        textoCrudo: String,
        portapapeles: Portapapeles = PortapapelesSistema(),
        duracionConfirmacion: TimeInterval = 2.0
    ) {
        self.textoCrudo = textoCrudo
        self.portapapeles = portapapeles
        self.duracionConfirmacion = duracionConfirmacion
    }

    /// Entrega el crudo exacto al portapapeles y muestra «Copiado».
    func copiar() {
        portapapeles.escribir(textoCrudo)
        copiado = true
        generacion += 1
        let actual = generacion

        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, duracionConfirmacion)
        ) { [weak self] in
            guard let self, self.generacion == actual else { return }
            self.copiado = false
        }
    }
}

/// Resaltado visual del bloque: tokens de NodoCore a colores de `Tema`.
///
/// Solo presentacion: no reordena, no reformatea y no cambia un caracter. Si
/// el lenguaje no se reconoce, devuelve el crudo tal cual (sin tokenizar).
enum ResaltadoCodigo {
    /// Texto con color por clase de token.
    static func atribuido(
        _ textoCrudo: String,
        lenguaje: String?
    ) -> AttributedString {
        guard let tokens = TokenizadorCodigo.tokens(
            textoCrudo: textoCrudo,
            lenguaje: lenguaje
        ) else {
            return AttributedString(textoCrudo)
        }

        var resultado = AttributedString()
        for token in tokens {
            var parte = AttributedString(token.texto)
            parte.foregroundColor = color(de: token.clase)
            resultado.append(parte)
        }
        return resultado
    }

    /// Paleta fijada por la spec §1.2: acento, naranja, purpura, texto suave.
    static func color(de clase: ClaseTokenCodigo) -> Color {
        switch clase {
        case .palabraClave:
            return Tema.acento
        case .cadena:
            return .orange
        case .numero:
            return .purple
        case .comentario:
            return Tema.textoSuave
        case .ordinario:
            return .white
        }
    }
}

/// Bloque de codigo de una respuesta: UN solo componente para todos los
/// caminos que pintan un `SegmentoRespuesta.codigo`.
///
/// Cabecera con el lenguaje (o «Código» si la cerca no lo declaro) y una sola
/// accion: [Copiar], que pasa a «Copiado» unos segundos. Sin scroll horizontal
/// propio: el texto se ajusta por salto de linea suave y las lineas originales
/// se conservan intactas en el crudo copiado. La seleccion de texto sigue
/// habilitada dentro del bloque.
struct BloqueCodigo: View {
    let lenguaje: String?
    let textoCrudo: String

    @StateObject private var copiador: CopiadorCodigo

    init(
        lenguaje: String?,
        textoCrudo: String,
        portapapeles: Portapapeles = PortapapelesSistema()
    ) {
        self.lenguaje = lenguaje
        self.textoCrudo = textoCrudo
        _copiador = StateObject(
            wrappedValue: CopiadorCodigo(
                textoCrudo: textoCrudo,
                portapapeles: portapapeles
            )
        )
    }

    /// Titulo de la cabecera. Normaliza la capitalizacion SOLO en la vista:
    /// la traza sigue emitiendo el lenguaje crudo de la cerca (`swift`).
    static func tituloCabecera(_ lenguaje: String?) -> String {
        guard let normalizado = TokenizadorCodigo.normalizar(lenguaje) else {
            return "Código"
        }
        switch normalizado {
        case "swift": return "Swift"
        case "python", "py": return "Python"
        case "js", "javascript": return "JavaScript"
        case "ts", "typescript": return "TypeScript"
        case "json": return "JSON"
        case "html": return "HTML"
        case "css": return "CSS"
        case "sql": return "SQL"
        case "yaml", "yml": return "YAML"
        case "bash", "sh", "shell", "zsh": return "Shell"
        case "md", "markdown": return "Markdown"
        case "objc", "objective-c": return "Objective-C"
        case "c++", "cpp": return "C++"
        default:
            let inicial = String(normalizado.prefix(1)).uppercased()
            return inicial + String(normalizado.dropFirst())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(Self.tituloCabecera(lenguaje))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    copiador.copiar()
                } label: {
                    Text(copiador.copiado ? "Copiado" : "Copiar")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Tema.acento)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Tema.acento.opacity(0.12))
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    copiador.copiado ? "Copiado" : "Copiar código"
                )
                .accessibilityIdentifier("copiar-codigo")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 4)

            Text(
                ResaltadoCodigo.atribuido(textoCrudo, lenguaje: lenguaje)
            )
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficieAlta)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
