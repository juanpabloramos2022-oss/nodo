import SwiftUI

import NodoCore

/// Pantalla "Acerca de" de la aplicacion (Solo informativa, no tiene botones para guardar ni editar).
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionTexto: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.2"
        return version
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    Text("Nodo")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(versionTexto)
                        .font(.subheadline)
                        .foregroundStyle(Tema.textoSuave)

                    Text("Chat con tus modelos de IA, con tus claves guardadas solo en tu teléfono.")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Tema.margen)

                    Text("Tus claves se guardan solo en el llavero de este teléfono. Nodo no las guarda en ningún servidor.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoSuave)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(Tema.margen)
                .frame(maxWidth: .infinity)
            }
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Acerca de")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") {
                        dismiss()
                    }
                    .font(.body)
                    .foregroundStyle(Tema.acento)
                }
            }
        }
    }
}
