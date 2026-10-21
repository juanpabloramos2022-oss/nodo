import Foundation
import Security

import NodoCore

/// Error del llavero del sistema.
struct ErrorLlavero: LocalizedError {
    let estado: OSStatus

    var errorDescription: String? {
        let detalle = SecCopyErrorMessageString(estado, nil) as String? ?? "codigo \(estado)"
        return "No se pudo acceder al llavero: \(detalle)"
    }
}

/// Guarda las credenciales en el llavero del telefono.
///
/// Se usa `WhenUnlockedThisDeviceOnly` a proposito: la clave no debe salir del
/// dispositivo ni siquiera a traves de una copia de seguridad de iCloud, y no
/// debe poder leerse con el telefono bloqueado.
final class LlaveroAlmacen: AlmacenClaves {
    private let servicio = "com.nodo.ios.credenciales"

    private func consultaBase(_ clave: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: clave
        ]
    }

    func guardar(_ valor: String, para clave: String) throws {
        let datos = Data(valor.utf8)
        let base = consultaBase(clave)

        // Se borra y se vuelve a escribir: es la unica forma de actualizar un
        // elemento existente sin depender de si ya estaba o no.
        SecItemDelete(base as CFDictionary)

        var nuevo = base
        nuevo[kSecValueData as String] = datos
        nuevo[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let estado = SecItemAdd(nuevo as CFDictionary, nil)
        guard estado == errSecSuccess else { throw ErrorLlavero(estado: estado) }
    }

    func leer(_ clave: String) -> String? {
        var consulta = consultaBase(clave)
        consulta[kSecReturnData as String] = true
        consulta[kSecMatchLimit as String] = kSecMatchLimitOne

        var resultado: CFTypeRef?
        let estado = SecItemCopyMatching(consulta as CFDictionary, &resultado)
        guard estado == errSecSuccess,
              let datos = resultado as? Data,
              let texto = String(data: datos, encoding: .utf8)
        else {
            return nil
        }
        return texto
    }

    func borrar(_ clave: String) throws {
        let estado = SecItemDelete(consultaBase(clave) as CFDictionary)
        // Borrar algo que no existe no es un error para quien llama.
        guard estado == errSecSuccess || estado == errSecItemNotFound else {
            throw ErrorLlavero(estado: estado)
        }
    }
}
