import SwiftUI

/// Aprobacion en contexto dentro del hilo de Tarea (B3-B, B.3).
///
/// POR QUE no reutiliza `HojaAprobacionView`: la spec exige que la hoja se
/// despliegue EN EL HILO, junto a su fila, y `HojaAprobacionView` es una hoja
/// modal con su propia navegacion. Ademas su fila «Herramienta» tiene un
/// renombre pendiente que es item del CIERRE: esta partida no la toca. Esta
/// tarjeta decide con los MISMOS dos metodos del estado
/// (`aprobarSolicitud` / `denegarSolicitud`), asi que el motor recibe
/// exactamente la misma decision y la continuacion de la hoja es la misma.
struct FilaAprobacionEnHilo: View {
    @EnvironmentObject private var estado: EstadoApp

    let solicitud: SolicitudAprobacion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Esperando tu aprobación", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(solicitud.descripcion)
                .font(.footnote)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Si rechazas, no se escribirá nada y la tarea no ejecutará "
                    + "la herramienta."
            )
            .font(.caption)
            .foregroundStyle(Tema.textoSuave)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    estado.denegarSolicitud()
                } label: {
                    Text("Rechazar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("rechazar-solicitud-hilo")

                Button {
                    estado.aprobarSolicitud()
                } label: {
                    Text("Aprobar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("aprobar-solicitud-hilo")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        }
        .accessibilityIdentifier("aprobacion-en-hilo")
    }
}
