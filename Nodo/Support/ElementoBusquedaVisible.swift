import Foundation

import NodoCore

/// Un elemento visible de la busqueda de conversaciones (B4-BUS).
///
/// Catalogo CERRADO de `UI_INVARIANTS.md`. Una fila se identifica por titulo y
/// vista previa de texto; no existe un caso con identificador de registro.
enum ElementoBusquedaVisible: Equatable {
    case resultadoBusqueda(titulo: String, vistaPrevia: String)
    case sinResultados(termino: String)
}

/// Una fila de la busqueda: lo que se VE y la conversacion que abre el toque.
///
/// POR QUE existe este par y no un caso nuevo del catalogo: la vista necesita
/// un destino de navegacion (`NavigationLink` por valor) y el catalogo cerrado
/// prohibe que un identificador viaje dentro del elemento visible. La fila
/// mantiene juntos el elemento proyectado (titulo y vista previa, lo unico que
/// se pinta) y la conversacion de la que salio; el id se usa solo para abrir
/// ESA conversacion, nunca como texto en pantalla ni en la traza.
struct FilaBusquedaVisible: Equatable {
    let conversacion: Conversation
    let elemento: ElementoBusquedaVisible
}
