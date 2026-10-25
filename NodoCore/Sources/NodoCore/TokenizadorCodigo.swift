import Foundation

/// Clase visual de un token de codigo (B4-COD).
///
/// No es una regla de negocio: solo decide de que color se pinta un tramo. El
/// texto nunca se reescribe; la tokenizacion es una capa de presentacion sobre
/// el crudo exacto que ya extrajo `BloquesRespuesta`.
public enum ClaseTokenCodigo: String, Equatable, Sendable {
    case palabraClave
    case cadena
    case numero
    case comentario
    case ordinario
}

/// Un tramo del codigo crudo con su clase visual.
///
/// La suma de `texto` de todos los tokens de una tokenizacion es, caracter por
/// caracter, el crudo de entrada. Esa es la garantia que impide que colorear
/// cambie el contenido copiado o seleccionable.
public struct TokenCodigo: Equatable, Sendable {
    public let texto: String
    public let clase: ClaseTokenCodigo

    public init(texto: String, clase: ClaseTokenCodigo) {
        self.texto = texto
        self.clase = clase
    }
}

/// Tokenizador determinista para el resaltado visual de bloques de codigo.
///
/// Decision de alcance (B4-COD, §1.2): se resaltan Swift y Python, que son los
/// dos lenguajes de los humos de la partida. Cualquier otro lenguaje declarado
/// se pinta SIN tokenizar, con su texto crudo intacto: no se inventan paletas
/// ni gramaticas fuera de la fijada por la spec.
///
/// La segmentacion del mensaje (cercas de Markdown) NO vive aqui: sigue en
/// `BloquesRespuesta`, por lineas y sin expresiones regulares de negocio. Las
/// expresiones regulares de este archivo solo clasifican tokens para colorear.
public enum TokenizadorCodigo {
    /// Lenguajes con resaltado propio (alias en minusculas).
    public static let lenguajesConResaltado: Set<String> = [
        "swift", "python", "py"
    ]

    /// Lenguaje normalizado (minusculas, sin espacios) o `nil` si no declaro.
    public static func normalizar(_ lenguaje: String?) -> String? {
        guard let lenguaje else { return nil }
        let limpio = lenguaje
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return limpio.isEmpty ? nil : limpio
    }

    /// True si el lenguaje tiene resaltado propio.
    public static func reconoce(_ lenguaje: String?) -> Bool {
        guard let normalizado = normalizar(lenguaje) else { return false }
        return lenguajesConResaltado.contains(normalizado)
    }

    /// Tokens que cubren TODO el crudo, en orden.
    ///
    /// Devuelve `nil` cuando el lenguaje no se reconoce: el llamador pinta el
    /// texto tal cual, sin tokenizar. Para un crudo vacio devuelve la lista
    /// vacia.
    public static func tokens(
        textoCrudo: String,
        lenguaje: String?
    ) -> [TokenCodigo]? {
        guard let normalizado = normalizar(lenguaje),
              lenguajesConResaltado.contains(normalizado) else {
            return nil
        }
        guard !textoCrudo.isEmpty else { return [] }

        let patron = normalizado == "swift" ? patronSwift : patronPython
        guard let regex = try? NSRegularExpression(pattern: patron) else {
            // Sin motor de resaltado se pinta el crudo: nunca se pierde texto.
            return nil
        }

        let completo = textoCrudo as NSString
        let rangoCompleto = NSRange(location: 0, length: completo.length)
        var tokens: [TokenCodigo] = []
        var cursor = 0

        for coincidencia in regex.matches(
            in: textoCrudo,
            range: rangoCompleto
        ) {
            let rango = coincidencia.range
            guard rango.location != NSNotFound, rango.length > 0 else {
                continue
            }
            if rango.location > cursor {
                let hueco = NSRange(
                    location: cursor,
                    length: rango.location - cursor
                )
                tokens.append(
                    TokenCodigo(
                        texto: completo.substring(with: hueco),
                        clase: .ordinario
                    )
                )
            }
            tokens.append(
                TokenCodigo(
                    texto: completo.substring(with: rango),
                    clase: clase(de: coincidencia)
                )
            )
            cursor = rango.location + rango.length
        }

        if cursor < completo.length {
            let resto = NSRange(
                location: cursor,
                length: completo.length - cursor
            )
            tokens.append(
                TokenCodigo(
                    texto: completo.substring(with: resto),
                    clase: .ordinario
                )
            )
        }

        return tokens
    }

    // MARK: - Motores de resaltado

    /// Grupo 1 comentario, 2 cadena, 3 numero, 4 palabra clave.
    private static let patronSwift = #"""
    (//[^\n]*)|("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*")|(\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?)\b)|(\b(?:associatedtype|class|deinit|enum|extension|fileprivate|func|import|init|inout|internal|let|open|operator|private|protocol|public|rethrows|static|struct|subscript|typealias|var|break|case|catch|continue|default|defer|do|else|fallthrough|for|guard|if|in|repeat|return|switch|throw|throws|try|where|while|as|is|nil|super|self|Self|true|false|await|async|some|any)\b)
    """#

    /// Grupo 1 comentario, 2 cadena, 3 numero, 4 palabra clave.
    private static let patronPython = #"""
    (#[^\n]*)|("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|(\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?)\b)|(\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|match|case)\b)
    """#

    private static func clase(
        de coincidencia: NSTextCheckingResult
    ) -> ClaseTokenCodigo {
        if coincidencia.range(at: 1).location != NSNotFound {
            return .comentario
        }
        if coincidencia.range(at: 2).location != NSNotFound {
            return .cadena
        }
        if coincidencia.range(at: 3).location != NSNotFound {
            return .numero
        }
        return .palabraClave
    }
}
