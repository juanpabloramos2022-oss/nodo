import Foundation

/// Construccion pura del historial que se manda al cliente HTTP.
///
/// Vive en NodoCore, y no en EstadoApp, para poder probar con `swift test` que
/// un chat sin memoria no recibe el texto de la Memoria (§4.6). La app la
/// conectara en la tarea de interfaz; aqui solo queda la regla.
public enum Historial {
    /// Cabecera unica del resumen de compactacion.
    ///
    /// La usan las dos vias (la Memoria y el respaldo sin memoria) para que el
    /// modelo reconozca siempre el mismo bloque. Tener una sola constante evita
    /// que una copia se pinte con un rotulo distinto y se duplique el contexto.
    public static let cabeceraResumen = "[Resumen de la conversacion anterior]"

    /// Bloque de Memoria primero (solo en chats con memoria), despues el resumen
    /// de /compact (si lo hay) y despues todos los mensajes de la conversacion,
    /// completos y en orden.
    ///
    /// La Memoria no se guarda dentro de la conversacion a proposito, para que
    /// cambiarla en Mi Contexto afecte tambien a los chats ya abiertos.
    ///
    /// MEM.2: el bloque de sistema declara la capacidad y lista las entradas con
    /// sus ids; sustituye al viejo texto plano de la Memoria. En un chat sin
    /// memoria no viaja ningun bloque de Memoria.
    ///
    /// B2.2: el Chat Temporal tambien queda fuera del bloque. No es lo mismo que
    /// un chat «sin memoria»: el temporal ademas no ofrece las herramientas de
    /// escritura (lo decide `EstadoApp.ejecutarTurno` con la misma regla).
    ///
    /// COMP.2: en un chat SIN memoria la Memoria no viaja, pero el resumen de
    /// la ultima compactacion si debe viajar. Si no, /compact resume y poda
    /// para siempre: el modelo olvida justo lo que el resumen conservaba. Por
    /// eso `resumenGuardado` es el respaldo que EstadoApp persiste junto a los
    /// usos resumidos. Cuando la conversacion ya aporta su resumen por la via
    /// de la Memoria (o el bloque ya lo trae), el respaldo no se anade: el
    /// mismo bloque nunca viaja dos veces.
    /// B2.3: `disparoMemoria` decide SOLO la instruccion de disparo del bloque
    /// de sistema. El conjunto de herramientas lo decide `usaMemoriaEnPayload`
    /// en la capa app y no cambia con el interruptor: ON y OFF ofrecen las
    /// mismas herramientas tipadas de B2.1.
    public static func paraEnviar(
        conversacion: Conversation,
        memoria: [EntradaMemoria],
        resumenGuardado: String? = nil,
        disparoMemoria: DisparoMemoria = .ordenExplicita
    ) -> [ChatMessage] {
        var historial: [ChatMessage] = []

        // B2.2: el camino de payload del Chat Temporal es propio. Un hilo
        // temporal no inyecta NINGUNA entrada de Memoria, ni siquiera si su
        // `sinMemoria` esta en false: la regla vive en
        // `Conversation.usaMemoriaEnPayload` para que el constructor de payload
        // y el ofrecimiento de herramientas no puedan divergir.
        let usaMemoria = conversacion.usaMemoriaEnPayload
        let bloqueMemoria = usaMemoria
            ? Memoria.bloqueSistema(
                entradas: memoria,
                disparo: disparoMemoria
            )
            : nil
        if let bloqueMemoria {
            historial.append(ChatMessage(rol: .sistema, texto: bloqueMemoria))
        }

        // La via de la Memoria manda: es el resumen que la conversacion ya
        // lleva encima y solo se inyecta cuando la Memoria esta activa. El
        // respaldo persistido cubre el hueco de los chats sin memoria (y de
        // cualquier archivo viejo que no traiga el resumen en la conversacion).
        let deMemoria = usaMemoria
            ? normalizar(conversacion.resumenCompactado)
            : nil
        let respaldo = normalizar(resumenGuardado)
        let resumen = deMemoria ?? respaldo

        if let resumen,
           !yaEstaEnElBloque(resumen, bloque: bloqueMemoria) {
            historial.append(mensajeDeResumen(resumen))
        }

        historial.append(contentsOf: conversacion.mensajes)
        return historial
    }

    /// Bloque de sistema con la cabecera comun del resumen.
    private static func mensajeDeResumen(_ resumen: String) -> ChatMessage {
        ChatMessage(
            rol: .sistema,
            texto: "\(cabeceraResumen)\n\(resumen)"
        )
    }

    private static func normalizar(_ texto: String?) -> String? {
        let limpio = (texto ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limpio.isEmpty ? nil : limpio
    }

    /// True si el bloque de Memoria ya contiene este resumen (o al menos su
    /// cabecera). En un chat sin Memoria no hay bloque, asi que no puede
    /// suprimir el respaldo.
    private static func yaEstaEnElBloque(
        _ resumen: String,
        bloque: String?
    ) -> Bool {
        guard let bloque, !bloque.isEmpty else { return false }
        let opciones: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if bloque.range(of: resumen, options: opciones) != nil {
            return true
        }
        return bloque.range(of: cabeceraResumen, options: opciones) != nil
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
