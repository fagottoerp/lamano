# La Mano App — Registro de Cambios

---

## v3.10.28 — 2026-05-16
### Nuevas funciones
- **Rainbow name para admins**: El nombre de los usuarios con rol administrador (rolId=1) se muestra en degradado arcoíris en grupos y en el AppBar del chat 1-a-1. Solo el nombre, no el mensaje.
- **Botón GPS Vivo (solo admin)**: Ícono 📍 azul en el AppBar principal. Abre `Admin/gps_vivo` en el navegador con el mapa de todos los usuarios en tiempo real.
- **Stickers Giphy**: Integración con Giphy SDK v1.0.9. Pestaña Giphy en el selector de stickers con millones de GIFs, stickers y emojis.
- **Alerta pánico mejorada**: Los botones de volumen ahora requieren mantener presionado **3 segundos** para enviar la alerta (antes era doble toque inmediato). Vol↓ 3s = ALERTA POLICIAL · Vol↑ 3s = ALERTA ROBO.

### Cambios técnicos
- `lib/widgets/rainbow_text.dart` — Nuevo widget `RainbowText` con `ShaderMask` + `LinearGradient`.
- `lib/pages/group_chat_page.dart` — Guarda `senderRolId` en mensajes; muestra `RainbowText` si es admin.
- `lib/pages/chat_page.dart` — Guarda `senderRolId` en mensajes; AppBar con `RainbowText` si peer es admin.
- `lib/pages/home_page.dart` — Botón GPS Vivo con `url_launcher` en AppBar (solo `_isAdmin`).
- `android/MainActivity.java` — Eliminado doble-toque; long press subido a 3000ms; usa `event.getRepeatCount()==0` para evitar re-disparos.
- `lib/utils/panic_alert_service.dart` — Solo responde a `long_down`/`long_up`, eliminadas referencias a `double_down`/`double_up`.

---

## v3.10.27 — 2026-05-16
### Nuevas funciones
- **Stickers Giphy (pubspec)**: Dependencia `giphy_flutter_sdk ^1.0.9` añadida.
- `lib/widgets/sticker_picker.dart` reescrito: tabs Giphy / Mis Stickers / Predeterminados.

---

## v3.10.26 — 2026-05-15
### Nuevas funciones
- **Indicador de escritura** ("escribiendo...") en chat 1-a-1 y grupos.
- **Responder mensajes** (swipe derecha para citar y responder).
- **Reacciones emoji** (long press sobre mensaje → selector de emojis).
- **Reproducción de video** en burbujas de chat.
- **Silenciar chat** (1h / 8h / 24h / 1 semana).
- **Color personalizado de burbujas propias** (selector en Ajustes).
- **Corrección UI grupos**: nombre del emisor sobre la burbuja.

---

## v3.10.25 — 2026-05-14
### Nuevas funciones
- **Selección múltiple de fotos** en chats (hasta 10 imágenes a la vez).
