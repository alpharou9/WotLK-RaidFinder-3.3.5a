# RaidFinder

A lightweight WoW addon for **WotLK 3.3.5a** (Warmane / Icecrown) that scans chat for raid recruitment messages and presents them in a clean, filterable, searchable UI.

Stop scrolling through Trade chat spam — let RaidFinder collect and organize it for you.

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Client](https://img.shields.io/badge/WoW-3.3.5a-yellow)
![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

- 🔍 **Auto-scans chat** — monitors Trade, LFG, General, Say, Yell, and Guild channels
- 🏰 **Detects all WotLK raids** — ICC, RS, ToC, Ulduar, Naxx, OS, EoE, VoA, Onyxia
- 🎯 **Smart parsing** — extracts raid name, size (10/25), difficulty (Normal/HC), role needed (Tank/Heal/DPS), and GearScore requirements
- 🔎 **Filter buttons** — quickly filter by raid, role, or size
- 💬 **One-click whisper** — click any entry to whisper the recruiter
- 🔔 **Sound alerts** — optional per-raid sound notifications
- ⚙️ **Fully configurable in-game** — no code editing required
- 💾 **Settings persist** between sessions

---

## Installation

1. **Download** this repository (Code → Download ZIP) or clone it:
   ```
   git clone https://github.com/alpharou9/WotLK-RaidFinder-3.3.5a.git
   ```

2. **Copy** the `RaidFinder` folder into your WoW AddOns directory:
   ```
   World of Warcraft 3.3.5a/Interface/AddOns/RaidFinder/
   ```
   
   The folder structure should look like:
   ```
   Interface/
   └── AddOns/
       └── RaidFinder/
           ├── RaidFinder.toc
           └── RaidFinder.lua
   ```

3. **Restart WoW** or type `/reload` if already in-game.

4. You should see in chat:
   ```
   [RaidFinder] Loaded! /rf to open · /rf config for settings · /rf help for commands.
   ```

---

## Usage

### Slash Commands

| Command | Description |
|---|---|
| `/rf` | Toggle the main scanner window |
| `/rf config` | Open the settings panel |
| `/rf clear` | Clear all collected entries |
| `/rf help` | Show help in chat |

### Main Window

- **Filter bar** at the top — click to filter by raid, role, or size. Click again to deselect. Active filters turn green.
- **Click "Reset"** to clear all filters.
- **Hover** over any entry to see the full message, channel, and time.
- **Left-click** any entry to open a whisper to that player.
- **Drag** the title bar to reposition the window.
- **ESC** or the ✕ button to close.

Entries auto-refresh every 3 seconds and live-update when new messages arrive.

---

## Settings (`/rf config`)

You can also open settings by clicking the **⚙ gear icon** in the top-left of the main window.

### Channels to Monitor
Toggle which chat types are scanned. Defaults:
| Channel | Default |
|---|---|
| Trade / LFG / General | ✅ On |
| Yell | ✅ On |
| Say | ✅ On |
| Guild | ✅ On |
| Party / Party Leader | ❌ Off |
| Raid / Raid Leader | ❌ Off |

### Entry Lifetime
How long entries stay in the list before expiring. Adjustable from **1 minute to 15 minutes** (default: 5 minutes).

### Minimum GearScore Filter
Hide entries whose detected GearScore is below a threshold. Adjustable from **0 (disabled) to 6500**. Entries without a GS mentioned are always shown.

### Sound Alerts
Enable per-raid sound notifications. When checked, a raid warning sound plays whenever a matching recruitment message is detected — even if the main window is closed.

### Custom Keywords
Add your own recruitment keywords on top of the built-in ones. Useful for server-specific lingo:
- `gdkp` — Gold DKP runs
- `ms>os` — Main-spec over off-spec
- `sr` — Soft reserve
- `gbid` — Gold bid
- `alt run` — Alt character runs

Type a keyword and click **Add** (or press Enter). Click **Remove** to delete one.

### Reset to Defaults
Wipe all settings back to factory defaults with one click.

---

## Detected Raids

| Tag | Matched Keywords |
|---|---|
| **ICC** | icc, icecrown, citadel |
| **RS** | ruby sanctum, halion |
| **ToC** | toc, togc, trial of the crusader, anub |
| **Ulduar** | ulduar, yogg, algalon, mimiron, freya, hodir, thorim, vezax |
| **Naxx** | naxx, naxxramas |
| **OS** | obsidian sanctum, sarth |
| **EoE** | eye of eternity, malygos |
| **VoA** | vault, archavon, emalon, koralon, toravon |
| **Ony** | onyxia |

## Built-in Recruit Keywords

Messages must contain **both** a raid keyword **and** a recruitment keyword to be captured:

`lfm` · `lf` · `looking for` · `need` · `whisper` · `pst` · `pm me` · `w me` · `/w` · `come join` · `join us` · `recruiting` · `forming` · `last spot` · `last slot` · `putting together` · `hosted`

Plus any custom keywords you add via the settings panel.

---

## FAQ

**Q: Why am I not seeing any entries?**  
A: Make sure the right channels are enabled in `/rf config`. On Warmane, most recruitment happens in Trade chat and Yell (especially in Dalaran).

**Q: Can I add keywords for things like "GDKP" or "MS>OS"?**  
A: Yes! Open `/rf config`, scroll to "Custom Keywords", type the keyword, and click Add.

**Q: Do settings save between sessions?**  
A: Yes, everything is saved via WoW's SavedVariables system.

**Q: Does this work on other 3.3.5a servers?**  
A: Yes, it should work on any 3.3.5a WotLK server (Warmane, ChromieCraft, etc.).

---

## License

MIT — do whatever you want with it.
