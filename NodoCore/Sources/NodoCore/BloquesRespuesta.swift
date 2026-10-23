import Foundation

/// Un tramo de una respuesta del asistente, ya separado para pintarlo.
///
/// Los bloques de codigo se guardan aparte del texto para que la vista pueda
/// ponerles su boton Copiar codigo (§4.7) sin volver a analizar la respuesta.
public enum BloqueRespuesta: Equatable {
    case texto(String)
    case codigo(lenguaje: String?, contenido: String)
}

/// Parser de bloques de respuesta con cercos de Markdown.
///
/// Reglas (SPEC §4.1/§4.7):
/// - Un cerco es una linea que empieza por tres comillas invertidas. La primera
///   palabra tras el cerco es el lenguaje; puede faltar.
/// - El contenido del codigo se conserva EXACTO, incluidas sus lineas vacias
///   internas, pero sin el salto de linea que precede al cerco de cierre.
/// - Los tramos de texto se recortan de saltos de linea en los bordes y los que
///   quedan vacios se omiten.
/// - Un cerco sin cerrar: todo lo que sigue es codigo.
/// - Sin cercos: un solo bloque con el texto tal cual (vacio -> lista vacia).
public enum BloquesRespuesta {
    public static func parsear(_ texto: String) -> [BloqueRespuesta] {
        let lineas = texto.components(separatedBy: "\n")
        var bloques: [BloqueRespuesta] = []
        var tramoTexto: [String] = []
        var hayCercos = false

        func volcarTexto() {
            let unido = tramoTexto.joined(separator: "\n")
            let limpio = unido.trimmingCharacters(in: .newlines)
            if !limpio.isEmpty {
                bloques.append(.texto(limpio))
            }
            tramoTexto.removeAll()
        }

        var indice = 0
        while indice < lineas.count {
            let linea = lineas[indice]
            guard linea.hasPrefix("```") else {
                tramoTexto.append(linea)
                indice += 1
                continue
            }

            hayCercos = true
            volcarTexto()

            let info = String(linea.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lenguaje = info
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map(String.init)

            var contenido: [String] = []
            indice += 1
            while indice < lineas.count && !lineas[indice].hasPrefix("```") {
                contenido.append(lineas[indice])
                indice += 1
            }

            bloques.append(.codigo(
                lenguaje: lenguaje,
                contenido: contenido.joined(separator: "\n")
            ))

            // Si se encontro el cerco de cierre, se salta; si no, el indice ya
            // esta al final y el bucle exterior termina.
            indice += 1
        }

        volcarTexto()

        if !hayCercos {
            return texto.isEmpty ? [] : [.texto(texto)]
        }
        return bloques
    }
}
