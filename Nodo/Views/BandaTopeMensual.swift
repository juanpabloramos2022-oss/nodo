import SwiftUI

import NodoCore

/// Banda discreta del tope mensual de gasto (IDEA4).
///
/// POR QUE vive FUERA del `ForEach` del hilo: la alerta no es un elemento de
/// `ElementoHiloVisible` ni se inyecta en la conversacion. La vista recibe el
/// estado ya resuelto por `EstadoApp` y solo pinta aviso (80 %) o tope
/// alcanzado (100 %). No bloquea, retrasa ni cancela ningun envio: el composer
/// sigue igual de operativo con la banda visible.
struct BandaTopeMensual: View {
    let estado: TopeMensualGasto
    /// En la tarjeta de Gasto la banda ya vive dentro de un contenedor con
    /// margen; sobre el composer necesita el suyo.
    var conMargen: Bool = true

    var body: some View {
        if estado.visible, let texto = estado.texto {
            Text(texto)
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, conMargen ? Tema.margen : 0)
                .padding(.vertical, 8)
                .background(Tema.superficie)
                .clipShape(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("banda-tope-mensual")
                .accessibilityLabel(texto)
        }
    }
}
