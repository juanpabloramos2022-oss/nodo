import Foundation

import NodoCore

/// Un elemento visible de la pantalla de Tarea (P0.2).
///
/// Catalogo CERRADO de `UI_INVARIANTS.md`. Igual que en el hilo del Chat, no
/// hay caso para un resultado de herramienta, un JSON, un UUID ni un nombre
/// tecnico de funcion. `etiquetaDinamica` es un rotulo humano: la proyeccion
/// lo deriva de la fase o del tipo de accion, nunca de los argumentos crudos.
enum ElementoTareaVisible: Equatable {
    /// Estado visible de la cabecera fija y colapsable del Bloque 3.
    ///
    /// Se anida aqui, y no en el ambito global, porque `NodoCore` ya declara un
    /// `EstadoTarea` de dominio con otros casos. Anidarlo evita ensombrecer el
    /// tipo del nucleo en toda la app.
    enum EstadoTarea: Equatable {
        case nuevaTarea
        case planificando
        case planPropuesto
        case esperandoAprobacion
        case enCurso
        case detenida
        case error
        case completada

        /// Rotulo fijo de la cabecera.
        var titulo: String {
            switch self {
            case .nuevaTarea: return "Nueva tarea"
            case .planificando: return "Planificando"
            case .planPropuesto: return "Plan propuesto"
            case .esperandoAprobacion: return "Esperando aprobación"
            case .enCurso: return "En curso"
            case .detenida: return "Detenida"
            case .error: return "Error"
            case .completada: return "Completada"
            }
        }

        /// Rotulo con el paso visible cuando la tarea esta en ejecucion.
        func rotulo(pasoActual: Int, pasosTotales: Int) -> String {
            guard self == .enCurso, pasosTotales > 0 else { return titulo }
            return "En curso: Paso \(pasoActual)/\(pasosTotales)"
        }
    }

    /// Estado visible de una fila del libro de ejecucion.
    ///
    /// Se anida por la misma razon que `EstadoTarea`: el nucleo ya tiene un
    /// `EstadoPaso` con `.terminado`/`.fallido` y este catalogo usa los
    /// nombres visibles de la spec (`.completado`, `.error`).
    enum EstadoPaso: Equatable {
        case pendiente
        case enCurso
        case esperandoAprobacion
        case completado
        case denegado
        case detenido
        case error

        var titulo: String {
            switch self {
            case .pendiente: return "Pendiente"
            case .enCurso: return "En curso"
            case .esperandoAprobacion: return "Esperando aprobación"
            case .completado: return "Completado"
            case .denegado: return "Denegado"
            case .detenido: return "Detenido"
            case .error: return "Error"
            }
        }
    }

    case cabeceraTarea(
        estado: EstadoTarea,
        pasoActual: Int,
        pasosTotales: Int,
        costoSellado: Decimal
    )
    case tarjetaPlan(pasos: [PasoPlan], version: Int)
    case filaPaso(
        paso: Int,
        estado: EstadoPaso,
        etiquetaDinamica: String,
        duracion: TimeInterval?,
        costo: Decimal?
    )
}
