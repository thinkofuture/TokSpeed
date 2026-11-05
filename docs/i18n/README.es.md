<p align="center"><img src="../../Resources/AppIcon.png" alt="Logo de TokSpeed" width="120" /></p>
<h1 align="center">TokSpeed</h1>
<p align="center"><strong>Comprueba en la barra de menús si tu IA está holgazaneando.</strong></p>
<p align="center">
  <a href="../../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a> · <strong>Español</strong>
</p>

---

TokSpeed es una aplicación ligera para la barra de menús de macOS que lee registros locales de **Codex, OpenCode, Claude Code y Antigravity** para mostrar la velocidad de generación de tokens y las tendencias de las últimas llamadas. No requiere clave API ni llamadas adicionales a modelos.

## Compilar y ejecutar

Requiere **macOS 13 o posterior** y Xcode Command Line Tools con modo de lenguaje Swift 5. Usa AppKit y SQLite del sistema, sin dependencias externas. Se compila para la arquitectura de tu Mac (Apple Silicon o Intel), no como binario universal.

Instala las herramientas de línea de comandos si las necesitas y ejecuta lo siguiente desde el repositorio descargado o clonado:

```sh
xcode-select --install
bash scripts/build.sh
open build/TokSpeed.app
```

La aplicación solo aparece en la barra de menús, no en el Dock. Las herramientas no instaladas se ocultan del resumen, la selección de fuente y el orden personalizado. Las instaladas sin registros muestran «Sin datos». La interfaz sigue los idiomas preferidos del sistema: inglés, chino simplificado/tradicional, japonés, coreano, alemán, francés y español, con inglés como alternativa. Reinicia la aplicación tras cambiar el idioma.

- **Ajustes…** abre una ventana nativa de macOS y guarda los cambios al instante. «Salir» sigue al final del menú.
- **Fuente / Mostrar**: «Automático» o herramienta fija; «Número y unidad», «Solo número» o «Solo icono». En espera muestra segundos (`s`), no velocidad (`tok/s`); en reposo, solo el rayo.
- **Orden de herramientas**: arrastra las tarjetas directamente en el panel abierto. Una línea indica la posición; suelta para guardar. Suelta fuera de las tarjetas o pulsa Escape para cancelar. Orden predeterminado: Claude Code → Codex → OpenCode → Antigravity. No cambia la selección automática de fuente; VoiceOver ofrece acciones para subir y bajar.
- Las curvas suaves no sobrepasan los valores de los puntos adyacentes.

Puedes mover `build/TokSpeed.app` a Aplicaciones. Para desinstalar, sal de la aplicación y elimínala. Fuente, visualización y orden se guardan en UserDefaults; tras salir, puedes borrarlos con `defaults delete io.github.thinkofuture.tokspeed`.

Actualmente se distribuye como código fuente. El script solo aplica una firma ad-hoc local, sin firma Developer ID ni notarización de Apple. El icono se genera desde `Resources/AppIcon.png` con herramientas del sistema.

## Fuentes de datos y privacidad

| Fuente | Ubicación predeterminada |
| --- | --- |
| Codex | Rollout JSONL en `~/.codex/sessions/` y `~/.codex/archived_sessions/`; respeta `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode/opencode.db`; formatos de tablas V1/V2 implementados por el lector |
| Claude Code | JSONL en `~/.claude/projects/`, sin subagentes; respeta `CLAUDE_CONFIG_DIR` |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` y `conversations/*.db` |

- No necesitas instalar todas las herramientas. Se detectan localmente aplicaciones de escritorio y CLI ejecutables en `PATH` o rutas habituales; los registros residuales no cuentan como instalación. La detección se actualiza automáticamente. Si desaparece una fuente fijada, se usa temporalmente la selección automática sin borrar la preferencia. Cada fuente elige registros recientes sin depender de la ventana en primer plano.
- Los registros pueden contener conversaciones. TokSpeed analiza los campos necesarios para las estadísticas, pero no sube datos, inicia peticiones de red ni modifica los archivos originales. SQLite se abre en modo de solo lectura.
- Solo se guardan preferencias de fuente, visualización y orden, no copias de conversaciones. Oculta los identificadores de sesión y rutas locales de los diagnósticos antes de compartirlos.
- Las aplicaciones iniciadas desde Finder normalmente no heredan las variables del terminal. Para rutas personalizadas, establece las variables y ejecuta desde el terminal el ejecutable que está dentro de la aplicación.

## Mediciones y limitaciones

Las velocidades son estimaciones basadas en registros locales: **no son mediciones instantáneas por token ni una comparación controlada entre herramientas.**

- En Codex, OpenCode y Claude Code: total de tokens de salida de llamadas completadas / suma de sus duraciones registradas en la respuesta actual. Antes de terminar la primera llamada, pueden mostrarse solo segundos.
- Los límites de tiempo varían y pueden incluir la espera del primer token. Claude Code necesita registros del inicio de solicitud y mide hasta el primer bloque de salida completo. Sin los campos necesarios puede no haber datos.
- Antigravity muestra tokens de salida de la última llamada / (espera del primer token + duración del streaming), y actualiza al finalizar.
- Los recuentos siguen lo informado por cada fuente y pueden incluir tokens de razonamiento. Las curvas muestran hasta 12 llamadas recientes, no muestras por segundo; cada fuente usa su propia escala.
- Los formatos de origen están fuera del control del proyecto. Las actualizaciones, rutas personalizadas o campos ausentes pueden causar datos incompletos o estimaciones inexactas. No se garantiza compatibilidad con todas las versiones.

## Comprobaciones básicas

Sin leer conversaciones reales ni modificar preferencias: comprueba detección y ocultación de herramientas, ocho idiomas y alternativa, modos de visualización, persistencia del orden, curvas, colores claros/oscuros, iconos y escrituras parciales de Codex.

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

Añade `-AppleLanguages '("es-ES")'` para elegir idioma y `--preview-directory <directorio>` para guardar vistas claras/oscuras.

## Licencia

El código está bajo la [MIT License](../../LICENSE). Las fuentes y licencias de iconos de terceros están en [Resources/Logos/NOTICE.md](../../Resources/Logos/NOTICE.md), incluido en la aplicación. Las marcas pertenecen a sus propietarios. TokSpeed no está afiliado a los proveedores ni respaldado por ellos; la licencia del código no otorga derechos de marca.
