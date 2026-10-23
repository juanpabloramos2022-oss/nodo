# Capturas del simulador (verificación visual, SPEC §6/H7)

Las capturas se generan en CI con datos de **PRUEBA** deterministas. No usan
claves reales ni datos de una persona. El job `capturas` de
`.github/workflows/ios.yml` publica el artefacto `capturas-<fase>`; el valor de
`<fase>` sale del input `fase` de `workflow_dispatch` y por defecto es `actual`.

## Cómo se ejecutan

```sh
xcodegen generate
xcodebuild test \
  -project Nodo.xcodeproj \
  -scheme Capturas \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:NodoCapturas \
  -resultBundlePath capturas.xcresult
python3 herramientas/extraer-capturas.py capturas.xcresult capturas
```

El esquema `Capturas` solo corre el target `NodoCapturas`. El esquema `Nodo`
sigue siendo el de compilación y no cambia.

La extracción intenta `xcrun xcresulttool export attachments` (Xcode 16+) y,
si el comando no está disponible, busca los PNG dentro del bundle del
resultado. En ambos casos los deja en `capturas/` con el nombre descriptivo del
adjunto.

## Convención de nombres

`f<fase>-<pantalla>-<estado>.png`, por ejemplo
`f1-editor-teclado-numerico.png`. El prefijo `f<fase>` es lo que permite mapear
cada PNG a las "Capturas exigidas" de SPEC §5. El nombre viaja en
`XCTAttachment.name`; el script de extracción lo conserva al copiar el PNG.

## Capturas implementadas

| Archivo | Fase | Qué exige SPEC §5 | Estado de prueba |
|---|---|---|---|
| `f1-editor-teclado-numerico` | 1 | Editor de proveedor con el teclado numérico abierto y la barra **Listo** visible | `editor-proveedor` |
| `f1-ajustes-tope-teclado-numerico` | 1 | Campo de tope con teclado y barra **Listo** visible | `ajustes-tope` |
| `f2-cabecera-teclado-abierto` | 2 | Cabecera despejada completa (← Chats, píldora y •••) con el teclado abierto | `chat` |
| `f2-tira-fina` | 2 | Tira fina con el conmutador Chat \| Tarea y el botón 🧠 sobre la caja | `chat` |
| `f2-menu-pildora` | 2 | Menú de la píldora abierto, con los modelos y el ✓ en el activo | `chat` |
| `f2-divisor-cambio-modelo` | 2 | Divisor ── Ahora responde X ── tras elegir otro modelo | `chat` |
| `f2-estado-del-chat` | 2 | Hoja Estado del chat con Ocupación de la ventana y Consumo acumulado del chat | `chat` |
| `f2-memoria-rapida` | 2 | Hoja Memoria rápida con Cancelar/Guardar | `chat` |
| `f2-tarea-aprobacion` | 2 | Hoja de aprobación antes de ejecutar la herramienta con consecuencias | `tarea` |
| `f2-tarea-paso-completado` | 2 | Turno de tarea terminado: respuesta final y paso plegable | `tarea` |
| `f2-tarea-ejecutando` | 2 | Intento del estado intermedio "Ejecutando…" justo tras aprobar | `tarea` |

## Estados de prueba disponibles

El gancho vive en `Nodo/Support/EstadosDePrueba.swift`. Solo se activa con el
argumento de lanzamiento `-CapturasPrueba`; sin ese argumento la app arranca
exactamente como siempre.

| Estado | Datos que siembra |
|---|---|
| `editor-proveedor` | Proveedor de ejemplo sin clave, precios 0.10/0.20 y conversación de ejemplo |
| `ajustes-tope` | Igual, con tope de aviso 1.00 |
| `conversacion-ejemplo` | Conversación con mensajes genéricos |
| `historial-ejemplo` | Varias conversaciones de ejemplo |
| `chat` | Los 4 combos del preset, Memoria con texto y conversación abierta con dos turnos y consumo medido (1200/300 tokens) |
| `tarea` | Conversación vacía en modo Tarea, con la herramienta de prueba que pide aprobación |

Los estados se siembran en memoria: el modo capturas no escribe en
`UserDefaults`, en el almacén de conversaciones ni en el llavero del simulador.

## Añadir una captura de otra fase

1. Añade o reutiliza un estado en `Nodo/Support/EstadosDePrueba.swift`.
2. Añade un método `testF<fase>...` en `NodoCapturas/CapturasTests.swift` que
   lance la app con `-CapturasPrueba -CapturasEstado <estado>`, navegue por la
   UI real y llame a `adjuntarCaptura("f<fase>-...")`.
3. Actualiza la tabla de arriba.
