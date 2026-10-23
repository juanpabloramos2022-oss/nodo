import XCTest

@testable import NodoCore

final class SkillsLocalesTests: XCTestCase {
    func testCrearNormalizaSlugYPersisteEnElJSONDeLaConfiguracion() throws {
        var config = AppConfig()

        let resultado = AlmacenSkills.guardar(
            nombre: "Mi Skill de Ventas",
            instrucciones: "Responde como un vendedor consultivo.",
            en: &config
        )
        let skill = try resultado.get()

        XCTAssertEqual(skill.slug, "mi-skill-de-ventas")
        XCTAssertEqual(skill.nombre, "Mi Skill de Ventas")
        XCTAssertEqual(skill.instrucciones, "Responde como un vendedor consultivo.")
        XCTAssertEqual(config.skills, [skill])

        let recargada = try AppConfig.desde(json: try config.json())
        XCTAssertEqual(recargada.skills, [skill])
    }

    func testNombreReservadoNoCreaLaSkill() {
        var config = AppConfig()

        let resultado = AlmacenSkills.guardar(
            nombre: "Compact",
            instrucciones: "no deberia guardarse",
            en: &config
        )

        guard case .failure(.nombreReservado) = resultado else {
            XCTFail("se esperaba .nombreReservado, llego \(resultado)")
            return
        }
        XCTAssertTrue(config.skills.isEmpty)
    }

    func testSlugDuplicadoSeRechaza() throws {
        var config = AppConfig()
        _ = try config.guardar(nombre: "Ventas", instrucciones: "primera").get()

        let resultado = AlmacenSkills.guardar(
            nombre: "ventas",
            instrucciones: "segunda",
            en: &config
        )

        guard case .failure(.slugDuplicado) = resultado else {
            XCTFail("se esperaba .slugDuplicado, llego \(resultado)")
            return
        }
        XCTAssertEqual(config.skills.count, 1)
        XCTAssertEqual(config.skills.first?.instrucciones, "primera")
    }

    func testEditarCambiaInstruccionesConservandoElId() throws {
        var config = AppConfig()
        let original = try config.guardar(
            nombre: "Ventas",
            instrucciones: "instrucciones viejas"
        ).get()

        let resultado = AlmacenSkills.guardar(
            nombre: "Ventas",
            instrucciones: "instrucciones nuevas",
            idExistente: original.id,
            en: &config
        )
        let editada = try resultado.get()

        XCTAssertEqual(editada.id, original.id)
        XCTAssertEqual(editada.slug, "ventas")
        XCTAssertEqual(editada.instrucciones, "instrucciones nuevas")
        XCTAssertEqual(config.skills.count, 1)
        XCTAssertEqual(config.skills.first, editada)
    }

    func testEditarPuedeCambiarElSlugSinChocarConsigoMisma() throws {
        var config = AppConfig()
        let original = try config.guardar(
            nombre: "Ventas",
            instrucciones: "texto"
        ).get()

        let editada = try AlmacenSkills.guardar(
            nombre: "Ventas Consultivas",
            instrucciones: "texto",
            idExistente: original.id,
            en: &config
        ).get()

        XCTAssertEqual(editada.id, original.id)
        XCTAssertEqual(editada.slug, "ventas-consultivas")
        XCTAssertEqual(config.skills, [editada])
    }

    func testBorrarEliminaLaSkill() throws {
        var config = AppConfig()
        let una = try config.guardar(nombre: "Una", instrucciones: "a").get()
        let otra = try config.guardar(nombre: "Otra", instrucciones: "b").get()

        AlmacenSkills.borrar(id: una.id, en: &config)

        XCTAssertEqual(config.skills, [otra])
        XCTAssertFalse(config.skills.contains { $0.id == una.id })
    }

    func testBorrarInexistenteNoTocaLasDemas() throws {
        var config = AppConfig()
        let una = try config.guardar(nombre: "Una", instrucciones: "a").get()

        config.borrar(id: UUID())

        XCTAssertEqual(config.skills, [una])
    }
}
