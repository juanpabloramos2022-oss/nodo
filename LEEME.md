# Nodo

Una app de iOS para hablar con modelos de inteligencia artificial usando **tus
propias claves de API**, desde el teléfono, sin depender de un computador
encendido.

Estado: **v0.1.0 — usable**. Conversa, guarda el historial, ejecuta herramientas
y se conecta a un servidor propio por MCP.

---

## Qué hace

- **Chat con streaming**, palabra por palabra, con dos protocolos: el formato de
  *chat completions* que hablan casi todos los proveedores y la API de mensajes
  de Anthropic.
- **Tus claves en el llavero del telefono**, nunca en el codigo, en la
  configuracion ni en los registros.
- **Proveedores ilimitados** dados de alta desde la propia app: nombre,
  direccion, modelo y clave. Anadir uno nuevo no requiere recompilar nada.
- **Historial** de conversaciones guardado en el telefono, varias a la vez.
- **Herramientas**: el modelo puede pedir datos de la web (traer_url, solo
  https) y ejecutar las que exponga tu servidor MCP.
- **Servidor remoto opcional por MCP**: apuntas a una URL y la app descubre las
  herramientas que ofrezca. Sin servidor, el chat funciona igual.
- **Exportar e importar la configuracion** entre telefonos, sin claves dentro.

Lo que no puede hacer es un entorno de agentes dentro del telefono: ni editar
archivos, ni ejecutar comandos, ni procesos en segundo plano. Es una limitacion
de iOS, no de la app: una aplicacion vive en un sandbox, sin shell y sin acceso
al sistema de archivos fuera de su contenedor. Los agentes que hacen cosas
necesitan una maquina donde hacerlas; Nodo se conecta a esa maquina por MCP
cuando existe, no la reemplaza. Ver docs/VPS.md.

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
   las 115 pruebas del núcleo, genera el proyecto Xcode con XcodeGen y compila.
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

## Instalar en el iPhone, paso a paso

Todo esto se puede hacer **desde el propio teléfono**, sin computador. El `.ipa`
que produce la compilación está **sin firmar**: hay que firmarlo con un
certificado propio antes de instalarlo.

### 1. Descargar el artifact desde el iPhone

1. Abre **Safari** y entra en la pestaña [**Actions**](../../actions) de este
   repositorio.
2. Toca la ejecución más reciente que tenga el check verde (la de arriba del
   todo). El nombre es el del último commit.
3. Baja hasta el final de la página, a la sección **Artifacts**.
4. Toca **Nodo-ipa**. Empieza a descargar y aparece el icono de descarga en la
   barra de direcciones.

> El artifact caduca a los **30 días**. Si ya no está, lanza la compilación de
> nuevo: en la misma página, **Run workflow** → **Run workflow**.

### 2. Descomprimir el ZIP

El artifact **no** se descarga como `.ipa`, se descarga como **`.zip`** que
contiene `Nodo.ipa` dentro. Hay que descomprimirlo:

1. Abre la app **Archivos** (Files).
2. Ve a **Descargas** (o *En mi iPhone → Descargas*).
3. Toca el archivo `Nodo-ipa.zip`. iOS lo descomprime solo y crea una carpeta
   llamada `Nodo-ipa`.
4. Entra en esa carpeta: ahí está **`Nodo.ipa`**, que es el archivo que hay que
   firmar.

> Si al tocar el ZIP no pasa nada, mantén pulsado y elige **Descomprimir**.

### 3. Firmar con ESign

1. Abre **ESign**.
2. En la pestaña **Archivo** (o *Files*), toca el botón de importar y elige
   **Importar desde Archivos**.
3. Navega a **Descargas → Nodo-ipa** y selecciona **`Nodo.ipa`**.
4. Vuelve a la lista de apps importadas y toca `Nodo.ipa`.
5. Elige **Firmar** (Sign) y selecciona tu certificado.
6. En las opciones de firma, deja el *Bundle ID* como está
   (`com.nodo.ios`) **salvo** que ESign avise de un conflicto: en ese caso,
   cámbialo por algo único, por ejemplo `com.nodo.ios2`.
7. Confirma la firma. Cuando termine, toca **Instalar**.

### 4. Confiar en el certificado

Si al abrir la app aparece *«No es posible verificar la app»* o *«Desarrollador
no confiable»*:

1. **Ajustes → General → VPN y gestión de dispositivos**.
2. En **App de desarrollador**, toca el certificado que acabas de usar.
3. Toca **Confiar en «…»** y confirma.

### 5. Comprobar que funciona

Abre **Nodo** en la pantalla de inicio. Debe mostrar:

```
        Nodo
    Nodo v0.0.1
Cadena de compilación operativa
```

Si aparece eso, la cadena completa funciona: código → GitHub Actions → `.ipa`
→ firma → teléfono. A partir de ahí todo lo demás es añadir funciones.

### Notas

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
