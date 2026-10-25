import Foundation

import NodoCore

/// Categoria tipada de una escritura sensible propuesta (B2.4).
///
/// Es el MISMO tipo del nucleo (`CategoriaSensibleMemoria`): la hoja, el
/// ejecutor y Mi Contexto no pueden discrepar de categoria ni de rotulo. El
/// rotulo visible (`etiquetaVisible`) vive en el nucleo para que no existan
/// dos listas que se desincronicen.
typealias CategoriaSensible = CategoriaSensibleMemoria

/// Propuesta de escritura sensible pendiente de aprobacion (B2.4).
///
/// P0.2 solo la proyecta: el flujo que la crea y la resuelve llega en B2.4.
/// Guarda exclusivamente el texto exacto que se guardaria y su categoria
/// tipada; no tiene campo para el nombre de la herramienta ni para un id.
struct PropuestaMemoriaSensible: Equatable {
    var texto: String
    var categoriaSensible: CategoriaSensible
    var estado: EstadoAprobacion

    init(
        texto: String,
        categoriaSensible: CategoriaSensible,
        estado: EstadoAprobacion = .pendiente
    ) {
        self.texto = texto
        self.categoriaSensible = categoriaSensible
        self.estado = estado
    }
}

/// Un tramo ordenado del contenido de una respuesta del asistente.
///
/// Es la traduccion a la capa de aplicacion de `BloqueRespuesta` del nucleo:
/// la prosa y los bloques de codigo se separan una sola vez y la vista pinta
/// exactamente esa lista. El codigo en linea dentro de una frase sigue siendo
/// `.texto`; solo una cerca de Markdown produce `.codigo`.
enum SegmentoRespuesta: Equatable {
    case texto(String)
    case codigo(lenguaje: String?, textoCrudo: String)

    /// Segmentos de una respuesta, en el mismo orden en que aparecen.
    static func segmentos(de texto: String) -> [SegmentoRespuesta] {
        BloquesRespuesta.parsear(texto).map { bloque in
            switch bloque {
            case .texto(let contenido):
                return .texto(contenido)
            case .codigo(let lenguaje, let contenido):
                return .codigo(lenguaje: lenguaje, textoCrudo: contenido)
            }
        }
    }
}

/// Un elemento visible del hilo del Chat (P0.2).
///
/// Catalogo CERRADO de `UI_INVARIANTS.md`. No existe ningun caso capaz de
/// representar un resultado de herramienta, un JSON, un UUID ni el nombre
/// tecnico de una funcion: la exclusion es estructural, no un filtro de texto.
enum ElementoHiloVisible: Equatable {
    case burbujaUsuario(texto: String)
    case burbujaAsistente(segmentos: [SegmentoRespuesta])
    case lineaMemoria(texto: String, puedeDeshacer: Bool, deshecho: Bool)
    case divisor(texto: String)
    case burbujaEnCurso(texto: String)
    case errorTurno(texto: String)
    case hojaAprobacionMemoria(
        texto: String,
        categoriaSensible: CategoriaSensible,
        estado: EstadoAprobacion
    )
}
