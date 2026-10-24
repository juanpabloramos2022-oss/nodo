import Foundation

/// Errores del almacen de conversaciones.
public enum ErrorConversationStore: Error, Equatable {
    /// Se intento guardar un Chat Temporal (B2.2).
    ///
    /// Un hilo temporal vive solo en memoria volatil: su camino de salida no
    /// escribe ni en la lista ni en un archivo. El rechazo vive aqui, en la
    /// capa que toca disco, para que ningun camino nuevo (ni un futuro metodo
    /// de EstadoApp) pueda saltarselo sin darse cuenta.
    case conversacionTemporal
}

/// Guarda y recupera conversaciones como un archivo JSON por conversacion.
///
/// Un archivo por conversacion y no un unico archivo con todas: asi guardar un
/// mensaje no reescribe el historial entero, y una conversacion corrupta no se
/// lleva por delante a las demas.
public final class ConversationStore {
    private let directorio: URL
    private let gestor: FileManager
    private let codificador: JSONEncoder
    private let decodificador: JSONDecoder

    public init(directorio: URL, gestor: FileManager = .default) throws {
        self.directorio = directorio
        self.gestor = gestor

        let codificador = JSONEncoder()
        codificador.outputFormatting = [.sortedKeys]
        codificador.dateEncodingStrategy = .iso8601
        self.codificador = codificador

        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        self.decodificador = decodificador

        if !gestor.fileExists(atPath: directorio.path) {
            try gestor.createDirectory(at: directorio, withIntermediateDirectories: true)
        }
    }

    /// Directorio por defecto dentro del contenedor de la app.
    public static func directorioPorDefecto() throws -> URL {
        let soporte = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return soporte.appendingPathComponent("conversaciones", isDirectory: true)
    }

    private func archivo(_ id: UUID) -> URL {
        directorio.appendingPathComponent("\(id.uuidString).json")
    }
    /// Escribe la conversacion. Es atomico: si el proceso muere a mitad, el
    /// archivo anterior queda intacto.
    ///
    /// B2.2: un hilo temporal se rechaza sin escribir nada. Es la demolicion,
    /// en la capa de almacenamiento, de la suposicion «todo hilo persiste».
    public func guardar(_ conversacion: Conversation) throws {
        guard conversacion.sePersiste else {
            throw ErrorConversationStore.conversacionTemporal
        }
        let datos = try codificador.encode(conversacion)
        try datos.write(to: archivo(conversacion.id), options: .atomic)
    }

    /// Carga una conversacion, o nil si no existe o esta corrupta.
    ///
    /// No lanza por un archivo corrupto a proposito: una conversacion rota no
    /// debe impedir abrir la app.
    public func cargar(id: UUID) -> Conversation? {
        guard let datos = try? Data(contentsOf: archivo(id)) else { return nil }
        return try? decodificador.decode(Conversation.self, from: datos)
    }

    /// Todas las conversaciones, la mas reciente primero.
    public func listar() -> [Conversation] {
        guard let nombres = try? gestor.contentsOfDirectory(atPath: directorio.path) else {
            return []
        }
        var salida: [Conversation] = []
        for nombre in nombres where nombre.hasSuffix(".json") {
            let ruta = directorio.appendingPathComponent(nombre)
            guard let datos = try? Data(contentsOf: ruta),
                  let conversacion = try? decodificador.decode(Conversation.self, from: datos)
            else { continue }
            salida.append(conversacion)
        }
        return salida.sorted { $0.actualizada > $1.actualizada }
    }

    public func borrar(id: UUID) throws {
        let ruta = archivo(id)
        guard gestor.fileExists(atPath: ruta.path) else { return }
        try gestor.removeItem(at: ruta)
    }

    public func borrarTodo() throws {
        guard let nombres = try? gestor.contentsOfDirectory(atPath: directorio.path) else { return }
        for nombre in nombres where nombre.hasSuffix(".json") {
            try? gestor.removeItem(at: directorio.appendingPathComponent(nombre))
        }
    }
}
