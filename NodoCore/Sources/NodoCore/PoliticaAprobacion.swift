import Foundation

/// Decide que herramientas necesitan aprobacion antes de ejecutarse en modo
/// Tarea.
///
/// La definicion es cerrada (SPEC §4.3 y CONTRATO §9): toda llamada MCP y toda
/// peticion HTTP que no sea GET tiene consecuencias. Los GET son de solo
/// lectura y corren sin preguntar. La lista de exentas gana siempre, incluso
/// para una herramienta MCP; por defecto esa lista esta vacia.
///
/// Vive en NodoCore, sin interfaz ni estado, para poder probarla con `swift
/// test` y para que la app no reimplemente la regla.
public enum PoliticaAprobacion {
    public static func requiereAprobacion(
        esMCP: Bool,
        metodoHTTP: String?,
        nombreHerramienta: String,
        exentas: [String]
    ) -> Bool {
        if exentas.contains(nombreHerramienta) {
            return false
        }

        if esMCP {
            return true
        }

        if let metodoHTTP {
            return metodoHTTP.uppercased() != "GET"
        }

        // Ante la duda, se pide aprobacion: una herramienta desconocida no
        // puede colarse como si fuera de solo lectura.
        return true
    }
}
