import SwiftUI

@main
struct NodoApp: App {
    var body: some Scene {
        WindowGroup {
            PortadaView()
        }
    }
}

/// Pantalla de la entrega 0.0.1.
///
/// No hace nada util todavia a proposito: su unico trabajo es demostrar que la
/// cadena completa funciona, desde el codigo hasta el icono en la pantalla de
/// inicio. Si esto se instala y abre, todo lo que venga despues es seguro.
struct PortadaView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)

            Text("Nodo")
                .font(.system(size: 40, weight: .bold, design: .rounded))

            Text(NodoVersion.descripcion)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            Text("Cadena de compilacion operativa")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
