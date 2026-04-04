# Security Scan Report — EbonholdEchoBuddy v4.0

This document records the security checks performed on the addon before public distribution.
Scan date: **2026-04-04**

---

## Antivirus Scan — Windows Defender

Engine: **Microsoft Defender Antivirus** (Windows 11, signatures up to date)
Scan type: Custom file scan (`MpCmdRun.exe -Scan -ScanType 3`)

| File | Result |
|---|---|
| `EbonholdEchoBuddy.lua` | ✅ No threats found |
| `EbonholdEchoBuddy.toc` | ✅ No threats found |
| `EbonholdEchoBuddy_v4.0.zip` (full archive) | ✅ No threats found |

---

## Static Code Analysis

Every line of the addon source was scanned with regex pattern matching for known threat categories.

| Category | Pattern checked | Result |
|---|---|---|
| Network calls | `http`, `socket`, `ftp`, `dns`, `curl` | ✅ None found |
| Shell / OS execution | `os.execute`, `io.popen`, `cmd.exe` | ✅ None found |
| File write operations | `io.open`, `io.write`, `WriteFile`, `dofile`, `loadfile` | ✅ None found |
| Code obfuscation | `loadstring`, `base64` | ✅ None found |
| Dangerous eval | `RunScript`, `SecureHandler` | ✅ None found |
| Credential / key patterns | `password`, `passwd`, `secret`, `api_key` | ✅ None found |
| Chat snooping | `CHAT_MSG_WHISPER`, `ChatFrame_AddMessageEventFilter` | ✅ None found |
| Keylogging / input capture | `GetCursorPosition`, `IsMouseButtonDown`, `GetMouseFocus` | ✅ None found |
| Inter-addon messaging | `SendAddonMessage`, `RegisterAddonMessagePrefix` | ✅ None found |

---

## Code Behaviour Audit

A full manual review of the source was conducted. Findings:

| Property | Detail |
|---|---|
| **Lines of code** | 2,008 |
| **Functions** | 55 — all declared `local`, no global function pollution |
| **WoW events registered** | 5 — `PLAYER_DEAD`, `PLAYER_LEVEL_UP`, `PLAYER_ENTERING_WORLD`, `ADDON_LOADED`, `PLAYER_LOGIN` |
| **External hooks** | 2 — `PerkUI.Show` and `PerkService.SelectPerk` (non-destructive wraps; originals always called first) |
| **Data storage** | `EchoBuddyDB` and `EchoBuddyLearnDB` WoW `SavedVariables` only — stored locally in the WoW client folder |
| **Output channels** | `print()` to the WoW chat window only — no outbound communication of any kind |
| **Network access** | None — the addon performs zero network requests |
| **Zip archive size** | 31.6 KB |

### What the addon actually does

1. **Reads** `ProjectEbonhold.PerkDatabase` (the server's echo data, already present on the client)
2. **Wraps** two server functions non-destructively to observe echo choices
3. **Computes** scores locally using ELO, EMA, and static weights
4. **Writes** results to WoW `SavedVariables` (a plain Lua file in the WoW directory)
5. **Displays** a GUI window and an optional auto-select toast notification

The addon cannot read, transmit, or exfiltrate any player data. It has no awareness of usernames, passwords, account details, or anything outside the WoW API surface.

---

## Verdict

> **Safe to distribute.** No threats detected by antivirus. No suspicious code patterns found by static analysis. Behaviour is limited to local scoring, local storage, and in-game UI rendering.
