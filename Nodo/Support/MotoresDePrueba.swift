import Foundation

import NodoCore

/// Error determinista del motor de capturas.
///
/// El estado `error-en-linea` lo inyecta para que la app recorra su ruta normal
/// de envio y pinte la burbuja de error con el mensaje del usuario intacto.
enum ErrorMotorDePrueba: LocalizedError {
    case falloDeEjemplo

    var errorDescription: String? {
        "No se pudo conectar con el proveedor de ejemplo."
    }
}

/// Motor de chat determinista para las capturas.
///
/// No hace red ni gasta cuota: como los chats normales ya no ofrecen
/// herramientas, responde directamente un texto final con consumo de ejemplo.
final class MotorDePrueba: ChatEngine {
    /// Cuando es true, el turno falla antes de producir texto.
    private let falla: Bool

    init(falla: Bool = false) {
        self.falla = falla
    }

    func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)?
    ) async throws -> RespuestaModelo {
        if falla {
            throw ErrorMotorDePrueba.falloDeEjemplo
        }

        let texto = "Respuesta de ejemplo para las capturas."
        alRecibirTexto?(texto)
        return RespuestaModelo(
            texto: texto,
            uso: UsoTokens(entrada: 120, salida: 32)
        )
    }
}
