# Nodo

Una app de iOS para hablar con modelos de inteligencia artificial usando **tus
propias claves de API**, desde el teléfono, sin depender de un computador
encendido.

Estado: **v0.0.1 — cadena de compilación**. Todavía no hace nada útil a
propósito: esta entrega solo demuestra que el código compila, se empaqueta y se
instala. Sirve para no construir sobre terreno sin probar.

---

## Qué va a ser y qué no

| | |
|---|---|
| ✅ Chat con streaming contra APIs compatibles con el formato de OpenAI y contra la API de Anthropic | |
| ✅ Tus claves en el Keychain del teléfono, nunca en el código ni en este repositorio | |
| ✅ Historial de conversaciones local | |
| ✅ Herramientas que el modelo puede pedir y ejecutar (traer una URL) | |
| ✅ Cliente MCP genérico: apuntar a un servidor propio, presente o futuro | |
| ❌ Un entorno de ejecución de agentes dentro del teléfono | |

Lo último es una limitación de iOS, no de la app: una aplicación vive en un
sandbox, sin shell, sin acceso al sistema de archivos fuera de su contenedor y
sin procesos en segundo plano. Los agentes que editan archivos o ejecutan
comandos necesitan una máquina donde hacerlo. Nodo se conecta a esa máquina por
MCP cuando existe; no la reemplaza.

---

## Requisitos

- iPhone con iOS 17 o superior.
- Una cuenta de GitHub (la compilación corre en GitHub Actions).
- Un certificado de firma propio para instalar el `.ipa` (ver *Instalar*).
- Opcional: Xcode 16 en un Mac, si prefieres compilar en local.

---

## Compilar

La compilación ocurre en la nube. No hace falta un Mac.

1. Sube un cambio a `main` (o lanza el workflow a mano desde la pestaña
   **Actions**).
2. El workflow [`.github/workflows/ios.yml`](.github/workflows/ios.yml) ejecuta
   las pruebas del núcleo, genera el proyecto Xcode con XcodeGen y compila.
3. Al terminar, descarga el artifact **Nodo-ipa** y descomprímelo. Dentro está
   `Nodo.ipa`, **sin firmar**.

En repositorios públicos el runner de macOS es gratuito e ilimitado, así que
compilar no cuesta nada.

### Compilar en local (opcional)

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Nodo.xcodeproj -scheme Nodo -sdk iphoneos \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/Nodo.app Payload/
zip -qr Nodo.ipa Payload
```

---

## Pruebas

El núcleo lógico vive en `NodoCore`, escrito solo con Foundation. Por eso se
puede compilar y probar en cualquier sistema con Swift instalado, sin simulador:

```bash
swift test
```

En Windows, el toolchain oficial se instala con:

```powershell
winget install --id Swift.Toolchain --accept-source-agreements --accept-package-agreements
```

Si Swift no está disponible, no pasa nada: GitHub Actions corre `swift test` en
cada cambio de todas formas.

---

## Instalar en el iPhone

El `.ipa` que produce la compilación está **sin firmar**. Para instalarlo hay que
firmarlo con un certificado propio:

1. Descarga `Nodo.ipa` del artifact.
2. Fírmalo con tu certificado de desarrollo y tu perfil de aprovisionamiento,
   con la herramienta de firma que uses (por ejemplo ESign, Sideloadly o
   AltStore).
3. Instálalo y, si el sistema lo pide, confía en el certificado en
   **Ajustes → General → VPN y gestión de dispositivos**.

Notas:

- El identificador de la app es `com.nodo.ios`. Se cambia en
  [`project.yml`](project.yml). Si tu perfil es comodín, cualquier
  identificador sirve.
- Si vuelves a firmar con otro certificado, las claves guardadas en el Keychain
  se pierden. Es normal: el Keychain está atado a la firma.
- La app no pide permisos especiales (ni notificaciones push, ni iCloud, ni
  grupos de apps), precisamente para que la firma sea trivial.

---

## Estructura

```
.
├── project.yml                     Definición del proyecto Xcode (XcodeGen)
├── Package.swift                   Paquete NodoCore, para `swift test`
├── NodoCore/
│   ├── Sources/NodoCore/           Lógica pura, sin UIKit ni SwiftUI
│   └── Tests/NodoCoreTests/        Pruebas que corren sin simulador
├── Nodo/
│   ├── NodoApp.swift               Punto de entrada
│   ├── Views/                      Pantallas
│   ├── Support/                    Keychain, red, tema
│   └── Assets.xcassets/            Icono
├── herramientas/generar-icono.py   Regenera el icono 1024×1024
├── docs/VPS.md                     Cómo montar un servidor MCP propio
└── .github/workflows/ios.yml       Compilación en la nube
```

---

## Privacidad

- Las claves de API se guardan en el Keychain del teléfono, con
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. No se sincronizan, no salen del
  dispositivo y no aparecen en los registros.
- Las conversaciones se guardan en el contenedor de la app.
- La app no incluye analítica, ni telemetría, ni servicios de terceros.
- Este repositorio no contiene ningún dato personal, ni claves, ni certificados.

---

## Licencia

MIT. Ver [LICENSE](LICENSE).
