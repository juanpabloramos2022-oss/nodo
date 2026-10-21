# Servidor propio para agentes (opcional)

La app funciona sin servidor: chat, historial y herramientas HTTP. Este documento
es para cuando quieras que el modelo pueda **hacer cosas** que un teléfono no
puede hacer: editar archivos, ejecutar comandos, dejar tareas en una cola.

Estado: **documentación de la opción, todavía no hace falta**. La app ya está
preparada para apuntar a un servidor MCP desde la pantalla *Servidor*, así que
montarlo no requiere recompilar nada.

---

## Cuándo tiene sentido

- Quieres usar el teléfono para lanzar trabajo que corre en otro sitio.
- No tienes un computador encendido de forma habitual.
- Quieres que las tareas sigan corriendo cuando cierras la app.

Si nada de eso te hace falta, **no montes nada**: la app ya es útil sola.

---

## Qué necesitas

Un servidor pequeño con acceso por HTTPS. Sirve cualquiera:

| Opción | Coste orientativo | Nota |
|---|---|---|
| VPS 1 vCPU / 1 GB | ~5 USD al mes | Suficiente para un harness y una cola de tareas |
| Contenedor en un servicio gestionado | Variable | Más cómodo, menos control |
| Un equipo propio siempre encendido | 0 | Gratis, pero deja de estar disponible cuando se apaga |

Requisitos reales: Docker (o el runtime que uses), un nombre de dominio o un
túnel HTTPS, y **un token largo y aleatorio**.

---

## Reglas que no se negocian

1. **HTTPS, siempre.** Nunca expongas el servidor en HTTP plano: el token viaja
   en una cabecera y cualquiera en la red lo leería.
2. **Token propio y rotable.** Genéralo con algo como
   `openssl rand -hex 32`. No reutilices claves de API de modelos.
3. **Escucha solo en localhost** y publica con un proxy inverso o un túnel. El
   puerto del servidor no debe quedar abierto a internet.
4. **Nada de datos personales en el repositorio.** La configuración del servidor
   va por variables de entorno, nunca en un archivo versionado.
5. **Límite de daño.** El servidor ejecuta lo que le pidas. Si va a tocar
   archivos, que sea dentro de una carpeta acotada y con copia de seguridad.

---

## Variables de entorno de ejemplo

```bash
# .env — NUNCA se versiona (ya está en .gitignore)
NODO_MCP_TOKEN=cambia-esto-por-openssl-rand-hex-32
NODO_MCP_PUERTO=8788
NODO_CARPETA_TRABAJO=/srv/nodo/trabajo
```

---

## Esbozo de `docker-compose.yml`

Los nombres de imagen son un marcador de posición: pon el servidor MCP que
decidas usar.

```yaml
services:
  nodo-servidor:
    image: ejemplo/servidor-mcp:latest
    restart: unless-stopped
    environment:
      TOKEN: ${NODO_MCP_TOKEN}
    volumes:
      - ./trabajo:/srv/nodo/trabajo
    ports:
      # Solo en localhost: el proxy inverso es quien habla con internet.
      - "127.0.0.1:8788:8788"
```

---

## Publicarlo con HTTPS

Dos caminos habituales:

- **Proxy inverso con certificado automático** (Caddy es el más corto: dos líneas
  de configuración y Let's Encrypt se encarga).
- **Túnel** (Cloudflare Tunnel, Tailscale Funnel, ngrok). Cómodo para probar,
  pero la URL puede cambiar y el tráfico pasa por un tercero.

Con Caddy, el `Caddyfile` es prácticamente esto:

```
nodo.tudominio.example {
    reverse_proxy 127.0.0.1:8788
}
```

---

## Conectarlo desde la app

1. Abre Nodo → **Ajustes → Servidor**.
2. Pega la URL del endpoint MCP (por ejemplo
   `https://nodo.tudominio.example/mcp`).
3. Pega el token. Se guarda en el Keychain.
4. Pulsa **Probar conexión**. La app lista las herramientas que el servidor
   expone, o muestra el error exacto si algo falla.

Si el servidor no responde, la app sigue funcionando en modo chat: las
herramientas simplemente no aparecen.

---

## Comprobar que está bien expuesto

Desde fuera de tu red:

```bash
# Debe responder 401 sin token: significa que el servidor está vivo y protegido.
curl -i https://nodo.tudominio.example/mcp

# Con token, debe responder al saludo inicial del protocolo.
curl -i -H "Authorization: Bearer $NODO_MCP_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"0"}}}' \
     https://nodo.tudominio.example/mcp
```

Si la primera petición devuelve el contenido en vez de `401`, el servidor está
abierto: ciérralo antes de seguir.
