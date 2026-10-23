import Foundation
import XCTest

@testable import Nodo
import NodoCore

/// Pruebas de la siembra del pack de skills de fabrica (PACK.1/PACK.2).
///
/// POR QUE un arranque propio y no `ArnesApp`: estas pruebas necesitan dos
/// cosas que el arnes compartido no da. Primero, que el `EstadoApp` se
/// construya con una configuracion YA escrita en las preferencias (para
/// simular una actualizacion con skills del dueno o con el marcador al dia).
/// Segundo, volver a arrancar sobre la MISMA suite para comprobar que el
/// marcador evita la resiembra. `ArnesApp` crea una suite nueva por test y
/// aplica su configuracion despues del init, que es justo lo que aqui
/// invalidaria la prueba. El `EstadoApp` que se usa es el de produccion, con
/// dobles solo en llavero, red, preferencias y carpeta.
@MainActor
final class SkillsFabricaTests: XCTestCase {

    /// Los 12 slugs del pack, escritos a mano a proposito.
    ///
    /// POR QUE no se leen de `PackSkillsFabrica.skills`: la prueba tiene que
    /// detectar si un slug del anexo cambia o desaparece, no repetir lo que el
    /// codigo ya dice.
    private static let slugsDelPack: Set<String> = [
        "grill-me",
        "en-cristiano",
        "guion-video",
        "prompt-en-ingles",
        "copy-fresco",
        "responder-cliente",
        "tutor-ia",
        "resume-enlace",
        "investiga",
        "traspaso",
        "memoria-orden",
        "crea-skills"
    ]

    // MARK: - 1. Arranque limpio

