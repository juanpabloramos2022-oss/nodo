import SwiftUI

import NodoCore

/// Configuracion del servidor remoto de herramientas.
///
/// No hace falta para conversar: si no hay servidor, la app funciona igual y
/// solo se pierden las herramientas que ese servidor ofrezca.
///
/// Presentacion (SPEC §2.2, hallazgo Jules 1): es una HOJA MODAL, no una
/// pantalla empujada en la pila. Se abre desde la tarjeta MCP en Conexiones
/// con `.sheet`, con Cancelar arriba a la izquierda y Guardar arriba a la
/// derecha, y no se puede cerrar arrastrando mientras haya cambios sin
/// guardar (`.interactiveDismissDisabled(hayCambios)`).
struct ServerView: View {
    @EnvironmentObject private var estado: EstadoApp
    @Environment(\.dismiss) private var dismiss

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var activo: Bool = false
    @State private var probando = false
    @State private var resultado: (exito: Bool, mensaje: String)?

    /// Valores con los que se abrio la hoja: Cancelar los restaura, asi que
    /// ni siquiera un "Probar conexion" previo (que guarda para poder probar)
    /// deja cambios pegados si el dueno decide no guardar.
    @State private var urlOriginal: String = ""
    @State private var tokenOriginal: String = ""
    @State private var activoOriginal: Bool = false

    private var hayCambios: Bool {
        url != urlOriginal || token != tokenOriginal || activo != activoOriginal
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Usar servidor", isOn: $activo)

                    TextField("https://tu-servidor.example/mcp", text: $url)
                        .foregroundStyle(.white)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Direccion")
                } footer: {
                    Text("Debe empezar por https: el token viaja en una cabecera.")
                }

                Section {
                    SecureField("Token", text: $token)
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Credencial")
                } footer: {
                    Text("Se guarda en el llavero del telefono.")
                }

                Section {
                    Button {
                        guardar()
                        Task { await probar() }
                    } label: {
                        HStack {
                            if probando {
                                ProgressView().controlSize(.small)
                            }
                            Text(probando ? "Probando..." : "Probar conexion")
                        }
                    }
                    .disabled(probando)
                }

                if let resultado {
                    Section {
                        Text(resultado.mensaje)
                            .font(.footnote)
                            .foregroundStyle(resultado.exito ? Color.green : Color.orange)
                    }
                }

                Section {
                    Text("Con el servidor configurado, el modelo puede usar las herramientas que exponga: por ejemplo, dejar una tarea en una cola o leer un registro. Sin servidor, el chat funciona igual.")
                        .font(.footnote)
                        .foregroundStyle(Tema.textoSuave)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tema.fondo.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Servidor")
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
                        dismiss()
                    }
                }
            }
            .onAppear(perform: cargar)
        }
        .interactiveDismissDisabled(hayCambios)
    }

    private func cargar() {
        url = estado.config.servidor.url
        activo = estado.config.servidor.activo
        token = estado.tokenServidor ?? ""
        urlOriginal = url
        activoOriginal = activo
        tokenOriginal = token
    }

    private func guardar() {
        var servidor = estado.config.servidor
        servidor.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        servidor.activo = activo
        estado.config.servidor = servidor
        estado.guardarTokenServidor(token)
    }

    /// Cancelar descarta todo, incluso lo que un "Probar conexion" haya
    /// guardado para poder probar: restaura los valores originales.
    private func cancelar() {
        var servidor = estado.config.servidor
        servidor.url = urlOriginal
        servidor.activo = activoOriginal
        estado.config.servidor = servidor
        estado.guardarTokenServidor(tokenOriginal)
        dismiss()
    }

    private func probar() async {
        probando = true
        resultado = await estado.probarServidor()
        probando = false
    }
}
