# Antigravity Remote Control

Удалённое управление сессиями **Google Antigravity** со смартфона (Flutter Mobile App и встроенный PWA) по локальной сети **LAN** и через **Cloudflare Edge (Workers + Durable Objects / Quick Tunnel)**.

## Возможности
- **Мгновенный пейринг**: автономный QR-код (SVG) и одноразовый 6-значный PIN прямо в боковой панели IDE.
- **Живой стриминг сессий**: шаги агента (`transcript.jsonl`), мысли, вызовы инструментов, артефакты и интерактивный `git diff`.
- **Удалённый Gatekeeper (`PreToolUse`)**: режимы `Ask Phone`, `Auto-Safe` и `Observe` для подтверждения команд и записи файлов с экрана телефона.
- **Единый Bridge (`:7443`)**: бесшовно синхронизируется с нативным плагином Antigravity 2.0 (`antigravity-remote`) и CLI `agy-bridge`.

## Команды
- `Antigravity Remote: Open Control Panel & QR Code`
- `Antigravity Remote: Rotate Pairing PIN & QR`
- `Antigravity Remote: Switch Mobile Approval Mode`
- `Antigravity Remote: Configure Cloudflare Edge / Tunnel`
