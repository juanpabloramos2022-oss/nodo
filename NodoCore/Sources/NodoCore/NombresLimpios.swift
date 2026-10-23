import Foundation

/// Reglas puras para ensenar nombres de modelos y proveedores sin fontaneria.
///
/// Viven en NodoCore, y no en la vista, para poder probarlas con `swift test`.
/// La configuracion no cambia: siguen siendo un modelo por registro; lo unico
/// que se limpia es lo que se pinta.
public enum NombresLimpios {
    /// Nombre limpio de un modelo.
    ///
    /// El apodo manda siempre que tenga algo. Si no lo hay, se recorta el prefijo
    /// anterior a la ultima barra (`vendedor/modelo` -> `modelo`), porque los
    /// combos se identifican como `vendedor/modelo` y el vendedor es ruido para
    /// quien solo quiere saber con que esta hablando. Si al recortar no queda
    /// nada, se devuelve el crudo recortado para no dejar la pildora vacia.
    public static func modelo(_ crudo: String, apodo: String? = nil) -> String {
        if let apodo {
            let limpio = apodo.trimmingCharacters(in: .whitespacesAndNewlines)
            if !limpio.isEmpty { return limpio }
        }

        let recortado = crudo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let barra = recortado.lastIndex(of: "/") else { return recortado }

        let sinPrefijo = String(recortado[recortado.index(after: barra)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sinPrefijo.isEmpty ? recortado : sinPrefijo
    }

    /// Nombre limpio de un proveedor.
    ///
    /// "Compatible" es la etiqueta de la plantilla, no el nombre de nadie: si el
    /// nombre guardado es generico o esta vacio, se deriva del dominio para que
    /// en pantalla se lea el proveedor real (`api.inferhub.dev` -> `Inferhub`).
    /// Un nombre propio se respeta tal cual; solo se recorta el espacio sobrante.
    public static func proveedor(nombre: String, baseURL: String) -> String {
        let recortado = nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        let esGenerico = recortado.isEmpty || recortado.lowercased() == "compatible"
        if !esGenerico { return recortado }

        if let derivado = derivarDelDominio(baseURL) { return derivado }

        // Sin dominio utilizable queda el respaldo: el nombre original si lo
        // habia, o "Proveedor" para no ensenar una etiqueta vacia.
        return recortado.isEmpty ? "Proveedor" : recortado
    }

    /// Deriva el nombre del host de la URL configurada.
    ///
    /// Se quita el prefijo "api." (es convencion de los endpoints, no parte del
    /// nombre), se toma la primera etiqueta del dominio y se capitaliza.
    /// Cualquier URL que no tenga host no permite derivar nada.
    private static func derivarDelDominio(_ baseURL: String) -> String? {
        let limpio = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpio.isEmpty,
              let url = URL(string: limpio),
              var host = url.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        if host.hasPrefix("api.") {
            host.removeFirst("api.".count)
        }
        guard let etiqueta = host.split(separator: ".").first, !etiqueta.isEmpty else {
            return nil
        }

        return String(etiqueta.prefix(1)).uppercased() + String(etiqueta.dropFirst())
    }
}
