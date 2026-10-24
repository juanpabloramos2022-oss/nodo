import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// H6.5: la lista de Conexiones se agrupa por URL base y "+ Anadir modelo/combo"
/// suma un modelo a un proveedor existente sin crear un proveedor nuevo.
@MainActor
final class ConexionesAgrupacionTests: XCTestCase {

    func testDosProveedoresConLaMismaURLBaseFormanUnSoloGrupo() {
        let uno = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/uno"
        )
        let dos = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/dos"
        )

        let grupos = AgrupacionConexiones.agrupar([uno, dos])

        XCTAssertEqual(grupos.count, 1)
        XCTAssertEqual(grupos.first?.proveedores.count, 2)
        XCTAssertEqual(
            Set(grupos.first?.proveedores.map(\.id) ?? []),
            Set([uno.id, dos.id])
        )
    }

    func testProveedoresConURLBaseDistintaVanEnGruposSeparados() {
        let uno = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/uno"
        )
        let otro = ProviderConfig(
            nombre: "Otro",
            baseURL: "https://api.otro.dev/v1",
            modelo: "otro-modelo"
        )

        let grupos = AgrupacionConexiones.agrupar([uno, otro])

        XCTAssertEqual(grupos.count, 2)
        XCTAssertTrue(grupos.allSatisfy { $0.proveedores.count == 1 })
    }

    /// Anadir un modelo a un proveedor existente lo suma a la configuracion y
    /// lo deja persistido, sin borrar ni duplicar el proveedor de origen.
    func testAnadirModeloPersisteEnLaConfiguracion() throws {
        let arnes = try ArnesApp()
        defer { arnes.limpiar() }

        let origen = try XCTUnwrap(arnes.estado.config.proveedorSeleccionado)
        let cantidadAntes = arnes.estado.config.proveedores.count

        var nuevo = arnes.estado.proveedorDuplicado(desde: origen)
        nuevo.modelo = "combo/nuevo"
        nuevo.precioEntradaPorMillon = 1
        nuevo.precioSalidaPorMillon = 2

        arnes.estado.actualizarProveedor(nuevo)

        XCTAssertEqual(arnes.estado.config.proveedores.count, cantidadAntes + 1)
        XCTAssertTrue(
            arnes.estado.config.proveedores.contains {
                $0.id == nuevo.id && $0.modelo == "combo/nuevo"
            }
        )
        // El proveedor de origen sigue intacto: no se reemplazo por el nuevo.
        XCTAssertTrue(
            arnes.estado.config.proveedores.contains { $0.id == origen.id }
        )
        // Hereda la URL base del origen, asi que cae en SU MISMO grupo: no se
        // crea un proveedor nuevo, se suma un modelo al que ya existia.
        XCTAssertEqual(nuevo.baseURL, origen.baseURL)
        let grupos = AgrupacionConexiones.agrupar(arnes.estado.config.proveedores)
        let grupo = try XCTUnwrap(
            grupos.first { $0.proveedores.contains { $0.id == nuevo.id } }
        )
        XCTAssertTrue(grupo.proveedores.contains { $0.id == origen.id })

        // Persistencia real: la configuracion releida trae el modelo nuevo.
        let datos = try XCTUnwrap(arnes.defaults.data(forKey: "nodo.config.v1"))
        let releida = try AppConfig.desde(json: datos)
        XCTAssertTrue(
            releida.proveedores.contains {
                $0.id == nuevo.id && $0.modelo == "combo/nuevo"
            }
        )
    }
}