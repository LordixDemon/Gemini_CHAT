---
name: remote-control
description: Opens and manages Antigravity Remote Control (QR code pairing, 6-digit PIN, LAN and Cloudflare Edge mobile sessions, and remote PreToolUse approvals). Activate when the user asks for remote control, mobile app pairing, QR code, or `/rc`.
---

# Antigravity Remote Control (`/remote-control`)

When the user asks to pair a phone, open Remote Control, inspect connected mobile devices, or configure Cloudflare Edge:

1. Check `~/.gemini/antigravity-remote/bridge-runtime.json` to see if the local Bridge is already running (if not, the `antigravity-remote/control-pane` sidecar starts it automatically when enabled).
2. Surface the sidecar UI pill so the user can view the live QR code and manage paired phones directly in the auxiliary pane:
   `[Remote Control](sidecar://antigravity-remote/control-pane/)`
3. Remind the user they can scan the QR code either with the native **Antigravity Remote Flutter App** OR with any mobile camera to open the instant **Mobile Web (PWA)** interface on LAN or Cloudflare Edge.

