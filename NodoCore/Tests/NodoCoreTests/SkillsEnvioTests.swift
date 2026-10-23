import XCTest

@testable import NodoCore

/// Cadena completa de una skill en un envio: el parser la resuelve, el
/// historial recibe sus instrucciones y el payload las lleva en ese turno.
///
/// No depende de ninguna respuesta de un LLM: comprueba el texto que sale hacia
/// el cliente HTTP (§4.4).
final class SkillsEnvioTests: XCTestCase {
    private struct ResolvedorFijo: ResolvedorSkills {
        let lista: [SkillResuelta]

        func skill(porSlug slug: String) -> SkillResuelta? {
            lista.first { $0.slug == slug }
        }

        func todas() -> [SkillResuelta] {
            lista
        }
    }

    func testLaSkillInvocadaInyectaSusInstruccionesEnElPayload() {
        let skill = SkillResuelta(
            nombre: "Resumidor",
            slug: "resumidor",
            instrucciones: "Resume en tres puntos claros."
        )
        let resolvedor = ResolvedorFijo(lista: [skill])

        let analisis = AnalizadorComandos.analizar(
            "/resumidor hola",
            resolvedor: resolvedor
        )
        guard case .conSkills(let skills, let mensaje) = analisis else {
            XCTFail("Se esperaba .conSkills, llego \(analisis)")
            return
        }

        XCTAssertEqual(mensaje, "hola")
        XCTAssertEqual(skills.map(\.nombre), ["Resumidor"])

        let historial = [
            ChatMessage(rol: .sistema, texto: "Memoria"),
            ChatMessage(rol: .usuario, texto: mensaje)
        ]
        let payload = Historial.insertarInstrucciones(
            historial,
            instrucciones: skills.map(\.instrucciones)
        )

        XCTAssertTrue(
            payload.contains {
                $0.rol == .sistema && $0.texto == "Resume en tres puntos claros."
            },
            "Las instrucciones de la skill no viajaron en el payload"
        )
        XCTAssertEqual(payload.last?.rol, .usuario)
        XCTAssertEqual(payload.last?.texto, "hola")
    }

    func testUnaSkillBorradaCaeEnTokensDesconocidos() {
        let resolvedor = ResolvedorFijo(lista: [])

        let analisis = AnalizadorComandos.analizar(
            "/resumidor hola",
            resolvedor: resolvedor
        )

        guard case .tokensDesconocidos(let slugs) = analisis else {
            XCTFail("Se esperaba .tokensDesconocidos, llego \(analisis)")
            return
        }
        XCTAssertEqual(slugs, ["resumidor"])
    }
}
