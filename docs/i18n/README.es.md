<p align="center">
  <img src="../../Resources/AppIcon.png" alt="Logo de TokSpeed" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>Comprueba en la barra de menús si tu IA está holgazaneando.</strong><br>
  Aplicación ligera para la barra de menús de macOS que muestra la velocidad de generación de tokens de Codex, OpenCode, Claude Code, Antigravity, Hermes y Cursor.
</p>

<p align="center">
  Solo lee registros locales — sin clave API, sin subidas, sin solicitudes de red.
</p>

<br>

---

<br>

## Compilar, probar y ejecutar

Requiere macOS 13+ y Xcode Command Line Tools.

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

Compilar un binario universal o ejecutar todas las pruebas:

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## Vistas y funciones

- **Gráfico de tendencia**: Muestra hasta 60 llamadas completadas por herramienta visible en una escala compartida, con colores distintos para las herramientas activas y marcas mínimas en el eje Y. Pasa el cursor por un punto o tarjeta para resaltar su curva y ver los detalles.
- **Lista detallada**: Cambia desde **Ajustes → Vista del panel**. Cuando una herramienta tiene dos o más sesiones activas o recientes, aparecen subfilas indentadas con el título y la velocidad de cada sesión.
- **Fijar y reordenar**: Haz clic en cualquier tarjeta para fijar o desfijar la fuente principal; arrastra las tarjetas (o usa las acciones de VoiceOver) para reordenarlas.
- **Ajustes e integraciones**: **Iniciar al abrir sesión**, visibilidad de herramientas, restablecer orden, **Diagnóstico** local (`TokSpeed --diagnostics`) y control explícito del **Hook de Cursor** (asistente ligero sin AppKit y rotación a 4 MB) y del **plugin de Hermes** (`--install-hermes-plugin [--force]`).

Para ver la velocidad estimada de streaming y el tiempo transcurrido de las solicitudes de Hermes en curso, activa el plugin instalado con `hermes plugins enable tokspeed-metrics`. Sin él se muestran las llamadas completadas de `logs/agent.log`.

## Licencia

[MIT License](../../LICENSE)
