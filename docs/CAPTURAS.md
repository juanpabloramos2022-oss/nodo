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

Los estados se siembran en memoria: el modo capturas no escribe en
`UserDefaults`, en el almacén de conversaciones ni en el llavero del simulador.

## Añadir una captura de otra fase

1. Añade o reutiliza un estado en `Nodo/Support/EstadosDePrueba.swift`.
2. Añade un método `testF<fase>...` en `NodoCapturas/CapturasTests.swift` que
   lance la app con `-CapturasPrueba -CapturasEstado <estado>`, navegue por la
   UI real y llame a `adjuntarCaptura("f<fase>-...")`.
3. Actualiza la tabla de arriba.
