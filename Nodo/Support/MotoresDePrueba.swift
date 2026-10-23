import Foundation

import NodoCore

/// Herramienta determinista para las capturas del modo Tarea.
///
/// Se clasifica como MCP en `EstadoApp` (todo lo que no es "traer_url"), asi
/// que siempre abre la hoja de aprobacion. El retardo corto y fijo es lo que
/// permite capturar el estado "Ejecutando..." antes de que termine.
struct HerramientaDePrueba: Herramienta {
    var definicion: ToolDefinition {
        ToolDefinition(
            nombre: "accion_de_prueba",
            descripcion: "Accion de ejemplo con consecuencias para las capturas.",
            parametros: JSONSchema(
                propiedades: [
                    "destino": .init(
                        tipo: "string",
                        descripcion: "Destino de ejemplo de la accion"
                    )
                ],
                requeridos: ["destino"]
            )
        )
    }

    func ejecutar(argumentos: String) async throws -> String {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return "Resultado de ejemplo: la accion de prueba termino sin errores."
    }
}

/// Motor de chat determinista para las capturas del modo Tarea.
///
/// No hace red ni gasta cuota: la primera respuesta pide la herramienta de
/// prueba y, cuando ya hay un resultado de herramienta en el historial,
/// devuelve un texto final con consumo de ejemplo. En modo Chat (sin
/// herramientas ofrecidas) responde directamente el texto final.
final class MotorDePrueba: ChatEngine {
    private var llamadas = 0

    func responder(
        mensajes: [ChatMessage],
        herramientas: [ToolDefinition],
        alRecibirTexto: ((String) -> Void)?
    ) async throws -> RespuestaModelo {
        llamadas += 1

        let nombre = "accion_de_prueba"
        let ofreceLaHerramienta = herramientas.contains { $0.nombre == nombre }
        let yaHayResultado = mensajes.last?.rol == .herramienta

        if ofreceLaHerramienta, !yaHayResultado {
            return RespuestaModelo(
                texto: "",
                toolCalls: [
                    ToolCall(
                        id: "prueba-\(llamadas)",
                        nombre: nombre,
                        argumentos: "{\"destino\":\"ejemplo\"}"
                    )
                ],
                uso: UsoTokens(entrada: 48, salida: 12)
            )
        }

        let texto = "Respuesta de ejemplo para las capturas."
        alRecibirTexto?(texto)
        return RespuestaModelo(
            texto: texto,
            uso: UsoTokens(entrada: 120, salida: 32)
        )
    }
}
