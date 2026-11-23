# Antigravity Remote (`agy-remote`)

Система удалённого управления **Google Antigravity** со смартфона (в стиле **Claude Code `/rc`** и **Codex Remote**), спроектированная по архитектуре **Local-First (LAN) → Cloudflare Edge (Workers + Durable Objects)**.

Ваша локальная кодовая база, терминал, ключи, MCP-серверы и контекст агента остаются на вашем ПК — телефон выступает живым защищённым пультом управления.

---

## Состав монорепозитория

| Пакет / Приложение | Путь | Назначение |
| :--- | :--- | :--- |
| **Protocol (`ARP v1`)** | [`packages/protocol`](packages/protocol/src/index.mjs) | Единый JSON/WS-протокол `arp.v1`, парсер `transcript.jsonl`, кодировщик URI пейринга и автономный ISO-генератор QR-кодов в SVG (без внешних API). |
| **Bridge Core** | [`packages/bridge-core`](packages/bridge-core/src/index.mjs) | Единый десктопный сервер (`:7443`), RFC 6455 WebSocket, `BrainWatcher`, `AgentDriver` (`agentapi` + Git Diff + Terminal), `ApprovalGate`, `CloudflareConnector` и встроенный PWA-клиент. |
| **Antigravity Native Plugin** | [`apps/agy-plugin`](apps/agy-plugin/plugin.json) | Нативный плагин Antigravity: боковая UI-панель (`sidecar_sdk`), хук `PreToolUse` (`gatekeeper.mjs`) для подтверждения команд с телефона и скилл `/remote-control`. |
| **VS Code Extension** | [`apps/vscode-extension`](apps/vscode-extension/src/extension.ts) | Расширение для VS Code / Antigravity IDE: иконка в Activity Bar, статус-бар, Webview-панель с QR и управлением Cloudflare. |
| **Cloudflare Edge Relay** | [`apps/cloudflare-edge`](apps/cloudflare-edge/src/index.ts) | Готовый к деплою **Cloudflare Worker + Durable Object (`SessionRoomDO`)** с WebSocket Hibernation для управления сессиями через интернет без проброса портов. |
| **Flutter Mobile App** | [`apps/mobile-flutter`](apps/mobile-flutter/lib/main.dart) | Нативное мобильное приложение (iOS / Android) с QR-сканером, авто-переключением **LAN ↔ Cloudflare**, live-стримом мыслей и тулов агента, шторкой **Approve / Deny** и просмотром Git Diff. |

---

## Быстрый старт (Этап 1: Локальная сеть LAN)

### Вариант А. Внутри Antigravity 2.0 / Antigravity IDE (Нативный плагин)
Плагин уже собран и установлен в `~/.gemini/config/plugins/antigravity-remote`.
1. Включите плагин **Antigravity Remote** на странице Customizations и откройте боковую панель **Remote Control**.
2. Отсканируйте QR-код приложением **Flutter** (или обычной камерой телефона для мгновенного входа через встроенный **Mobile Web PWA**).

### Вариант Б. Из терминала (как `claude /rc`)
```powershell
npm run start:bridge
```
В консоли появится QR-код, 6-значный PIN и локальный адрес `http://192.168.x.x:7443`.

### Вариант В. В VS Code
Откройте папку `apps/vscode-extension` в VS Code и нажмите `F5` (или упакуйте через `npx @vscode/vsce package`).

---

## Запуск мобильного приложения (Flutter — Android / iOS)

```powershell
cd apps/mobile-flutter
flutter pub get
flutter run
```

Возможности мобильного приложения:
- **QR-сканер и 6-значный PIN**: мгновенная привязка ПК с выдачей `HMAC-SHA256` токена устройства.
- **Smart Auto-Failover (`LAN` → `Cloudflare`)**: дома приложение подключается напрямую по Wi-Fi (`2–5 мс`), а при выходе в мобильную сеть 5G/LTE автоматически переключается на Cloudflare Edge WSS.
- **Сессии и Live-чат**: список всех сессий Antigravity из `~/.gemini/*/brain`, просмотр блоков `<Thinking>`, вызовов тулов, артефактов и отправка промптов / слэш-команд (`/plan`, `/boost`, `/compact`).
- **Удалённый Gatekeeper (`PreToolUse`)**: всплывающая карточка с вибрацией и таймером при попытке агента выполнить `run_command`, `write_file` или `edit_file` — кнопки **Разрешить**, **Разрешать в сессии**, **Заблокировать**.
- **Git Diff и Терминал**: инспекция изменённых файлов с цветовой разметкой `+`/`-` и запуск быстрых команд (`git status`, `npm test`, `flutter analyze`).

---

## Подключение Cloudflare (Этап 2: Управление сессиями вне локальной сети)

### Способ 1: Cloudflare Workers + Durable Objects (Рекомендуется)
Не требует белого IP и проброса портов на роутере. Десктопный `BridgeServer` сам устанавливает исходящее WSS-соединение с вашим `SessionRoomDO`.

```powershell
cd apps/cloudflare-edge
npx wrangler login
npx wrangler secret put HOST_AUTH_SECRET
npx wrangler secret put EDGE_SIGNING_SECRET
npx wrangler deploy
```

После деплоя вставьте полученный URL (`https://antigravity-remote-edge.<account>.workers.dev`) и `HOST_AUTH_SECRET` в блок **Cloudflare Сессии и Туннель** в панели расширения Antigravity / VS Code и нажмите **Применить транспорт**.

### Способ 2: Быстрый туннель `cloudflared`
Если на ПК установлен `cloudflared`, просто выберите в панели расширения режим **`Cloudflare Quick Tunnel (cloudflared)`** — расширение автоматически поднимет защищённый `https://*.trycloudflare.com` адрес и обновит QR-код.

---

## Сборка и тестирование

```powershell
# Полная сборка всех пакетов и проверка типов TypeScript (VS Code + Cloudflare Edge)
npm run build

# Синхронизация нативного плагина в ~/.gemini/config/plugins/antigravity-remote
npm run install:plugin

# Интеграционные E2E-тесты (QR, LAN Auth, WS Stream, PreToolUse Hook Gatekeeper)
npm test
```