    func testArranqueSinSkillsSiembraLosDoceSlugsDeFabrica() throws {
        let arranque = try Arranque()
        defer { arranque.limpiar() }

        let estado = arranque.arrancar()
        let sembradas = estado.config.skills

        XCTAssertEqual(sembradas.count, 12)
        XCTAssertEqual(Set(sembradas.map(\.slug)), Self.slugsDelPack)
        XCTAssertTrue(
            sembradas.allSatisfy { $0.origen == .fabrica },
            "Toda skill sembrada tiene que llevar la marca de origen de fabrica"
        )
        XCTAssertTrue(
            sembradas.allSatisfy {
                !$0.instrucciones.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            "Ninguna skill del pack puede sembrarse con el texto vacio"
        )
        XCTAssertTrue(
            sembradas.allSatisfy {
                !($0.descripcion ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            "El pack trae la descripcion de selector de cada skill"
        )
        XCTAssertEqual(estado.config.packSkillsVersion, PACK_VERSION)
        XCTAssertEqual(estado.config.packSkillsVersion, 1)

        // El marcador y las skills tienen que quedar PERSISTIDOS: si solo
        // vivieran en memoria, el siguiente arranque volveria a sembrar.
        let guardada = try AppConfig.desde(
            json: try XCTUnwrap(arranque.configPersistida())
        )
        XCTAssertEqual(guardada.packSkillsVersion, 1)
        XCTAssertEqual(Set(guardada.skills.map(\.slug)), Self.slugsDelPack)
    }

    // MARK: - 2. Marcador al dia

    func testSegundoArranqueConMarcadorAlDiaNoCreaNiModificaNada() throws {
        let arranque = try Arranque()
        defer { arranque.limpiar() }

        let primero = arranque.arrancar()
        XCTAssertEqual(primero.config.skills.count, 12)
        let jsonAntes = try XCTUnwrap(arranque.configPersistida())

        let segundo = arranque.arrancar()

        XCTAssertEqual(segundo.config.skills, primero.config.skills)
        XCTAssertEqual(segundo.config.packSkillsVersion, 1)
        // La prueba fuerte: con el marcador al dia no se reescribe NI UN byte
        // de la configuracion. Si la siembra corriera en cada apertura, el
        // archivo cambiaria (ids nuevos o textos repuestos).
        let jsonDespues = try XCTUnwrap(arranque.configPersistida())
        XCTAssertEqual(
            jsonDespues,
            jsonAntes,
            "El segundo arranque no puede tocar la configuracion persistida"
        )
    }

    // MARK: - 3. Skill del dueno con un slug del pack

    func testSkillDelDuenoConSlugGrillMeNoSeTocaYSeCreanLasOtrasOnce() throws {
        let delDueno = SkillLocal(
            nombre: "Mi grill",
            slug: "grill-me",
            instrucciones: "TEXTO DEL DUENO QUE NO SE PUEDE TOCAR"
        )
        let arranque = try Arranque(configInicial: AppConfig(skills: [delDueno]))
        defer { arranque.limpiar() }

        let estado = arranque.arrancar()

        XCTAssertEqual(estado.config.skills.count, 12)
        let conservadas = estado.config.skills.filter { $0.slug == "grill-me" }
        XCTAssertEqual(conservadas.count, 1, "No puede duplicarse el slug del dueno")

        let conservada = try XCTUnwrap(conservadas.first)
        XCTAssertEqual(conservada.id, delDueno.id)
        XCTAssertEqual(conservada.nombre, "Mi grill")
        XCTAssertEqual(
            conservada.instrucciones,
            "TEXTO DEL DUENO QUE NO SE PUEDE TOCAR"
        )
        XCTAssertEqual(conservada.origen, .propia)

        // Las otras once si nacen del pack.
        let delPack = estado.config.skills.filter { $0.origen == .fabrica }
        XCTAssertEqual(delPack.count, 11)
        XCTAssertEqual(
            Set(delPack.map(\.slug)),
            Self.slugsDelPack.subtracting(["grill-me"])
        )
    }

    // MARK: - 4. Skill de fabrica editada por el dueno

    func testSkillDeFabricaEditadaPorElDuenoNoSeSobrescribe() throws {
        let editada = SkillLocal(
            nombre: "Grill-me",
            slug: "grill-me",
            descripcion: "descripcion original",
            instrucciones: "TEXTO EDITADO POR EL DUENO",
            origen: .fabrica
        )
        let arranque = try Arranque(configInicial: AppConfig(skills: [editada]))
        defer { arranque.limpiar() }

        let estado = arranque.arrancar()

        XCTAssertEqual(estado.config.skills.count, 12)
        let conservadas = estado.config.skills.filter { $0.slug == "grill-me" }
        XCTAssertEqual(conservadas.count, 1)

        let conservada = try XCTUnwrap(conservadas.first)
        XCTAssertEqual(conservada.id, editada.id)
        XCTAssertEqual(conservada.instrucciones, "TEXTO EDITADO POR EL DUENO")
        XCTAssertEqual(conservada.origen, .fabrica)
        // Y el texto original del pack no puede reaparecer por ningun lado.
        XCTAssertFalse(
            estado.config.skills.contains {
                $0.slug == "grill-me" && $0.instrucciones.contains("Eres mi entrevistador")
            }
        )
    }

    // MARK: - 5. Borrar una de fabrica y restaurar

    func testBorrarUnaDeFabricaYRestaurarVuelveSoloLaBorradaSinDuplicar() throws {
        let arranque = try Arranque()
        defer { arranque.limpiar() }

        let estado = arranque.arrancar()
        let idsAntes = Dictionary(
            estado.config.skills.map { ($0.slug, $0.id) },
            uniquingKeysWith: { primero, _ in primero }
        )
        let borrada = try XCTUnwrap(
            estado.config.skills.first { $0.slug == "copy-fresco" }
        )
        estado.borrarSkill(id: borrada.id)
        XCTAssertEqual(estado.config.skills.count, 11)

        // Lo borrado no resucita solo: el marcador ya subio y un arranque
        // normal no repone nada.
        let relanzado = arranque.arrancar()
        XCTAssertEqual(relanzado.config.skills.count, 11)
        XCTAssertFalse(relanzado.config.skills.contains { $0.slug == "copy-fresco" })

        // El boton explicito repone SOLO la borrada.
        let repuestas = relanzado.restaurarSkillsDeFabrica()
        XCTAssertEqual(repuestas, 1)
        XCTAssertEqual(relanzado.config.skills.count, 12)
        XCTAssertEqual(Set(relanzado.config.skills.map(\.slug)), Self.slugsDelPack)

        let restaurada = try XCTUnwrap(
            relanzado.config.skills.first { $0.slug == "copy-fresco" }
        )
        XCTAssertEqual(restaurada.origen, .fabrica)
        let definicion = try XCTUnwrap(
            PackSkillsFabrica.skills.first { $0.slug == "copy-fresco" }
        )
        XCTAssertEqual(restaurada.instrucciones, definicion.instrucciones)

        // Ninguna de las otras once se toco: mismo id, sin duplicados.
        for (slug, id) in idsAntes where slug != "copy-fresco" {
            let actual = try XCTUnwrap(
                relanzado.config.skills.first { $0.slug == slug }
            )
            XCTAssertEqual(actual.id, id, "Restaurar no puede tocar \(slug)")
        }

        // Un segundo toque no duplica ni repone nada.
        XCTAssertEqual(relanzado.restaurarSkillsDeFabrica(), 0)
        XCTAssertEqual(relanzado.config.skills.count, 12)
    }

    // MARK: - 6. Las skills del dueno nunca son de fabrica

    func testSkillsDelDuenoNuncaRecibenOrigenDeFabrica() throws {
        let arranque = try Arranque()
        defer { arranque.limpiar() }

        let estado = arranque.arrancar()
        let nueva = try estado.guardarSkill(
            nombre: "Mia",
            instrucciones: "Instrucciones escritas por el dueno."
        ).get()

        XCTAssertEqual(nueva.origen, .propia)
        XCTAssertNil(nueva.descripcion)
        XCTAssertEqual(estado.config.skills.count, 13)
        XCTAssertEqual(estado.config.skills.filter { $0.origen == .fabrica }.count, 12)
        let mia = try XCTUnwrap(estado.config.skills.first { $0.slug == "mia" })
        XCTAssertEqual(mia.origen, .propia)

        // Y una skill guardada ANTES de PACK.1, cuyo JSON no trae `origen` ni
        // `descripcion`, se lee como propia: actualizar la app no puede
        // convertir el contenido del dueno en pack.
        var legado = AppConfig()
        legado.skills = [
            SkillLocal(
                nombre: "Vieja",
                slug: "vieja",
                instrucciones: "Texto guardado antes del pack."
            )
        ]
        let datosLegado = try jsonSinCamposNuevos(de: legado)
        let arranqueLegado = try Arranque(datosIniciales: datosLegado)
        defer { arranqueLegado.limpiar() }

        let estadoLegado = arranqueLegado.arrancar()
        let vieja = try XCTUnwrap(
            estadoLegado.config.skills.first { $0.slug == "vieja" }
        )
        XCTAssertEqual(vieja.origen, .propia)
        XCTAssertEqual(vieja.instrucciones, "Texto guardado antes del pack.")
        XCTAssertEqual(estadoLegado.config.skills.count, 13)
        XCTAssertEqual(
            estadoLegado.config.skills.filter { $0.origen == .fabrica }.count,
            12
        )
    }

    // MARK: - Ayudas

    /// JSON de una configuracion como lo escribia la app antes de PACK.1:
    /// sin `origen`, sin `descripcion` y sin marcador del pack.
    private func jsonSinCamposNuevos(de config: AppConfig) throws -> Data {
        var objeto = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try config.json()) as? [String: Any]
        )
        var skills = try XCTUnwrap(objeto["skills"] as? [[String: Any]])
        for indice in skills.indices {
            skills[indice].removeValue(forKey: "origen")
            skills[indice].removeValue(forKey: "descripcion")
        }
        objeto["skills"] = skills
        objeto.removeValue(forKey: "packSkillsVersion")
        return try JSONSerialization.data(withJSONObject: objeto)
    }

    /// Un arranque real de `EstadoApp` sobre preferencias y carpeta temporales.
    ///
    /// `arrancar()` se puede llamar varias veces: cada llamada construye un
    /// `EstadoApp` nuevo sobre la MISMA suite, que es lo que hace la app al
    /// abrirse otra vez.
    @MainActor
    private final class Arranque {
        private let nombreSuite: String
        private let defaults: UserDefaults
        private let directorio: URL
        private let llavero = LlaveroFalso()
        private let transporte = TransporteGuionizado()

        init(configInicial: AppConfig? = nil, datosIniciales: Data? = nil) throws {
            let sufijo = UUID().uuidString
            nombreSuite = "com.nodo.ios.apptests.skills.\(sufijo)"
            directorio = FileManager.default.temporaryDirectory
                .appendingPathComponent("NodoAppTests-skills-\(sufijo)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directorio,
                withIntermediateDirectories: true
            )
            defaults = try XCTUnwrap(UserDefaults(suiteName: nombreSuite))
            defaults.removePersistentDomain(forName: nombreSuite)

            // Se escribe ANTES del init: el arranque la lee como si viniera de
            // una instalacion anterior, con sus skills y su marcador.
            if let datosIniciales {
                defaults.set(datosIniciales, forKey: "nodo.config.v1")
            } else if let configInicial {
                defaults.set(try configInicial.json(), forKey: "nodo.config.v1")
            }
        }

        func arrancar() -> EstadoApp {
            EstadoApp(
                llavero: llavero,
                transporte: transporte,
                defaults: defaults,
                directorioStore: directorio,
                directorioTareas: TareaStore.directorioEn(directorio)
            )
        }

        func configPersistida() -> Data? {
            defaults.data(forKey: "nodo.config.v1")
        }

        func limpiar() {
            defaults.removePersistentDomain(forName: nombreSuite)
            try? FileManager.default.removeItem(at: directorio)
        }
    }
}
