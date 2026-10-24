import Foundation

/// Un elemento visible de la busqueda de conversaciones (B4-BUS).
///
/// Catalogo CERRADO de `UI_INVARIANTS.md`. Una fila se identifica por titulo y
/// vista previa de texto; no existe un caso con identificador de registro.
enum ElementoBusquedaVisible: Equatable {
    case resultadoBusqueda(titulo: String, vistaPrevia: String)
    case sinResultados(termino: String)
}
