import Foundation

import NodoCore

/// Resolvedor de skills de esta fase (§4.2/§4.4).
///
/// Hoy la lista esta VACIA en produccion: el parser ya nace con el puerto y la
/// ruta de envio, pero el almacen persistido de skills llega en la Fase 4. Esa
/// fase solo tendra que rellenar `skills` (o sustituir esta instancia por otra
/// que cumpla `ResolvedorSkills`); el parser y `EstadoApp` no cambian.
///
/// Vive en la app, no en NodoCore, porque es una fuente de datos de interfaz y
/// no una regla del parser.
final class ResolvedorSkillsEnMemoria: ResolvedorSkills {
    /// Skills disponibles ahora mismo. En esta fase arranca vacia.
    var skills: [SkillResuelta] = []

    func skill(porSlug slug: String) -> SkillResuelta? {
        skills.first { $0.slug == slug }
    }

    func todas() -> [SkillResuelta] {
        skills
    }
}
