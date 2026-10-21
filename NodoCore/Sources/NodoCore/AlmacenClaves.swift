import Foundation

/// Donde viven las credenciales.
///
/// Es un protocolo y no una llamada directa al Keychain por dos motivos: las
/// pruebas no pueden tocar el Keychain del sistema, y en Windows no existe. La
/// implementacion real vive en la capa de la app.
public protocol AlmacenClaves {
    func guardar(_ valor: String, para clave: String) throws
    func leer(_ clave: String) -> String?
    func borrar(_ clave: String) throws
}

/// Almacen en memoria, solo para pruebas.
public final class AlmacenClavesMemoria: AlmacenClaves {
    private var valores: [String: String] = [:]

    public init() {}

    public func guardar(_ valor: String, para clave: String) throws {
        valores[clave] = valor
    }

    public func leer(_ clave: String) -> String? {
        valores[clave]
    }

    public func borrar(_ clave: String) throws {
        valores.removeValue(forKey: clave)
    }

    /// Cuantas claves hay guardadas. Sirve para comprobar que no se acumulan
    /// credenciales huerfanas al borrar un proveedor.
    public var cantidad: Int { valores.count }
}
