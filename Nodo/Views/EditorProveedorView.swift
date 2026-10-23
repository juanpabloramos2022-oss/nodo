import SwiftUI

import NodoCore

/// Edicion de un proveedor: nombre, protocolo, direccion, modelo, precios y clave.
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
                Button {
                    guardar()
                } label: {
                    Label("Guardar", systemImage: "checkmark")
                }

                if estado.config.proveedorActivo != proveedor.id {
                    Button {
                        estado.config.proveedorActivo = proveedor.id
                        guardar()
                    } label: {
                        Label("Usar este proveedor", systemImage: "arrow.right.circle")
                    }
                }

                Button(role: .destructive) {
                    estado.borrarProveedor(proveedor)
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
        .onAppear {
            if clave.isEmpty, let guardada = estado.clave(para: proveedor) {
                clave = guardada
            }
        }
    }

    private func guardar() {
        let entrada = leerPrecio(precioEntrada)
        guard entrada.valido else {
            errorLocal = "El precio de entrada no es un numero valido."
            return
        }

        let salida = leerPrecio(precioSalida)
        guard salida.valido else {
            errorLocal = "El precio de salida no es un numero valido."
            return
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
            return
        }

        errorLocal = nil
        estado.actualizarProveedor(actualizado)
        estado.guardarClave(clave, para: actualizado)
        dismiss()
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
