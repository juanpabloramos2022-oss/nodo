import SwiftUI

import NodoCore

/// Configuracion del servidor remoto de herramientas.
///
/// No hace falta para conversar: si no hay servidor, la app funciona igual y
/// solo se pierden las herramientas que ese servidor ofrezca.
struct ServerView: View {
    @EnvironmentObject private var estado: EstadoApp

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var activo: Bool = false
    @State private var probando = false
    @State private var resultado: (exito: Bool, mensaje: String)?

    var body: some View {
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

                Button {
                    guardar()
                } label: {
                    Label("Guardar", systemImage: "checkmark")
                }
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
        .navigationTitle("Servidor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: cargar)
    }

    private func cargar() {
        url = estado.config.servidor.url
        activo = estado.config.servidor.activo
        token = estado.tokenServidor ?? ""
    }

    private func guardar() {
        var servidor = estado.config.servidor
        servidor.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        servidor.activo = activo
        estado.config.servidor = servidor
        estado.guardarTokenServidor(token)
    }

    private func probar() async {
        probando = true
        resultado = await estado.probarServidor()
        probando = false
    }
}
