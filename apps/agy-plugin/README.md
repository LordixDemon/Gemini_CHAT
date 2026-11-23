# Antigravity Remote Plugin

Native Google Antigravity plugin providing Claude Code `/rc` & Codex-style mobile control:

- **Auxiliary Side Pane (`control-pane`)**: Displays live offline-generated QR code, 6-digit pairing PIN, LAN IP selector, Cloudflare Edge / Tunnel configuration, paired devices, and pending tool approvals.
- **`PreToolUse` Gatekeeper Hook**: Routes sensitive tool executions (`run_command`, `write_file`, `edit_file`) to your phone for instant **Approve / Deny** when `Ask Phone` mode is active.
- **`remote-control` Skill**: Quick conversational access to pairing and session status.

