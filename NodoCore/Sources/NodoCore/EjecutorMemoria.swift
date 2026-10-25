import Foundation

/// Ejecutor local validador de las herramientas de memoria de UN turno (B2.1).
///
/// Se crea dentro de `ejecutarTurno`, no en el estado global: el contador
/// 1/turno y el snapshot de ids se reinician solos en cada turno. Es
/// `@MainActor` para que el contador y la mutacion queden serializados en el
/// mismo actor; el ToolLoop puede pedir varias herramientas en un turno y la
/// segunda se rechaza sin tocar el registro.
///
/// POR QUE vive en el nucleo y no en la capa app: aqui no depende de SwiftUI ni
/// de la vista, y sus cuatro validaciones (conjunto tipado, tope por turno,
/// `entry_id` del snapshot y freno sensible) se prueban con `swift test` sin
/// simulador. La capa app solo inyecta el aplicador y decide donde se pinta la
/// linea.
///
/// B2.4: el aplicador es `async` porque una propuesta sensible detiene el turno
/// mientras el dueno decide en la hoja. Las validaciones NO cambian; lo unico
/// que cambia es que `.proponerSensible` deja de cortarse aqui y llega al
/// aplicador, que es quien presenta la hoja y, solo con [Aprobar], escribe.
@MainActor
public final class EjecutorMemoriaDelTurno {
    private let idsDelTurno: Set<UUID>
    private let categoriasDelTurno: [UUID: CategoriaMemoria]
    /// Entradas que entraron con aprobacion sensible (B2.4). Una actualizacion
    /// por `update_memory` sobre una de ellas se rechaza: reescribirla sin
    /// hoja seria persistir contenido sensible sin [Aprobar].
    private let sensiblesDelTurno: Set<UUID>
    /// B2.5: el turno arranca con el tope lleno o no. Se fija con el mismo
    /// snapshot que los ids, de modo que la decisión se toma contra la lista
    /// inyectada en ese turno.
    private let enTope: Bool
    private var invocaciones = 0
    private let aplicar: @MainActor (OperacionMemoriaTipada) async -> ResultadoAccionMemoria

    public init(
        entradas: [EntradaMemoria],
        aplicar: @escaping @MainActor (OperacionMemoriaTipada) async -> ResultadoAccionMemoria
    ) {
        self.idsDelTurno = Set(entradas.map(\.id))
        self.categoriasDelTurno = Dictionary(
            uniqueKeysWithValues: entradas.map { ($0.id, $0.categoria) }
        )
        self.sensiblesDelTurno = Set(
            entradas.filter { $0.categoriaSensible != nil }.map(\.id)
        )
        self.enTope = entradas.count >= Memoria.topeEntradas
        self.aplicar = aplicar
    }

    public func ejecutar(herramienta: String, argumentos: String) async throws -> String {
        // El contador cuenta INVOCACIONES, no escrituras: la segunda llamada a
        // cualquier herramienta de memoria del turno se rechaza aunque la
        // primera haya fallado. Una propuesta sensible tambien cuenta: es la
        // operacion de memoria de ese turno.
        invocaciones += 1
        guard invocaciones == 1 else {
            return "Error: ya se ejecuto una operacion de memoria en este turno; maximo 1 por turno."
        }

        let operacion: OperacionMemoriaTipada
        do {
            operacion = try Memoria.operacion(
                herramienta: herramienta,
                argumentos: argumentos
            )
        } catch let error as ErrorHerramienta {
            return "Error: \(error.errorDescription ?? "argumentos invalidos")"
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        switch operacion {
        case .guardar:
            // B2.5: con el tope lleno no se crea nada. La actualización y el
            // borrado siguen su camino normal (no hacen crecer N).
            if enTope {
                return "Error: \(Memoria.rechazoEnTope)"
            }

        case .actualizar(let id, _, let categoria, _):
            guard idsDelTurno.contains(id) else {
                return "Error: no existe ninguna entrada de Memoria con ese entry_id en este turno."
            }
            if sensiblesDelTurno.contains(id) {
                return "Error: esa entrada es sensible y no se reescribe por esta via."
            }
            if categoria != .correction,
               categoriasDelTurno[id] != categoria {
                return "Error: la categoria no coincide con la entrada que se corrige."
            }

        case .proponerSensible:
            // B2.4: la propuesta no escribe nada aqui. Pasa al aplicador, que
            // detiene el turno y presenta la hoja; solo el [Aprobar] del dueno
            // en ESE turno llega a crear la entrada.
            break

        case .borrar(let id):
            guard idsDelTurno.contains(id) else {
                return "Error: no existe ninguna entrada de Memoria con ese entry_id en este turno."
            }
        }

        switch await aplicar(operacion) {
        case .aplicada(let cambio):
            return cambio.resultadoHerramienta
        case .rechazada(let motivo):
            // Una denegacion del dueno no es un error tecnico: viaja con el
            // MISMO texto que usa el Modo Tarea, para que el modelo lo lea
            // como decision del dueno. Cualquier otro motivo si se rotula.
            if motivo == Memoria.rechazoDenegado { return motivo }
            return "Error: \(motivo)"
        }
    }
}
