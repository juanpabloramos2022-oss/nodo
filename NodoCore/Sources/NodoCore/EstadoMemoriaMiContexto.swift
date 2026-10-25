import Foundation

/// Grupo de entradas de Memoria de una misma categoria (B2.5).
///
/// La revisión de compactación no inventa una vista nueva de gestión: usa la
/// misma lista de Mi Contexto, agrupada por categoria, con el editor y el
/// borrado que ya existen por entrada.
public struct GrupoMemoria: Identifiable, Equatable {
    public let categoria: CategoriaMemoria
    public let entradas: [EntradaMemoria]

    public init(categoria: CategoriaMemoria, entradas: [EntradaMemoria]) {
        self.categoria = categoria
        self.entradas = entradas
    }

    public var id: String { categoria.rawValue }
    public var titulo: String { categoria.etiquetaVisible }
}

/// Estado visible de la Memoria en Mi Contexto (B2.5).
///
/// Vive en el nucleo y no en la vista para que el contador, la banda y la
/// agrupación se prueben con `swift test` sin simulador: la vista solo pinta
/// lo que este valor declara.
///
/// POR QUE `total` topa en 50: un respaldo heredado puede traer más de 50
/// entradas almacenadas. La inyección manda las primeras 50 y el contador no
/// puede decir «60 de 50»: muestra el tope alcanzado (50 de 50) sin borrar ni
/// ocultar ninguna entrada de la lista, que sigue completa y editable.
public struct EstadoMemoriaMiContexto: Equatable {
    /// Entradas almacenadas, en el orden vigente de la lista.
    public let entradas: [EntradaMemoria]

    public init(entradas: [EntradaMemoria]) {
        self.entradas = entradas
    }

    /// Entradas almacenadas de verdad (puede superar el tope).
    public var almacenadas: Int { entradas.count }

    /// N que anuncia el contador: las que caben en el tope.
    public var total: Int { min(entradas.count, Memoria.topeEntradas) }

    /// Contador siempre visible en Mi Contexto, por debajo y por encima del
    /// umbral: «Memoria en N de 50 entradas».
    public var contador: String {
        "Memoria en \(total) de \(Memoria.topeEntradas) entradas"
    }

    /// La banda de aviso aparece desde N=40 (inclusive) y solo desde ahí.
    public var muestraBanda: Bool {
        total >= Memoria.umbralAvisoEntradas
    }

    /// True cuando ya no cabe ninguna creación más.
    public var enTope: Bool {
        entradas.count >= Memoria.topeEntradas
    }

    /// Entradas agrupadas por categoria, en el orden fijo de las cuatro
    /// categorias tipadas y sin grupos vacios. El orden de las entradas dentro
    /// de cada grupo es el de la lista: agrupar para revisar no reordena el
    /// almacenamiento.
    public var grupos: [GrupoMemoria] {
        CategoriaMemoria.allCases.compactMap { categoria in
            let delGrupo = entradas.filter { $0.categoria == categoria }
            guard !delGrupo.isEmpty else { return nil }
            return GrupoMemoria(categoria: categoria, entradas: delGrupo)
        }
    }
}
