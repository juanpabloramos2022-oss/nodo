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
    /// Linea corta que se ve en el selector de "/".
    ///
    /// Las skills del pack la traen escrita; las que crea el dueno nacen sin
    /// ella (nil) y el selector sigue mostrando su nombre. No es obligatoria
    /// para invocar la skill: el texto que manda es `instrucciones`.
    public var descripcion: String?
    public var instrucciones: String
    /// De donde salio la skill (PACK.1). Visible como "De fábrica" en Mi
    /// Contexto > Skills; no cambia como se edita, invoca ni borra.
    public var origen: OrigenSkill

    public init(
        id: UUID = UUID(),
        nombre: String,
        slug: String,
        descripcion: String? = nil,
        instrucciones: String,
        origen: OrigenSkill = .propia
    ) {
        self.id = id
        self.nombre = nombre
        self.slug = slug
        self.descripcion = descripcion
        self.instrucciones = instrucciones
        self.origen = origen
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nombre
        case slug
        case descripcion
        case instrucciones
        case origen
    }

    /// Decodificacion tolerante con las skills guardadas antes de PACK.1.
    ///
    /// `descripcion` y `origen` no existian en ese formato. Se leen como nil y
    /// `.propia` respectivamente: el dueno es el unico que pudo crear esas
    /// skills, y marcarlas de fabrica por actualizar la app seria mentirle
    /// sobre el origen de su propio contenido (y ademas las volveria candidatas
    /// del pack, que es justo lo que la siembra no puede hacer).
    public init(from decoder: Decoder) throws {
        let contenedor = try decoder.container(keyedBy: CodingKeys.self)
        id = try contenedor.decode(UUID.self, forKey: .id)
        nombre = try contenedor.decode(String.self, forKey: .nombre)
        slug = try contenedor.decode(String.self, forKey: .slug)
        descripcion = try contenedor.decodeIfPresent(String.self, forKey: .descripcion)
        instrucciones = try contenedor.decode(String.self, forKey: .instrucciones)
        origen = try contenedor.decodeIfPresent(OrigenSkill.self, forKey: .origen)
            ?? .propia
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
            // Editar el texto no cambia de donde vino la skill ni le borra su
            // descripcion de selector: se conservan las marcas del registro.
            // Si el dueno la edita, el texto editado manda y la siembra ya no
            // la toca (su slug sigue existiendo), pero sigue siendo del pack.
            let anterior = config.skills[indice]
            skill = SkillLocal(
                id: idExistente,
                nombre: nombre,
                slug: slug,
                descripcion: anterior.descripcion,
                instrucciones: instrucciones,
                origen: anterior.origen
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
