import Foundation

/// Construccion pura del historial que se manda al cliente HTTP.
///
/// Vive en NodoCore, y no en EstadoApp, para poder probar con `swift test` que
/// un chat sin memoria no recibe el texto de la Memoria (§4.6). La app la
/// conectara en la tarea de interfaz; aqui solo queda la regla.
public enum Historial {
    /// Prompt de sistema primero (solo si tiene texto) y despues todos los
    /// mensajes de la conversacion, completos y en orden.
    ///
    /// El prompt no se guarda dentro de la conversacion a proposito, para que
    /// cambiarlo en Mi Contexto afecte tambien a los chats ya abiertos. En un
    /// chat sin memoria simplemente no se inyecta: no se recorta ni se resume
    /// nada mas.
    public static func paraEnviar(
        conversacion: Conversation,
        promptSistema: String
    ) -> [ChatMessage] {
        var historial: [ChatMessage] = []

        let prompt = promptSistema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty && !conversacion.sinMemoria {
            historial.append(ChatMessage(rol: .sistema, texto: prompt))
        }

        historial.append(contentsOf: conversacion.mensajes)
        return historial
    }
}
