import Foundation

/// Version del producto en un solo sitio, para que la app y las pruebas no se
/// desincronicen.
///
/// Vive en NodoCore y no en la capa de interfaz a proposito: asi `swift test`
/// puede comprobarla en Windows, donde no hay SwiftUI.
public enum NodoVersion {
    /// Version visible para la persona que usa la app.
    public static let version = "0.0.1"

    /// Numero de compilacion. Se sube en cada entrega que se instala.
    public static let build = "1"

    /// Texto corto que identifica la compilacion en pantalla.
    public static var descripcion: String {
        "Nodo v\(version)"
    }
}
