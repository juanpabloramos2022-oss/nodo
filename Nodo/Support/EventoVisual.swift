import Foundation

/// Un evento puramente visual del hilo (contrato §6 / SPEC §2.6).
///
/// No es un mensaje: no se guarda en la conversacion y nunca entra en el
/// arreglo que se manda al proveedor. Vive solo en memoria mientras el chat
/// esta abierto; al abrir o crear otra conversacion se limpia.
struct EventoVisual: Identifiable, Equatable {
    let id: UUID
    /// El divisor se pinta DESPUES de este mensaje. nil = al principio del hilo.
    let trasMensaje: UUID?
    let texto: String

    init(id: UUID = UUID(), trasMensaje: UUID?, texto: String) {
        self.id = id
        self.trasMensaje = trasMensaje
        self.texto = texto
    }
}
