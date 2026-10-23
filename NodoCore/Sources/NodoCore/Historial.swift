import Foundation

/// Construccion pura del historial que se manda al cliente HTTP.
///
/// Vive en NodoCore, y no en EstadoApp, para poder probar con `swift test` que
/// un chat sin memoria no recibe el texto de la Memoria (§4.6). La app la
/// conectara en la tarea de interfaz; aqui solo queda la regla.
public enum Historial {
    /// Prompt de sistema primero (solo si tiene texto), despues el resumen de
    /// /compact (si lo hay) y despues todos los mensajes de la conversacion,
    /// completos y en orden.
    ///
    /// El prompt no se guarda dentro de la conversacion a proposito, para que
    /// cambiarlo en Mi Contexto afecte tambien a los chats ya abiertos. En un
    /// chat sin memoria simplemente no se inyecta nada de contexto: ni prompt
    /// ni resumen, porque manda el olvido.
    public static func paraEnviar(
        conversacion: Conversation,
        promptSistema: String
    ) -> [ChatMessage] {
        var historial: [ChatMessage] = []

        guard !conversacion.sinMemoria else {
            historial.append(contentsOf: conversacion.mensajes)
            return historial
        }

        let prompt = promptSistema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            historial.append(ChatMessage(rol: .sistema, texto: prompt))
        }

        let resumen = conversacion.resumenCompactado?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resumen.isEmpty {
            historial.append(ChatMessage(rol: .sistema, texto: resumen))
        }

        historial.append(contentsOf: conversacion.mensajes)
        return historial
    }

    /// Inserta las instrucciones de las skills como mensajes de sistema justo
    /// antes del ultimo mensaje del usuario.
    ///
    /// El historial guardado no lleva las instrucciones: solo el payload de ese
    /// turno. Si todavia no hay mensaje de usuario, se anaden al final para no
    /// perderlas. Las instrucciones vacias se omiten.
    public static func insertarInstrucciones(
        _ historial: [ChatMessage],
        instrucciones: [String]
    ) -> [ChatMessage] {
        let mensajes = instrucciones.compactMap { instruccion -> ChatMessage? in
            let limpia = instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limpia.isEmpty else { return nil }
            return ChatMessage(rol: .sistema, texto: limpia)
        }
        guard !mensajes.isEmpty else { return historial }

        var salida = historial
        if let indice = salida.lastIndex(where: { $0.rol == .usuario }) {
            salida.insert(contentsOf: mensajes, at: indice)
        } else {
            salida.append(contentsOf: mensajes)
        }
        return salida
    }
}
