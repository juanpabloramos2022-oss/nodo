import Foundation

import NodoCore

/// Un evento puramente visual del hilo (contrato §6 / SPEC §2.6).
///
/// No es un mensaje: no se guarda en la conversacion y nunca entra en el
/// arreglo que se manda al proveedor. Vive solo en memoria mientras el chat
/// esta abierto; al abrir o crear otra conversacion se limpia.
struct EventoVisual: Identifiable, Equatable {
    let id: UUID
    /// El evento se pinta DESPUES de este mensaje. nil = al principio del hilo.
    let trasMensaje: UUID?
    let texto: String
    /// Cambio de Memoria que esta linea puede deshacer (MEM.3).
    ///
    /// nil en los divisores de siempre (cambio de modelo, memoria desactivada,
    /// compactacion): esos no tienen nada que revertir.
    let cambioMemoria: CambioMemoria?
    /// True cuando el cambio ya se revirtio.
    ///
    /// La linea se queda como constancia de lo que paso, pero deja de ofrecer
    /// [Deshacer]: un mismo cambio no puede revertirse dos veces.
    let deshecho: Bool

    init(
        id: UUID = UUID(),
        trasMensaje: UUID?,
        texto: String,
        cambioMemoria: CambioMemoria? = nil,
        deshecho: Bool = false
    ) {
        self.id = id
        self.trasMensaje = trasMensaje
        self.texto = texto
        self.cambioMemoria = cambioMemoria
        self.deshecho = deshecho
    }

    /// Copia la linea marcandola como ya deshecha.
    func comoDeshecho() -> EventoVisual {
        EventoVisual(
            id: id,
            trasMensaje: trasMensaje,
            texto: texto,
            cambioMemoria: cambioMemoria,
            deshecho: true
        )
    }
}
