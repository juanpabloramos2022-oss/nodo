import Foundation
import SwiftUI

/// Estado vacio explicito de la busqueda de Chats (B4-BUS).
///
/// Catalogo de `UI_INVARIANTS.md`: `.sinResultados(termino:)`. Existe para que
/// una busqueda sin coincidencias NUNCA deje la pestana en blanco sin
/// explicacion (§2.2): se dice que no hay resultados y se repite el termino
/// buscado, para que el dueno vea que se busco exactamente lo que escribio.
///
/// El termino es el texto ya recortado que trae la proyeccion; aqui no se
/// reconstruye ni se normaliza nada.
struct SearchEmptyState: View {
    let termino: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Tema.acento.opacity(0.7))

            Text("Sin resultados para \"\(termino)\"")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("La búsqueda mira el título y el texto de tus conversaciones guardadas.")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, Tema.margen)
        .accessibilityIdentifier("sin-resultados-busqueda")
    }
}
