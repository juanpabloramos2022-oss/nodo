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
@MainActor
public final class EjecutorMemoriaDelTurno {
    private let idsDelTurno: Set<UUID>
    private let categoriasDelTurno: [UUID: CategoriaMemoria]
    private var invocaciones = 0
    private let aplicar: @MainActor (OperacionMemoriaTipada) -> ResultadoAccionMemoria

    public init(
        entradas: [EntradaMemoria],
        aplicar: @escaping @MainActor (OperacionMemoriaTipada) -> ResultadoAccionMemoria
    ) {
        self.idsDelTurno = Set(entradas.map(\.id))
        self.categoriasDelTurno = Dictionary(
            uniqueKeysWithValues: entradas.map { ($0.id, $0.categoria) }
        )
        self.aplicar = aplicar
    }

    public func ejecutar(herramienta: String, argumentos: String) async throws -> String {
        // El contador cuenta INVOCACIONES, no escrituras: la segunda llamada a
        // cualquier herramienta de memoria del turno se rechaza aunque la
        // primera haya fallado.
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
            break

        case .actualizar(let id, _, let categoria, _):
            guard idsDelTurno.contains(id) else {
                return "Error: no existe ninguna entrada de Memoria con ese entry_id en este turno."
            }
            if categoria != .correction,
               categoriasDelTurno[id] != categoria {
                return "Error: la categoria no coincide con la entrada que se corrige."
            }

        case .proponerSensible:
            // B2.1 la define y la valida, pero no la ofrece en Chat: sin hoja
            // de aprobacion no puede persistir nada.
            return "Error: la memoria sensible necesita aprobacion del dueno y no se persiste en este turno."

        case .borrar(let id):
            guard idsDelTurno.contains(id) else {
                return "Error: no existe ninguna entrada de Memoria con ese entry_id en este turno."
            }
        }

        switch aplicar(operacion) {
        case .aplicada(let cambio):
            return cambio.resultadoHerramienta
        case .rechazada(let motivo):
            return "Error: \(motivo)"
        }
    }
}
