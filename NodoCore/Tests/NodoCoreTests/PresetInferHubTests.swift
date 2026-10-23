import XCTest

@testable import NodoCore

final class PresetInferHubTests: XCTestCase {
    func testInicialTraeLosCuatroCombosDeInferHub() {
        let config = AppConfig.inicial()

        XCTAssertEqual(config.proveedores.count, 4)
        XCTAssertTrue(config.proveedores.allSatisfy { $0.nombre == "InferHub" })
        XCTAssertTrue(config.proveedores.allSatisfy {
            $0.baseURL == "https://api.inferhub.dev/v1"
        })
        XCTAssertTrue(config.proveedores.allSatisfy { $0.protocolo == .chatCompletions })
    }

    func testElActivoEsDeepSeekPorDefecto() {
        let config = AppConfig.inicial()

        XCTAssertEqual(config.proveedorSeleccionado?.modelo, "combo/deepseek-v4-1-flash")
        XCTAssertEqual(config.proveedorActivo, config.proveedorSeleccionado?.id)
    }

    func testLosPreciosSonLosDeLaSpec() throws {
        let config = AppConfig.inicial()
        var precios: [String: (Double?, Double?)] = [:]
        for proveedor in config.proveedores {
            precios[proveedor.modelo] = (
                proveedor.precioEntradaPorMillon,
                proveedor.precioSalidaPorMillon
            )
        }

        let esperados: [String: (Double, Double)] = [
            "combo/deepseek-v4-1-flash": (0.03, 0.12),
            "combo/glm-5-3-flash": (0.03, 0.10),
            "combo/gpt-6-1-sol": (0.6, 3),
            "combo/gpt-6-astra": (3, 15)
        ]

        XCTAssertEqual(precios.count, esperados.count)
        for (modelo, esperado) in esperados {
            let guardado = try XCTUnwrap(precios[modelo])
            let entrada = try XCTUnwrap(guardado.0)
            let salida = try XCTUnwrap(guardado.1)
            XCTAssertEqual(entrada, esperado.0, accuracy: 0.0000001)
            XCTAssertEqual(salida, esperado.1, accuracy: 0.0000001)
        }
    }

    func testLosIdsSonFijosParaQueElEstadoInicialSeaDeterminista() {
        XCTAssertEqual(
            AppConfig.inicial().proveedores.map(\.id),
            AppConfig.inicial().proveedores.map(\.id)
        )
    }

    func testLaIdaYVueltaPorJSONConservaLosCuatroRegistros() throws {
        let original = AppConfig.inicial()

        let vuelta = try AppConfig.desde(json: try original.json())

        XCTAssertEqual(vuelta.proveedores, original.proveedores)
        XCTAssertEqual(vuelta.proveedorActivo, original.proveedorActivo)
    }
}

final class CompanerosDeHostTests: XCTestCase {
    func testMismoHostConDistintaRutaEmpareja() {
        let uno = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/uno"
        )
        let dos = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v2",
            modelo: "combo/dos"
        )
        let config = AppConfig(proveedores: [uno, dos], proveedorActivo: uno.id)

        XCTAssertEqual(config.companerosDeHost(de: uno).map(\.id), [dos.id])
        XCTAssertEqual(config.companerosDeHost(de: dos).map(\.id), [uno.id])
    }

    func testElHostSeComparaSinMayusculasNiPuerto() {
        let uno = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/uno"
        )
        let dos = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://API.InferHub.DEV:443/v2",
            modelo: "combo/dos"
        )
        let config = AppConfig(proveedores: [uno, dos], proveedorActivo: uno.id)

        XCTAssertEqual(config.companerosDeHost(de: uno).map(\.id), [dos.id])
    }

    func testHostsDistintosNoEmparejan() {
        let uno = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/uno"
        )
        let otro = ProviderConfig(
            nombre: "Otro",
            baseURL: "https://api.deepseek.com/v1",
            modelo: "deepseek-chat"
        )
        let config = AppConfig(proveedores: [uno, otro], proveedorActivo: uno.id)

        XCTAssertTrue(config.companerosDeHost(de: uno).isEmpty)
    }

    func testElPropioProveedorNoSeIncluye() {
        let proveedor = ProviderConfig(
            nombre: "InferHub",
            baseURL: "https://api.inferhub.dev/v1",
            modelo: "combo/uno"
        )
        let config = AppConfig(proveedores: [proveedor], proveedorActivo: proveedor.id)

        XCTAssertTrue(config.companerosDeHost(de: proveedor).isEmpty)
    }

    func testUnaURLInvalidaNoEmparejaConNada() {
        let uno = ProviderConfig(nombre: "Roto", baseURL: "", modelo: "m")
        let dos = ProviderConfig(nombre: "Roto", baseURL: "", modelo: "n")
        let config = AppConfig(proveedores: [uno, dos], proveedorActivo: uno.id)

        XCTAssertTrue(config.companerosDeHost(de: uno).isEmpty)
        XCTAssertTrue(config.companerosDeHost(de: dos).isEmpty)
    }
}
