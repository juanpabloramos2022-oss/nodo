import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import NodoCore

/// Pestana Conexiones: proveedores agrupados, MCP y Respaldo (§3.6/§4.8).
///
/// Solo fontaneria: aqui no vive ningun control de Memoria ni de Tope (esos
/// estan en Mi Contexto). La agrupacion por URL base es puramente visual: por
/// dentro sigue habiendo un registro por modelo (`ProviderConfig`).
struct ConexionesView: View {
    @EnvironmentObject private var estado: EstadoApp

    /// Aviso unico para cualquier archivo que no sea un respaldo de Nodo.
    private static let avisoRespaldoInvalido =
        "El archivo no es un respaldo válido de Nodo. No se cambió nada."

    @State private var aviso: String?
    @State private var confirmacion: String?
    @State private var proveedorEnEdicion: ProviderConfig?
    /// Borrador creado con "+ Anadir modelo/combo" al que se copio la clave.
    /// Si el Editor se cancela, el registro no entra en la configuracion y su
    /// credencial se retira para no dejar una clave huerfana en el llavero.
    @State private var borradorDuplicado: ProviderConfig?
    @State private var mostrandoImportador = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    seccionProveedores
                    tarjetaMCP
                    seccionRespaldo
                }
                .padding(.horizontal, Tema.margen)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Tema.fondo.ignoresSafeArea())
            .navigationTitle("Conexiones")
            // Esta pestana es su propia jerarquia de navegacion: la barra
            // Listo se declara aqui una sola vez (contrato §4).
            .conBarraTecladoListo()
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $proveedorEnEdicion, onDismiss: limpiarBorrador) { proveedor in
                EditorProveedorView(proveedor: proveedor)
            }
            .fileImporter(
                isPresented: $mostrandoImportador,
                allowedContentTypes: [.json]
            ) { resultado in
                importar(resultado)
            }
            .alert(
                "Nodo",
                isPresented: Binding(
                    get: { aviso != nil },
                    set: { if !$0 { aviso = nil } }
                )
            ) {
                Button("Vale") { aviso = nil }
            } message: {
                Text(aviso ?? "")
            }
        }
    }

    // MARK: - Mis Proveedores de IA

    private var grupos: [GrupoProveedores] {
        AgrupacionConexiones.agrupar(estado.config.proveedores)
    }

    private var seccionProveedores: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mis Proveedores de IA")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            if grupos.isEmpty {
                Text("Todavía no tienes proveedores. Añade uno para empezar.")
                    .font(.footnote)
                    .foregroundStyle(Tema.textoSuave)
                    .padding(.vertical, 6)
            } else {
                ForEach(grupos) { grupo in
                    tarjetaProveedor(grupo)
                }
            }

            Button {
                bajarTeclado()
                borradorDuplicado = nil
                proveedorEnEdicion = estado.proveedorNuevo()
            } label: {
                Label("Añadir proveedor", systemImage: "plus.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Tema.acento)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Tema.superficie)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                            .stroke(Tema.borde, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("anadir-proveedor")
        }
    }

    private func tarjetaProveedor(_ grupo: GrupoProveedores) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(grupo.nombre)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityIdentifier("proveedor-grupo")
                    Text(grupo.dominio)
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(
                    grupo.proveedores.count == 1
                        ? "1 modelo"
                        : "\(grupo.proveedores.count) modelos"
                )
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
            }
            .padding(.bottom, 10)

            ForEach(grupo.proveedores) { proveedor in
                filaProveedor(proveedor)
                if proveedor.id != grupo.proveedores.last?.id {
                    Divider().overlay(Tema.borde)
                }
            }

            Divider().overlay(Tema.borde)

            Button {
                anadirModelo(a: grupo)
            } label: {
                Label(
                    "Añadir modelo/combo a este proveedor",
                    systemImage: "plus.circle"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tema.acento)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("anadir-modelo-combo")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                .stroke(Tema.borde, lineWidth: 1)
        )
    }

    private func filaProveedor(_ proveedor: ProviderConfig) -> some View {
        let modelo = AgrupacionConexiones.nombreModelo(proveedor)
        let precios = AgrupacionConexiones.textoPrecios(proveedor)
        let activo = estado.config.proveedorActivo == proveedor.id

        return Button {
            bajarTeclado()
            borradorDuplicado = nil
            proveedorEnEdicion = proveedor
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(modelo)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let precios {
                        Text(precios)
                            .font(.caption2)
                            .foregroundStyle(Tema.textoSuave)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 6)

                if activo {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tema.acento)
                        .accessibilityLabel("Modelo activo")
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("proveedor-fila")
        .accessibilityLabel("Editar \(modelo)")
    }

    /// Duplica nombre, URL y clave del proveedor y abre el Editor del nuevo
    /// registro con el modelo vacio (§3.6).
    private func anadirModelo(a grupo: GrupoProveedores) {
        guard let origen = grupo.proveedores.first else { return }
        bajarTeclado()
        let nuevo = estado.proveedorDuplicado(desde: origen)
        borradorDuplicado = nuevo
        proveedorEnEdicion = nuevo
    }

    /// Un borrador que no llego a guardarse no deja su clave en el llavero.
    private func limpiarBorrador() {
        guard let borrador = borradorDuplicado else { return }
        borradorDuplicado = nil
        guard !estado.config.proveedores.contains(where: { $0.id == borrador.id }) else {
            return
        }
        estado.descartarClave(para: borrador)
    }

    // MARK: - Tarjeta MCP

    private var servidorConfigurado: Bool {
        !estado.config.servidor.url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var tarjetaMCP: some View {
        NavigationLink {
            ServerView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(Tema.acento)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Servidor MCP")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(servidorConfigurado ? "Listo" : "Sin configurar")
                        .font(.caption)
                        .foregroundStyle(
                            servidorConfigurado ? Tema.acento : Tema.textoSuave
                        )
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.superficie)
            .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                    .stroke(Tema.borde, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tarjeta-mcp")
        .accessibilityLabel(
            "Servidor MCP, \(servidorConfigurado ? "Listo" : "Sin configurar")"
        )
    }

    // MARK: - Respaldo

    private var seccionRespaldo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Respaldo")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text("Guarda tu configuración completa en un archivo para recuperarla si tienes que reinstalar la app.")
                .font(.footnote)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)

            botonExportar
            botonImportar

            if let confirmacion {
                Label(confirmacion, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("respaldo-confirmacion")
            }

            Text("El respaldo NO incluye la clave de API. Tras importar, pégala una vez en la Tarjeta de Bienvenida.")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.superficie)
        .clipShape(RoundedRectangle(cornerRadius: Tema.radio, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tema.radio, style: .continuous)
                .stroke(Tema.borde, lineWidth: 1)
        )
    }

    /// JSON construido con la configuracion viva y la tabla de ventanas que
    /// comparte con la Hoja Estado del chat (`nodo.ventanas.v1`).
    private var datosDeRespaldo: Data? {
        let respaldo = RespaldoConfiguracion.hacerRespaldo(
            config: estado.config,
            ventanas: estado.ventanasPorModelo
        )
        return try? respaldo.json()
    }

    @ViewBuilder
    private var botonExportar: some View {
        if let datos = datosDeRespaldo {
            ShareLink(
                item: ArchivoRespaldo(datos: datos),
                preview: SharePreview("Respaldo de Nodo")
            ) {
                Label("Exportar mi configuración", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tema.acento)
            .accessibilityIdentifier("exportar-respaldo")
        } else {
            Button {
                aviso = "No se pudo preparar el respaldo."
            } label: {
                Label("Exportar mi configuración", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tema.textoSuave)
            .accessibilityIdentifier("exportar-respaldo")
        }
    }

    private var botonImportar: some View {
        Button {
            bajarTeclado()
            confirmacion = nil
            mostrandoImportador = true
        } label: {
            Label("Importar configuración", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tema.acento)
        .accessibilityIdentifier("importar-respaldo")
    }

    /// Lee un respaldo y lo aplica. Un archivo invalido no toca nada.
    private func importar(_ resultado: Result<URL, Error>) {
        switch resultado {
        case .failure(let error):
            confirmacion = nil
            // Cancelar el selector no es un error que haya que ensenar.
            if (error as NSError).code == NSUserCancelledError { return }
            aviso = "No se pudo abrir el archivo."

        case .success(let url):
            let acceso = url.startAccessingSecurityScopedResource()
            defer {
                if acceso { url.stopAccessingSecurityScopedResource() }
            }

            guard let datos = try? Data(contentsOf: url) else {
                confirmacion = nil
                aviso = "No se pudo leer el archivo."
                return
            }

            guard let respaldo = try? RespaldoConfiguracion.desde(json: datos) else {
                confirmacion = nil
                aviso = Self.avisoRespaldoInvalido
                return
            }

            // Dos registros con el mismo id romperian las listas de SwiftUI.
            // Un respaldo asi no es valido y se rechaza antes de tocar nada.
            let idsProveedores = Set(respaldo.proveedores.map(\.id))
            let idsSkills = Set(respaldo.skills.map(\.id))
            guard idsProveedores.count == respaldo.proveedores.count,
                  idsSkills.count == respaldo.skills.count
            else {
                confirmacion = nil
                aviso = Self.avisoRespaldoInvalido
                return
            }

            estado.importarRespaldo(respaldo)
            aviso = nil
            confirmacion = "Configuración importada"
        }
    }
}

// MARK: - Agrupacion visual por URL base

/// Un grupo visual de registros que comparten dominio/URL base.
private struct GrupoProveedores: Identifiable {
    let id: String
    let dominio: String
    let nombre: String
    let proveedores: [ProviderConfig]
}

/// Reglas de presentacion de la agrupacion de Conexiones.
///
/// No tocan `ProviderConfig`: solo deciden como se reparten los registros que
/// ya existen y como se pinta cada nombre y cada precio (§2.5/§3.6).
private enum AgrupacionConexiones {
    /// Agrupa por host y conserva el orden de aparicion de la configuracion.
    static func agrupar(_ proveedores: [ProviderConfig]) -> [GrupoProveedores] {
        var orden: [String] = []
        var porClave: [String: [ProviderConfig]] = [:]

        for proveedor in proveedores {
            let clave = claveDeGrupo(proveedor)
            if porClave[clave] == nil {
                orden.append(clave)
            }
            porClave[clave, default: []].append(proveedor)
        }

        return orden.compactMap { clave in
            guard let lista = porClave[clave], let primero = lista.first else {
                return nil
            }
            return GrupoProveedores(
                id: clave,
                dominio: dominioVisible(primero.baseURL),
                nombre: nombreDeGrupo(lista),
                proveedores: lista
            )
        }
    }

    /// El host es el dominio real; una URL sin host se agrupa por su texto.
    static func claveDeGrupo(_ proveedor: ProviderConfig) -> String {
        let limpio = proveedor.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: limpio),
           let host = url.host,
           !host.isEmpty {
            return "host:\(host.lowercased())"
        }

        if limpio.isEmpty {
            return "sin-url:\(proveedor.id.uuidString)"
        }
        return "url:\(limpio.lowercased())"
    }

    static func dominioVisible(_ baseURL: String) -> String {
        let limpio = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: limpio),
           let host = url.host,
           !host.isEmpty {
            return host.lowercased()
        }
        return limpio.isEmpty ? "Sin dirección" : limpio
    }

    /// Nombre limpio del proveedor: manda el primer nombre propio del grupo y,
    /// si todos son genericos, se deriva del dominio con `NombresLimpios`.
    static func nombreDeGrupo(_ proveedores: [ProviderConfig]) -> String {
        let preferido = proveedores.first { proveedor in
            let nombre = proveedor.nombre.trimmingCharacters(in: .whitespacesAndNewlines)
            return !nombre.isEmpty && nombre.lowercased() != "compatible"
        } ?? proveedores.first

        guard let preferido else { return "Proveedor" }
        return NombresLimpios.proveedor(
            nombre: preferido.nombre,
            baseURL: preferido.baseURL
        )
    }

    static func nombreModelo(_ proveedor: ProviderConfig) -> String {
        let limpio = NombresLimpios.modelo(proveedor.modelo)
        return limpio.isEmpty ? "Sin modelo" : limpio
    }

    /// "Entrada $0.03 · Salida $0.12 por millon"; nil si no hay ningun precio.
    static func textoPrecios(_ proveedor: ProviderConfig) -> String? {
        var partes: [String] = []

        if let entrada = proveedor.precioEntradaPorMillon,
           entrada.isFinite,
           entrada >= 0 {
            partes.append("Entrada \(textoImporte(entrada))")
        }

        if let salida = proveedor.precioSalidaPorMillon,
           salida.isFinite,
           salida >= 0 {
            partes.append("Salida \(textoImporte(salida))")
        }

        guard !partes.isEmpty else { return nil }
        return partes.joined(separator: " · ") + " por millón"
    }

    /// Importe corto: entre dos y cuatro decimales, sin separador de miles.
    static func textoImporte(_ valor: Double) -> String {
        let texto = formateadorPrecio.string(from: NSNumber(value: valor))
            ?? String(format: "%.2f", valor)
        return "$" + texto
    }

    private static let formateadorPrecio: NumberFormatter = {
        let formateador = NumberFormatter()
        formateador.locale = Locale(identifier: "en_US_POSIX")
        formateador.numberStyle = .decimal
        formateador.minimumFractionDigits = 2
        formateador.maximumFractionDigits = 4
        formateador.usesGroupingSeparator = false
        return formateador
    }()
}

// MARK: - Archivo exportable

/// Archivo JSON que `ShareLink` ofrece con el nombre exacto del respaldo.
private struct ArchivoRespaldo: Transferable {
    let datos: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { archivo in
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent("nodo-respaldo.json")
            try archivo.datos.write(to: destino, options: .atomic)
            return SentTransferredFile(destino)
        }
    }
}
