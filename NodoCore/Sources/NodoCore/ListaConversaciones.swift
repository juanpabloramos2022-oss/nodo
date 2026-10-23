import Foundation

/// Segmento visible de la lista de chats (§3.1, Fase 5).
///
/// Es un filtro puro: Activos y Archivados nunca se mezclan. La vista decide
/// cual esta seleccionado; el nucleo solo dice que conversaciones pertenecen a
/// cada uno.
public enum SegmentoChats: String, CaseIterable, Identifiable {
    case activos
    case archivados

    public var id: String { rawValue }

    public var titulo: String {
        switch self {
        case .activos: return "Activos"
        case .archivados: return "Archivados"
        }
    }
}

/// Datos ya resueltos de una fila de la lista (§3.1, Fase 5).
///
/// La vista solo pinta: el costo sale de los usos del chat con los precios del
/// proveedor de ESE chat, y el modelo es el nombre limpio de ese mismo
/// proveedor. Si algo no se puede resolver, el campo queda vacio o nil para que
/// la app decida no pintar la pastilla o la etiqueta, en vez de inventar cifras.
public struct DatosFilaChat: Equatable {
    /// Costo acumulado con los precios del proveedor del chat.
    ///
    /// nil cuando no hay consumo medido o cuando ese proveedor no tiene precios
    /// configurados. La app no pinta pastilla en ese caso.
    public let costo: Double?

    /// Nombre limpio del modelo del proveedor de la conversacion. "" si la
    /// conversacion no tiene un proveedor resoluble o el modelo esta vacio.
    public let modelo: String

    /// Vista previa de una linea del ultimo mensaje. "" si no hay mensajes.
    public let vistaPrevia: String

    public init(costo: Double? = nil, modelo: String = "", vistaPrevia: String = "") {
        self.costo = costo
        self.modelo = modelo
        self.vistaPrevia = vistaPrevia
    }
}

extension HistorialConversaciones {
    /// Actividad de una conversacion para ordenar la lista.
    ///
    /// Manda la fecha del ultimo mensaje, que es la actividad real de la charla.
    /// Si todavia no hay mensajes se usa `actualizada`, el sello que la app
    /// mantiene desde la creacion y que en un chat vacio coincide con `creada`.
    /// Se documenta aqui porque el modelo ya usaba `actualizada` para ordenar
    /// (`ConversationStore.listar`), pero la fila enriquecida necesita que un
    /// mensaje nuevo mande sobre cualquier otra escritura del archivo.
    public static func actividad(de conversacion: Conversation) -> Date {
        conversacion.mensajes.last?.fecha ?? conversacion.actualizada
    }

    /// Orden de la lista: fijadas primero y, dentro de cada grupo, actividad
    /// reciente primero. El id desempata para que el orden sea determinista.
    public static func ordenar(_ conversaciones: [Conversation]) -> [Conversation] {
        conversaciones.sorted { izquierda, derecha in
            if izquierda.fijada != derecha.fijada {
                return izquierda.fijada
            }

            let actividadIzquierda = actividad(de: izquierda)
            let actividadDerecha = actividad(de: derecha)
            if actividadIzquierda != actividadDerecha {
                return actividadIzquierda > actividadDerecha
            }

            return izquierda.id.uuidString < derecha.id.uuidString
        }
    }

    /// Filtra por segmento sin mezclar: Activos excluye archivadas y Archivados
    /// excluye activas. Conserva el orden recibido; la lista lo combina con
    /// `ordenar(_:)` cuando necesita la actividad reciente.
    public static func enSegmento(
        _ segmento: SegmentoChats,
        de conversaciones: [Conversation]
    ) -> [Conversation] {
        conversaciones.filter { conversacion in
            switch segmento {
            case .activos: return !conversacion.archivada
            case .archivados: return conversacion.archivada
            }
        }
    }

