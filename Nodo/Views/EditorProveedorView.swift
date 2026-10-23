import SwiftUI

import NodoCore

/// Edicion de un proveedor: nombre, protocolo, direccion, modelo, precios y clave.
///
/// Es una hoja modal: Cancelar descarta el borrador y Guardar solo se activa
/// cuando algo ha cambiado (leyes n. 2 y n. 3).
struct EditorProveedorView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    let proveedor: ProviderConfig

    @State private var nombre: String
    @State private var protocolo: ProtocoloProveedor
    @State private var baseURL: String
    @State private var modelo: String
    @State private var clave: String
    @State private var precioEntrada: String
    @State private var precioSalida: String
    @State private var revelarClave = false
    @State private var errorLocal: String?
    /// Texto de la clave con el que se abrio la hoja, ya leido del llavero.
    @State private var claveInicial = ""
    @State private var claveInicialCargada = false

    init(proveedor: ProviderConfig) {
        self.proveedor = proveedor
        _nombre = State(initialValue: proveedor.nombre)
        _protocolo = State(initialValue: proveedor.protocolo)
        _baseURL = State(initialValue: proveedor.baseURL)
        _modelo = State(initialValue: proveedor.modelo)
        _clave = State(initialValue: "")
        _precioEntrada = State(initialValue: Self.textoPrecio(proveedor.precioEntradaPorMillon))
        _precioSalida = State(initialValue: Self.textoPrecio(proveedor.precioSalidaPorMillon))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identidad") {
                    TextField("Nombre", text: $nombre)
                        .foregroundStyle(.white)

                    Picker("Protocolo", selection: $protocolo) {
                        ForEach(ProtocoloProveedor.allCases) { opcion in
                            Text(opcion.etiqueta).tag(opcion)
                        }
                    }
                }

                Section {
                    TextField("https://api.ejemplo.com/v1", text: $baseURL)
                        .foregroundStyle(.white)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Modelo", text: $modelo)
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Conexion")
                } footer: {
                    Text(protocolo == .anthropic
                         ? "La direccion base, sin /v1/messages. Se anade solo."
                         : "La direccion base, sin /chat/completions. Se anade solo.")
                }

                Section {
                    HStack {
                        Text("Entrada")
                            .foregroundStyle(.white)
                        Spacer()
                        TextField("Vacio", text: $precioEntrada)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 120)
                    }

                    HStack {
                        Text("Salida")
                            .foregroundStyle(.white)
                        Spacer()
                        TextField("Vacio", text: $precioSalida)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white)
                            .frame(maxWidth: 120)
                    }
                } header: {
                    Text("Precios")
                } footer: {
                    Text("USD por millon de tokens. Vacio = sin costo estimado.")
                }

                Section {
                    HStack {
                        if revelarClave {
                            TextField("Clave de API", text: $clave)
                                .foregroundStyle(.white)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Clave de API", text: $clave)
                                .foregroundStyle(.white)
                        }

                        Button {
                            revelarClave.toggle()
                        } label: {
                            Image(systemName: revelarClave ? "eye.slash" : "eye")
                                .foregroundStyle(Tema.textoSuave)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Credencial")
                } footer: {
                    Text("Se guarda en el llavero del telefono, no en la configuracion ni en ningun registro.")
                }

                Section {
                    if estado.config.proveedorActivo != proveedor.id {
                        Button {
                            // Solo se marca como activo si el guardado valido:
                            // un borrador invalido no debe dejar la app sin
                            // proveedor seleccionado.
                            if guardar() {
                                estado.config.proveedorActivo = proveedor.id
                            }
                        } label: {
                            Label("Usar este proveedor", systemImage: "arrow.right.circle")
                        }
                    }

                    Button(role: .destructive) {
                        estado.borrarProveedor(proveedor)
                        bajarTeclado()
                        dismiss()
                    } label: {
                        Label("Borrar proveedor", systemImage: "trash")
                    }
                }

                if let errorLocal {
                    Section {
                        Text(errorLocal)
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle(nombre.isEmpty ? "Proveedor" : nombre)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") {
                        cancelar()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") {
                        guardar()
                    }
                    .fontWeight(.semibold)
                    // Ley n. 3: sin cambios no hay nada que guardar.
                    .disabled(!hayCambios)
                }
            }
            // Esta hoja es su propia jerarquia de navegacion: la barra Listo
            // se declara aqui una sola vez y no se hereda de Ajustes.
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .onAppear(perform: cargarClaveInicial)
        }
        // Con cambios sin guardar, arrastrar hacia abajo solo esconde el
        // teclado; la hoja nunca se cierra perdiendo lo escrito.
        .interactiveDismissDisabled(hayCambios)
    }

    /// Hay cambios cuando cualquier campo del borrador difiere del valor con
    /// el que se abrio la hoja. La comparacion es logica de presentacion.
    private var hayCambios: Bool {
        nombre != proveedor.nombre
            || protocolo != proveedor.protocolo
            || baseURL != proveedor.baseURL
            || modelo != proveedor.modelo
            || precioEntrada != Self.textoPrecio(proveedor.precioEntradaPorMillon)
            || precioSalida != Self.textoPrecio(proveedor.precioSalidaPorMillon)
            || clave != claveInicial
    }

    /// Lee la clave guardada una sola vez y la fija como valor inicial.
    ///
    /// Asi la clave precargada no cuenta como cambio: Guardar sigue
    /// deshabilitado hasta que el usuario modifique algo de verdad.
    private func cargarClaveInicial() {
        guard !claveInicialCargada else { return }

        var inicial = clave
        if inicial.isEmpty, let guardada = estado.clave(para: proveedor) {
            inicial = guardada
        }
        clave = inicial
        claveInicial = inicial
        claveInicialCargada = true
    }

    /// Cancelar descarta el borrador, baja el teclado y cierra la hoja.
    private func cancelar() {
        bajarTeclado()
        dismiss()
    }

    @discardableResult
    private func guardar() -> Bool {
        let entrada = leerPrecio(precioEntrada)
        guard entrada.valido else {
            errorLocal = "El precio de entrada no es un numero valido."
            return false
        }

        let salida = leerPrecio(precioSalida)
        guard salida.valido else {
            errorLocal = "El precio de salida no es un numero valido."
            return false
        }

        var actualizado = proveedor
        actualizado.nombre = nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        actualizado.protocolo = protocolo
        actualizado.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        actualizado.modelo = modelo.trimmingCharacters(in: .whitespacesAndNewlines)
        actualizado.precioEntradaPorMillon = entrada.valor
        actualizado.precioSalidaPorMillon = salida.valor

        do {
            try actualizado.validar()
        } catch {
            errorLocal = error.localizedDescription
            return false
        }

        errorLocal = nil
        estado.actualizarProveedor(actualizado)
        estado.guardarClave(clave, para: actualizado)
        bajarTeclado()
        dismiss()
        return true
    }

    /// Texto inicial del campo: vacio cuando el precio no esta configurado.
    private static func textoPrecio(_ valor: Double?) -> String {
        guard let valor else { return "" }
        return String(valor)
    }

    /// Resultado de leer un campo de precio.
    private struct PrecioLeido {
        let valor: Double?
        let valido: Bool
    }

    /// Vacio es nil; un numero no negativo se guarda; lo demas no pisa nada.
    private func leerPrecio(_ texto: String) -> PrecioLeido {
        let limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.isEmpty { return PrecioLeido(valor: nil, valido: true) }

        // Se admite coma decimal, que es lo que suele escribir el teclado en
        // espanol, pero se guarda siempre como numero.
        let normalizado = limpio.replacingOccurrences(of: ",", with: ".")
        guard let valor = Double(normalizado), valor.isFinite, valor >= 0 else {
            return PrecioLeido(valor: nil, valido: false)
        }
        return PrecioLeido(valor: valor, valido: true)
    }
}
