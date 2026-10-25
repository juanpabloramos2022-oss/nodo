import SwiftUI

import NodoCore

@main
struct NodoApp: App {
    // El gancho de capturas solo devuelve un estado si la app se lanzo con
    // `-CapturasPrueba`; en cualquier otro arranque vale nil y todo sigue igual.
    @StateObject private var estado = EstadoApp(
        estadoDePrueba: EstadosDePrueba.estadoSolicitado()
    )

    var body: some Scene {
        WindowGroup {
            RaizView()
                .environmentObject(estado)
                .preferredColorScheme(.dark)
                .tint(Tema.acento)
        }
    }
}

/// Raiz definitiva de la app: cuatro pestanas, cada una con su propia pila.
///
/// Chats conserva la pila de la Fase 2 (lista -> conversacion). Tareas es el
/// espacio propio del modo Tarea: no comparte lista con los chats. Mi Contexto
/// reune Memoria, Tope y Skills. Conexiones es solo fontaneria: proveedores
/// agrupados por URL base, servidor MCP y Respaldo (§3.6/§4.8).
struct RaizView: View {
    @EnvironmentObject private var estado: EstadoApp
    @State private var seleccion: PestanaRaiz = .chats

    var body: some View {
        TabView(selection: $seleccion) {
            ChatsRaizView(seleccion: $seleccion)
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(PestanaRaiz.chats)

            TareasRaizView()
                .tabItem { Label("Tareas", systemImage: "checklist") }
                .tag(PestanaRaiz.tareas)

            MiContextoView()
                .tabItem { Label("Mi Contexto", systemImage: "brain") }
                .tag(PestanaRaiz.contexto)

            ConexionesView()
                .tabItem { Label("Conexiones", systemImage: "network") }
                .tag(PestanaRaiz.conexiones)
        }
        // La aprobacion vive en la raiz como RED DE SEGURIDAD: si el dueno
        // cambia de pestana con una tarea ejecutando, la hoja sigue apareciendo
        // y el bucle no se queda esperando una decision invisible.
        //
        // B3-B: cuando el hilo de esa tarea esta en pantalla, la hoja no se
        // presenta —la decision se toma EN CONTEXTO, junto a su fila— y el
        // binding devuelve nil para no tapar la fila que la pide.
        .sheet(
            item: Binding(
                get: { estado.solicitudAprobacionModal },
                set: { _ in }
            )
        ) { solicitud in
            HojaAprobacionView(solicitud: solicitud)
        }
    }
}

/// Pestanas de la raiz definitiva (SPEC §3).
///
/// TASK.1 anade Tareas como espacio propio; las otras tres siguen siendo las
/// del mapa de pantallas del Documento Maestro.
enum PestanaRaiz: Hashable {
    case chats
    case tareas
    case contexto
    case conexiones
}