    /// Datos de la fila de dos lineas: pastilla de costo, etiqueta del ultimo
    /// modelo de la conversacion y vista previa del ultimo mensaje.
    ///
    /// La etiqueta usa el proveedor registrado del chat, nunca el activo
    /// global. El costo valora cada mensaje con el proveedor que lo genero y
    /// solo cae a `conversacion.proveedorID` en los mensajes viejos que no
    /// traen esa anotacion.
    public static func datosFila(
        de conversacion: Conversation,
        proveedores: [ProviderConfig]
    ) -> DatosFilaChat {
        let idDelChat = conversacion.proveedorID
            ?? conversacion.mensajes.last(where: { $0.proveedorID != nil })?.proveedorID
        let proveedor = idDelChat.flatMap { id in
            proveedores.first { $0.id == id }
        }

        // Cada mensaje se valora con el proveedor que lo genero; el del chat
        // solo cubre los mensajes viejos que no traen esa anotacion.
        let costo = CostoEstimado.acumulado(
            mensajes: conversacion.mensajes,
            proveedores: proveedores,
            proveedorDelChat: conversacion.proveedorID
        )

        let modelo = proveedor.map { NombresLimpios.modelo($0.modelo) } ?? ""

        return DatosFilaChat(
            costo: costo,
            modelo: modelo,
            vistaPrevia: vistaPrevia(de: conversacion)
        )
    }

    /// Texto plano del ultimo mensaje, recortado para la segunda linea.
    private static func vistaPrevia(de conversacion: Conversation) -> String {
        guard let ultimo = conversacion.mensajes.last else { return "" }

        let plano = ultimo.texto
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plano.count <= 80 { return plano }
        return String(plano.prefix(80)) + "..."
    }

    /// Ramifica una conversacion hasta un mensaje, inclusive (§5.4).
    ///
    /// La copia lleva ids nuevos de conversacion y de mensaje, el mismo rol,
    /// texto, uso y skills de cada mensaje clonado, y el mismo `proveedorID`,
    /// `sinMemoria` y `modoTarea` del original. No es un chat fijado ni
    /// archivado y nace con el titulo de un chat nuevo (`tituloSugerido` se
    /// deriva del primer usuario, como siempre).
    ///
    /// NO hereda `resumenCompactado` ni `usoTrasCompactar`: el historial
    /// clonado ES el contexto completo hasta el corte, y heredar el resumen
    /// duplicaria contexto. Su acumulado facturable sale de los usos clonados.
    ///
    /// Devuelve nil si el id no pertenece a esta conversacion; no se inventa un
    /// punto de corte.
    public static func ramificar(
        _ conversacion: Conversation,
        hastaElMensaje id: UUID
    ) -> Conversation? {
        guard let corte = conversacion.mensajes.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let ahora = Date()
        let clonados = conversacion.mensajes[...corte].map { mensaje in
            ChatMessage(
                id: UUID(),
                rol: mensaje.rol,
                texto: mensaje.texto,
                fecha: mensaje.fecha,
                toolCalls: mensaje.toolCalls,
                toolCallId: mensaje.toolCallId,
                tokensEntrada: mensaje.tokensEntrada,
                tokensSalida: mensaje.tokensSalida,
                skillsAplicadas: mensaje.skillsAplicadas,
                proveedorID: mensaje.proveedorID
            )
        }

        return Conversation(
            titulo: "Conversacion",
            mensajes: clonados,
            creada: ahora,
            actualizada: ahora,
            fijada: false,
            archivada: false,
            avisoCostoMostrado: false,
            sinMemoria: conversacion.sinMemoria,
            modoTarea: conversacion.modoTarea,
            topeIgnorado: false,
            resumenCompactado: nil,
            usoTrasCompactar: nil,
            proveedorID: conversacion.proveedorID
        )
    }

    /// Alias con la firma literal de la fase, por comodidad de las llamadas.
    public static func ramificar(
        la conversacion: Conversation,
        hastaElMensaje id: UUID
    ) -> Conversation? {
        ramificar(conversacion, hastaElMensaje: id)
    }
}

extension Conversation {
    /// Version de instancia de `HistorialConversaciones.ramificar`.
    public func ramificar(hastaElMensaje id: UUID) -> Conversation? {
        HistorialConversaciones.ramificar(self, hastaElMensaje: id)
    }
}
