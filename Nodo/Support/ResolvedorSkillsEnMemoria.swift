import Foundation

import NodoCore

/// Resolvedor de skills conectado al almacen real (§4.2/§4.4).
///
/// `EstadoApp` copia aqui `config.skills` cada vez que cambia la configuracion
/// (al crear, editar, borrar o importar). Asi el parser de "/" y el selector
/// flotante leen las skills persistidas sin conocer la interfaz, y una skill
/// borrada deja de resolverse en el acto.
///
/// Vive en la app, no en NodoCore, porque es una fuente de datos de interfaz y
/// no una regla del parser.
final class ResolvedorSkillsEnMemoria: ResolvedorSkills {
    /// Espejo de `config.skills` en la forma que consume el parser.
    var skills: [SkillResuelta] = []

    func skill(porSlug slug: String) -> SkillResuelta? {
        skills.first { $0.slug == slug }
    }

    func todas() -> [SkillResuelta] {
        skills
    }
}
