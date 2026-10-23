import Foundation

/// Una skill ya resuelta por el registro, lista para inyectar en un envio.
public struct SkillResuelta: Equatable {
    /// Nombre visible, por ejemplo "resumidor".
    public let nombre: String
    /// Identificador normalizado con el que se invoca, por ejemplo "resumidor".
    public let slug: String
    /// Instrucciones que se suman al contexto de ese turno.
    public let instrucciones: String

    public init(nombre: String, slug: String, instrucciones: String) {
        self.nombre = nombre
        self.slug = slug
        self.instrucciones = instrucciones
    }
}

/// Gancho de resolucion de skills.
///
/// En la Fase 3 el parser nace ya con este protocolo; la Fase 4 conecta el
/// almacen real de skills sin reescribir el parser ni sus tests (§4.2).
public protocol ResolvedorSkills {
    func skill(porSlug slug: String) -> SkillResuelta?
    func todas() -> [SkillResuelta]
}

/// Los cinco comandos locales del sistema (§4.2). Sus slugs son reservados.
public enum ComandoIntegrado: String, Equatable, CaseIterable {
    case compact
    case costo
    case modelos
    case nuevo
    case exportar
}

/// Resultado de analizar un texto enviado desde la caja.
public enum ResultadoAnalisis: Equatable {
    /// Texto normal, sin comandos ni skills: va al modelo tal cual.
    case mensajeNormal(texto: String)
    /// La linea entera es un comando local; no se envia nada al modelo.
    case comando(ComandoIntegrado)
    /// Skills resueltas y el mensaje limpio que queda tras quitarlas.
    case conSkills(skills: [SkillResuelta], mensaje: String)
    /// Tokens con "/" que no resolvieron a ninguna skill (sin la "/").
    case tokensDesconocidos([String])
    /// Habia skills pero no quedo mensaje: nunca se envia un turno vacio.
    case skillSinMensaje(skill: SkillResuelta)
}

/// La gramatica unica del parser de "/" (SPEC §4.5 / contrato §8).
///
/// Decision documentada: un comando integrado SOLO se reconoce cuando la linea
/// completa es exactamente "/nombre". Si lleva texto detras ("/compact ahora")
/// pasa al analisis de skills; como "compact" es un slug reservado, no se
/// resuelve como skill y cae en `.tokensDesconocidos`. Se eligio asi porque la
/// SPEC solo define la accion local para el comando solo y nunca debe
/// ejecutarse una accion por accidente mientras el usuario escribe un mensaje.
public enum AnalizadorComandos {
    /// Slugs que el almacen de skills no puede usar (§4.6). El parser tampoco
    /// los resuelve como skill: un comando con texto detras ("/compact ahora")
    /// cae en `.tokensDesconocidos` aunque un registro defectuoso los ofrezca.
    public static let slugsReservados: Set<String> = [
        "compact", "costo", "modelos", "nuevo", "exportar"
    ]

    public static func analizar(
        _ texto: String,
        resolvedor: ResolvedorSkills
    ) -> ResultadoAnalisis {
        let recortado = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recortado.hasPrefix("/") else {
            return .mensajeNormal(texto: recortado)
        }

        let tokens = recortado
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        // Comando integrado: solo si es el unico token de la linea.
        if tokens.count == 1,
           let primero = tokens.first,
           let comando = comandoDeToken(primero) {
            return .comando(comando)
        }

        var skills: [SkillResuelta] = []
        var slugsVistos = Set<String>()
        var desconocidos: [String] = []
        var partesMensaje: [String] = []

        for token in tokens {
            guard token.hasPrefix("/") else {
                partesMensaje.append(token)
                continue
            }

            let crudo = String(token.dropFirst())
            let slug = normalizarSlug(crudo)
            guard !slug.isEmpty,
                  !slugsReservados.contains(slug),
                  let skill = resolvedor.skill(porSlug: slug)
            else {
                // Se reporta el token sin la primera "/", tal como lo escribio
                // el usuario; asi "//" se reporta como "/" y "/" como "".
                desconocidos.append(crudo)
                continue
            }

            if slugsVistos.insert(skill.slug).inserted {
                skills.append(skill)
            }
        }

        if !desconocidos.isEmpty {
            return .tokensDesconocidos(desconocidos)
        }

        let mensaje = partesMensaje
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if mensaje.isEmpty {
            if let primera = skills.first {
                return .skillSinMensaje(skill: primera)
            }
            return .mensajeNormal(texto: recortado)
        }

        return .conSkills(skills: skills, mensaje: mensaje)
    }

    /// Normaliza un nombre a slug invocable.
    ///
    /// Minusculas, tildes fuera, espacios y guiones bajos convertidos en "-",
    /// cualquier caracter fuera de [a-z0-9-] descartado, guiones repetidos
    /// colapsados y sin guiones en los bordes.
    public static func normalizarSlug(_ texto: String) -> String {
        let plegado = texto
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()

        let permitidos = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        var piezas: [String] = []
        var actual = ""

        for escalar in plegado.unicodeScalars {
            let esSeparador = escalar == "-"
                || escalar == "_"
                || CharacterSet.whitespacesAndNewlines.contains(escalar)
            if esSeparador {
                if !actual.isEmpty {
                    piezas.append(actual)
                    actual = ""
                }
            } else if permitidos.contains(escalar) {
                actual.unicodeScalars.append(escalar)
            }
        }

        if !actual.isEmpty {
            piezas.append(actual)
        }
        return piezas.joined(separator: "-")
    }

    /// Reconoce el comando integrado de un token, sin aceptar "//nombre".
    private static func comandoDeToken(_ token: String) -> ComandoIntegrado? {
        guard token.hasPrefix("/") else { return nil }
        let cuerpo = token.dropFirst()
        guard !cuerpo.isEmpty, !cuerpo.contains("/") else { return nil }
        return ComandoIntegrado(rawValue: normalizarSlug(String(cuerpo)))
    }
}
