import Foundation

/// Siembra de las skills de fabrica sobre el almacen normal de skills (PACK.1).
///
/// El pack NO es un bloque aparte ni un prompt escondido: cada skill nace como
/// un `SkillLocal` comun, con su marca de origen, y se edita, invoca y borra
/// como cualquier otra del dueno. Las reglas puras viven aqui (sin reloj, red
/// ni disco) y la app solo persiste el resultado.
public enum SiembraSkills {
    /// Corre la siembra cuando la build trae una version nueva del pack.
    ///
    /// POR QUE mira el marcador: la siembra tiene que ocurrir tras instalar o
    /// actualizar, no en cada apertura. Si `packSkillsVersion` ya esta al dia,
    /// no se toca NADA del almacen (ni siquiera se recorre la lista).
    ///
    /// - Returns: cuantas skills se crearon (0 si el marcador ya estaba al dia).
    @discardableResult
    public static func sembrarSiFaltaVersion(en config: inout AppConfig) -> Int {
        guard config.packSkillsVersion < PACK_VERSION else { return 0 }

        let creadas = sembrarAusentes(en: &config)
        // El marcador sube aunque no se haya creado ninguna: el dueno ya tenia
        // esos slugs (suyos, de fabrica intactos o de fabrica editados) y la
        // version quedo atendida. Asi la proxima apertura no vuelve a recorrer
        // ni a decidir sobre lo que ya decidio.
        config.packSkillsVersion = PACK_VERSION
        return creadas
    }

    /// [Restaurar skills de fabrica]: repone solo los slugs del pack ausentes.
    ///
    /// Es la unica via para que vuelva una skill de fabrica borrada, ademas de
    /// reinstalar la app sin respaldo. Respeta la misma regla que la siembra
    /// normal: lo que ya existe con ese slug no se toca ni se duplica. No mueve
    /// el marcador porque restaurar no es una version nueva del pack.
    ///
    /// - Returns: cuantas skills se repusieron.
    @discardableResult
    public static func restaurar(en config: inout AppConfig) -> Int {
        sembrarAusentes(en: &config)
    }

    /// Crea los registros del pack cuyo slug no exista ya.
    ///
    /// Regla dura de idempotencia por slug: se recorre el PACK, nunca la lista
    /// del dueno. Si el slug esta ocupado por una skill suya, por una de
    /// fabrica intacta o por una de fabrica que el edito, no se toca: el texto
    /// que manda es el que ya esta guardado. Sus skills propias jamas se
    /// recorren, se cuentan ni se reescriben como parte del pack.
    private static func sembrarAusentes(en config: inout AppConfig) -> Int {
        var creadas = 0

        for definicion in PackSkillsFabrica.skills {
            let yaExiste = config.skills.contains { $0.slug == definicion.slug }
            guard !yaExiste else { continue }

            config.skills.append(
                SkillLocal(
                    nombre: definicion.nombre,
                    slug: definicion.slug,
                    descripcion: definicion.descripcion,
                    instrucciones: definicion.instrucciones,
                    origen: .fabrica
                )
            )
            creadas += 1
        }

        return creadas
    }
}
