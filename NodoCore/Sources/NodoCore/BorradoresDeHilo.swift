import Foundation

/// Borradores del composer por hilo (IDEA6).
///
/// POR QUE un almacen aparte y no un campo de `Conversation`: el borrador es
/// texto que el dueno todavia NO envio. No es historial, no viaja al modelo,
/// no se pinta en el hilo y no puede sobrevivir como mensaje. Guardarlo dentro
/// de la conversacion lo mezclaria con el payload y, en un Chat Temporal,
/// romperia la promesa de cero rastro (B2.2).
///
/// La clave es el `conversacion.id`: dos hilos NUNCA comparten borrador y el
/// mismo hilo lo recupera tal cual lo dejo el dueno. El tipo es puro (sin UI y
/// sin disco): `EstadoApp` decide cuando lee y cuando escribe.
public struct BorradoresDeHilo: Equatable {
    /// Texto por id de conversacion, en `uuidString`.
    private var textos: [String: String]

    public init(textos: [String: String] = [:]) {
        self.textos = textos
    }

    /// Texto guardado para ese hilo, o nil si no hay borrador.
    public func texto(para id: UUID) -> String? {
        textos[id.uuidString]
    }

    /// Guarda el borrador exacto de ese hilo.
    ///
    /// Un texto vacio BORRA la entrada en vez de dejar una cadena vacia: un
    /// borrador vacio no es evidencia y no debe ocupar sitio ni contar como
    /// residuo. El texto se guarda sin recortar: el dueno lo recupera tal cual
    /// lo escribio.
    public mutating func guardar(_ texto: String, para id: UUID) {
        if texto.isEmpty {
            textos.removeValue(forKey: id.uuidString)
        } else {
            textos[id.uuidString] = texto
        }
    }

    /// Borra el borrador de ese hilo (envio exitoso, cierre temporal, borrado
    /// de la conversacion). Es idempotente.
    public mutating func borrar(para id: UUID) {
        textos.removeValue(forKey: id.uuidString)
    }

    /// Cuantos hilos tienen borrador vivo. Lo usan las pruebas de estado.
    public var cantidad: Int { textos.count }

    // MARK: - Persistencia

    /// JSON plano `{"<uuid>": "texto"}`.
    public func json() throws -> Data {
        try JSONEncoder().encode(textos)
    }

    /// Lee el JSON; un archivo corrupto o de otra forma deja el almacen vacio
    /// en vez de impedir abrir la app.
    public static func desde(json: Data) throws -> BorradoresDeHilo {
        BorradoresDeHilo(textos: try JSONDecoder().decode([String: String].self, from: json))
    }
}
