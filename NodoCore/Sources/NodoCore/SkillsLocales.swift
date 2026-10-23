import Foundation

/// Una skill local: instrucciones con nombre que se guardan en el telefono.
///
/// El `nombre` es lo que ve la persona; el `slug` es el identificador invocable
/// (`/mi-skill-de-ventas`) y siempre se calcula con
/// `AnalizadorComandos.normalizarSlug` al guardar. Las instrucciones no se
/// guardan en el historial: solo viajan en el payload del turno que las usa.
public struct SkillLocal: Codable, Identifiable, Equatable {
    public var id: UUID
    public var nombre: String
    public var slug: String
    public var instrucciones: String

    public init(
        id: UUID = UUID(),
        nombre: String,
        slug: String,
        instrucciones: String
    ) {
        self.id = id
        self.nombre = nombre
        self.slug = slug
        self.instrucciones = instrucciones
    }
}

/// Errores al guardar una skill, con mensajes listos para mostrar.
public enum ErrorSkill: Error, Equatable, LocalizedError {
    /// El slug coincide con uno de los cinco comandos del sistema.
    case nombreReservado
    /// Otra skill ya usa ese slug.
    case slugDuplicado

    public var errorDescription: String? {
        switch self {
        case .nombreReservado:
            return "Ese nombre esta reservado para un comando del sistema."
        case .slugDuplicado:
            return "Ya existe una skill con ese identificador."
        }
    }
}

/// Reglas puras del almacen de skills.
///
/// No hay reloj, red ni disco aqui: las funciones reciben la configuracion y la
/// modifican en el sitio, para que la app solo tenga que guardar el resultado.
/// El slug se normaliza SIEMPRE al guardar, tanto al crear como al editar, y se
/// valida contra los nombres reservados y contra las demas skills.
public enum AlmacenSkills {
    /// Crea una skill nueva o edita la que tenga `idExistente`.
    ///
    /// - Parameters:
    ///   - nombre: Nombre visible escrito por la persona.
    ///   - instrucciones: Texto que se inyecta en el contexto del turno.
    ///   - idExistente: nil para crear; el id de una skill para editarla.
    ///   - config: Configuracion que se actualiza solo si el guardado prospera.
    /// - Returns: La skill guardada o el error de validacion.
    public static func guardar(
        nombre: String,
        instrucciones: String,
        idExistente: UUID? = nil,
        en config: inout AppConfig
    ) -> Result<SkillLocal, ErrorSkill> {
        let slug = AnalizadorComandos.normalizarSlug(nombre)

        // Un nombre sin letras ni numeros deja un slug vacio que no se puede
        // invocar. No hay un tercer caso de error en el contrato, asi que se
        // rechaza con el mismo aviso que un nombre no utilizable.
        guard !slug.isEmpty, !AnalizadorComandos.slugsReservados.contains(slug) else {
            return .failure(.nombreReservado)
        }

        let duplicada = config.skills.contains { skill in
            skill.slug == slug && skill.id != idExistente
        }
        guard !duplicada else { return .failure(.slugDuplicado) }

        let skill: SkillLocal
        if let idExistente,
           let indice = config.skills.firstIndex(where: { $0.id == idExistente }) {
            skill = SkillLocal(
                id: idExistente,
                nombre: nombre,
                slug: slug,
                instrucciones: instrucciones
            )
            config.skills[indice] = skill
        } else {
            skill = SkillLocal(
                id: idExistente ?? UUID(),
                nombre: nombre,
                slug: slug,
                instrucciones: instrucciones
            )
            config.skills.append(skill)
        }

        return .success(skill)
    }

    /// Borra la skill con ese id. Si no existe, no hace nada.
    public static func borrar(id: UUID, en config: inout AppConfig) {
        config.skills.removeAll { $0.id == id }
    }
}

/// Atajos sobre la configuracion para que la interfaz no repita el `inout`.
extension AppConfig {
    /// Crea o edita una skill; vease `AlmacenSkills.guardar`.
    @discardableResult
    public mutating func guardar(
        nombre: String,
        instrucciones: String,
        idExistente: UUID? = nil
    ) -> Result<SkillLocal, ErrorSkill> {
        AlmacenSkills.guardar(
            nombre: nombre,
            instrucciones: instrucciones,
            idExistente: idExistente,
            en: &self
        )
    }

    /// Borra una skill por id; vease `AlmacenSkills.borrar`.
    public mutating func borrar(id: UUID) {
        AlmacenSkills.borrar(id: id, en: &self)
    }
}
