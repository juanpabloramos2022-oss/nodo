import Foundation

/// Una skill ya resuelta por el registro, lista para inyectar en un envio.
public struct SkillResuelta: Equatable {
    /// Nombre visible, por ejemplo "resumidor".
    public let nombre: String
    /// Identificador normalizado con el que se invoca, por ejemplo "resumidor".
    public let slug: String
    /// Linea corta que se ve en el selector de "/".
    ///
    /// Las skills del pack la traen; las propias que no la escribieron dejan
    /// nil y el selector sigue mostrando su nombre. No viaja al payload: el
    /// modelo solo recibe las instrucciones.
    public let descripcion: String?
    /// Instrucciones que se suman al contexto de ese turno.
    public let instrucciones: String

    public init(
        nombre: String,
        slug: String,
        descripcion: String? = nil,
        instrucciones: String
    ) {
        self.nombre = nombre
        self.slug = slug
        self.descripcion = descripcion
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

/// Los comandos locales del sistema (§4.2) mas /plan y /boost.
///
/// /plan es una adicion firmada del dueno para TASK.2: genera un plan por pasos
/// sin ejecutar herramientas y lo deja como mensaje en el chat. Se suma a la
/// gramatica existente; no se crea un parser paralelo.
///
/// /boost (BOOST.1) se registra aqui por la misma razon, pero su accion NO vive
/// en el chat: marca el disparo de la tuberia multi-agente DENTRO de una Tarea.
/// La linea "/boost" sola en un chat no puede ejecutar nada util, asi que la
/// app solo avisa donde se usa; el reconocimiento con texto detras lo hace
/// `instruccionDeBoost`, porque la instruccion efectiva es el resto del texto.
public enum ComandoIntegrado: String, Equatable, CaseIterable {
    case compact
    case costo
    case modelos
    case nuevo
    case exportar
    case plan
    case boost
}

/// Resultado de analizar un texto enviado desde la caja.
public enum ResultadoAnalisis: Equatable {
    /// Texto normal, sin comandos ni skills: va al modelo tal cual.
    case mensajeNormal(texto: String)
    /// La linea entera es un comando local; no se envia nada al modelo.
    case comando(ComandoIntegrado)
    /// El PRIMER token es un comando conocido y habia texto detras (D1=A):
    /// el comando se ejecuta y el resto se descarta. `descartado` es ese texto,
    /// para que la app avise en el hilo que no se envio.
    case comandoConTexto(comando: ComandoIntegrado, descartado: String)
    /// Skills resueltas y el mensaje limpio que queda tras quitarlas.
    case conSkills(skills: [SkillResuelta], mensaje: String)
    /// Tokens con "/" que no resolvieron a ninguna skill (sin la "/").
    case tokensDesconocidos([String])
    /// Habia skills pero no quedo mensaje: nunca se envia un turno vacio.
    case skillSinMensaje(skill: SkillResuelta)
}

/// La gramatica unica del parser de "/" (SPEC §4.5 / contrato §8).
///
/// Decision firmada D1=A: manda el PRIMER token. Si es un comando integrado
/// conocido se ejecuta, aunque lleve texto detras ("/compact ahora" compacta);
/// el resto se descarta y el llamador avisa en el hilo, nunca en silencio. Si
/// el primer token no es comando ni skill conocida, el texto completo se manda
/// como mensaje normal: un "/" delante no puede tragarse lo que se escribio.
public enum AnalizadorComandos {
    /// Slugs que el almacen de skills no puede usar (§4.6). El parser tampoco
    /// los resuelve como skill: un token reservado que no sea el primero cae en
    /// `.tokensDesconocidos` aunque un registro defectuoso lo ofrezca.
    public static let slugsReservados: Set<String> = [
        "compact", "costo", "modelos", "nuevo", "exportar", "plan", "boost"
    ]

    /// Texto del comando /boost, sin espacios de borde.
    public static let tokenBoost = "/boost"

    /// Instruccion efectiva de una tarea /boost, o nil si no lo es.
    ///
    /// A diferencia de /plan, /boost lleva el encargo DETRAS en la misma linea
    /// ("/boost analiza esto"), asi que no puede esperar a que la linea entera
    /// sea el comando. Se exige que el primer token sea exactamente /boost para
    /// que "/boosters" o un texto que mencione /boost a mitad no disparen la
    /// tuberia por accidente. Devuelve "" cuando solo viene el comando: el
    /// llamador decide si eso es un error de instruccion vacia.
    public static func instruccionDeBoost(_ texto: String) -> String? {
        let recortado = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recortado.isEmpty else { return nil }

        let tokens = recortado.split(whereSeparator: { $0.isWhitespace })
        guard let primero = tokens.first,
              primero.lowercased() == tokenBoost
        else {
            return nil
        }

        // Se corta por longitud y no por el token normalizado: el resto debe
        // conservar tildes, saltos de linea y mayusculas del encargo original.
        let resto = String(recortado.dropFirst(primero.count))
        return resto.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

        // D1=A: el PRIMER token manda. Si es un comando integrado conocido se
        // ejecuta aunque haya texto detras; el resto se descarta y el llamador
        // avisa en el hilo. Un primer token que no es comando ni skill conocida
        // se manda entero como mensaje normal en vez de tragarse el texto.
        if let primero = tokens.first {
            if let comando = comandoDeToken(primero) {
                guard tokens.count > 1 else { return .comando(comando) }
                // Se corta por longitud del token crudo, no por el normalizado:
                // el aviso debe ensenar el texto tal como se escribio.
                let resto = String(recortado.dropFirst(primero.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .comandoConTexto(comando: comando, descartado: resto)
            }

            // Sin comando de primer token: solo se sigue con la gramatica de
            // skills si el primero resuelve a una skill. Si no, el "/" delante
            // no puede bloquear el envio.
            let crudoPrimero = primero.hasPrefix("/")
                ? String(primero.dropFirst())
                : primero
            let slugPrimero = normalizarSlug(crudoPrimero)
            let primerTokenEsSkill = !slugPrimero.isEmpty
                && !slugsReservados.contains(slugPrimero)
                && resolvedor.skill(porSlug: slugPrimero) != nil
            if !primerTokenEsSkill {
                return .mensajeNormal(texto: recortado)
            }
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
