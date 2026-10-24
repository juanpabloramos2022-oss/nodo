import Foundation

/// Guarda y recupera tareas como un archivo JSON por tarea.
///
/// Espejo deliberado de `ConversationStore`: un directorio propio (no se mezcla
/// con el de conversaciones), escritura atomica y una tarea corrupta no impide
/// abrir las demas. La lista se ordena por `fechaActualizacion` descendente,
/// que es el orden en el que el dueno espera ver su trabajo reciente.
public final class TareaStore {
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
    ///
    /// "tareas" y no el directorio raiz: las conversaciones y las tareas son
    /// espacios distintos y no deben compartir archivos ni indices.
    public static func directorioPorDefecto() throws -> URL {
        let soporte = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return soporte.appendingPathComponent("tareas", isDirectory: true)
    }

    /// Directorio de tareas junto a un contenedor inyectado.
    ///
    /// Lo usan los tests y `EstadoApp` cuando reciben `directorioStore`: el
    /// almacen de conversaciones sigue en la raiz y el de tareas en su propia
    /// subcarpeta, sin compartir archivos.
    public static func directorioEn(_ contenedor: URL) -> URL {
        contenedor.appendingPathComponent("tareas", isDirectory: true)
    }

    private func archivo(_ id: UUID) -> URL {
        directorio.appendingPathComponent("\(id.uuidString).json")
    }

    /// Escribe la tarea de forma atomica: si el proceso muere a mitad, el
    /// archivo anterior queda intacto.
    public func guardar(_ tarea: Tarea) throws {
        let datos = try codificador.encode(tarea)
        try datos.write(to: archivo(tarea.id), options: .atomic)
    }

    /// Carga una tarea, o nil si no existe o esta corrupta.
    public func cargar(id: UUID) -> Tarea? {
        guard let datos = try? Data(contentsOf: archivo(id)) else { return nil }
        return try? decodificador.decode(Tarea.self, from: datos)
    }

    /// Todas las tareas, la mas reciente primero.
    public func listar() -> [Tarea] {
        guard let nombres = try? gestor.contentsOfDirectory(atPath: directorio.path) else {
            return []
        }
        var salida: [Tarea] = []
        for nombre in nombres where nombre.hasSuffix(".json") {
            let ruta = directorio.appendingPathComponent(nombre)
            guard let datos = try? Data(contentsOf: ruta),
                  let tarea = try? decodificador.decode(Tarea.self, from: datos)
            else { continue }
            salida.append(tarea)
        }
        return salida.sorted { izquierda, derecha in
            if izquierda.fechaActualizacion == derecha.fechaActualizacion {
                return izquierda.id.uuidString < derecha.id.uuidString
            }
            return izquierda.fechaActualizacion > derecha.fechaActualizacion
        }
    }

    /// Marca como interrumpidas todas las tareas que quedaron `enCurso`.
    ///
    /// POR QUE en el arranque: iOS no mantiene procesos vivos en segundo plano.
    /// Si la app se cerro con una tarea ejecutando, al volver no hay nada
    /// corriendo y decir "En curso" seria mentir. La pantalla de la tarea lo
    /// declara con la frontera honesta.
    ///
    /// Devuelve cuantas tareas cambio para que el llamador pueda probarlo.
    @discardableResult
    public func marcarInterrumpidas(fecha: Date = Date()) -> Int {
        var cambiadas = 0
        for tarea in listar() where tarea.estado == .enCurso {
            var copia = tarea
            copia.estado = .interrumpida
            copia.fechaActualizacion = fecha
            // Un fallo de escritura no debe impedir que el resto de la lista
            // arranque; la marca en memoria la aplica tambien EstadoApp.
            try? guardar(copia)
            cambiadas += 1
        }
        return cambiadas
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
