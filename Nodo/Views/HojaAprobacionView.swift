import SwiftUI

/// Hoja de aprobacion de una herramienta con consecuencias (TASK.4/HP1).
///
/// POR QUE se recrea aqui: DEM la retiro cuando el modo Tarea se desconecto y
/// la hoja quedo inalcanzable. Vuelve con el mismo contrato de la app: no se
/// puede arrastrar para cerrar sin decidir, Rechazar no ejecuta nada y Aprobar
/// deja que el ToolLoop aplique la escritura.
///
/// Nomenclatura visible (SPEC §2.2, hallazgo Jules 3): las dos salidas son
/// exactamente "Aprobar" o "Rechazar". Los nombres internos
/// (`denegarSolicitud`) no se tocan: son codigo, no texto visible, y
/// renombrarlos tocaria el nucleo y decenas de pruebas sin cambiar lo que
/// ve el dueno.
struct HojaAprobacionView: View {
    @EnvironmentObject private var estado: EstadoApp

    let solicitud: SolicitudAprobacion

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Aprobación necesaria", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text(solicitud.descripcion)
                        .font(.body)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("aprobacion-descripcion")
                }

                if !solicitud.detalle.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Herramienta")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Tema.textoSuave)
                        Text(solicitud.herramienta)
                            .font(.caption.monospaced())
                            .foregroundStyle(Tema.acento)

                        Text(solicitud.detalle)
                            .font(.caption)
                            .foregroundStyle(Tema.textoSuave)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tema.superficie)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Text("Si rechazas, no se escribirá nada y la tarea no ejecutará la herramienta.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        estado.denegarSolicitud()
                    } label: {
                        Text("Rechazar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("rechazar-solicitud")

                    Button {
                        estado.aprobarSolicitud()
                    } label: {
                        Text("Aprobar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("aprobar-solicitud")
                }
            }
            .padding(Tema.margen)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Aprobación")
            .navigationBarTitleDisplayMode(.inline)
        }
        // La decision es obligatoria: arrastrar no puede dejar el bucle
        // esperando una respuesta que ya no va a llegar.
        .interactiveDismissDisabled()
    }
}
