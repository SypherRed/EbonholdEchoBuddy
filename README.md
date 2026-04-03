# EbonholdEchoBuddy

> **WoW 3.3.5a (WotLK) addon for the Project Ebonhold private server**

A three-in-one echo companion: it advises the best build for your class and role, automatically selects echoes for you, and gets smarter with every run through a self-improving AI learning engine.

---

## Features

### 🔍 Build Advisor
Browse the full echo database filtered by your class and role. Each echo is scored using a weighted algorithm that factors in quality tier and role-family relevance so you always know what's worth taking.

- Supports all 10 classes and all 5 roles (Tank, Healer, Melee DPS, Ranged DPS, Caster DPS)
- Scores up to 50 echoes ranked highest-to-lowest
- Hover any row to see a full tooltip breakdown: base score, ELO adjustment, run adjustment, and AI confidence
- **Use My Character** button auto-fills your logged-in class

### ⚡ Auto-Select
Hooks directly into the echo choice popup and automatically picks the highest-scoring option the moment it appears — no clicking required.

- Configurable delay before selecting (default 0.6 s) so the UI has time to render
- On-screen toast notification shows what was picked and why
- Toggle on/off instantly with `/ebauto` or from the GUI

### 🧠 AI Learning Engine
Every echo choice and every run outcome teaches the addon which echoes actually perform best. Three independent signals are combined:

| Signal | How it works |
|---|---|
| **ELO ratings** | Each time echoes are offered together, the chosen one "beats" the unchosen ones. Ratings update using chess-style ELO (K=32 for new echoes, K=16 once established). |
| **Run EMA** | On death, every echo in that run gets its average level-reached updated: `avg = 0.70 × old + 0.30 × new`. Echoes that survive to higher levels score better. |
| **UCB1 exploration** | Rarely-seen echoes receive a small bonus to prevent the model permanently ignoring uncommon picks. The bonus decays as the echo accumulates data. |

**Confidence blending** means the advisor starts at 100% static scoring and gradually shifts toward AI scores as data accumulates. Full AI confidence is reached after 30 comparisons per echo. Confidence is shown as a coloured dot on every row:

| Dot | Meaning |
|---|---|
| ⚫ Grey | No data — static score only |
| 🟡 Yellow | Learning (3–9 comparisons) |
| 🟠 Orange | Building (10–29 comparisons) |
| 🟢 Green | Confident (30+ comparisons) |

Learning data persists across sessions via `SavedVariables` and is stored per-role, so your Tank data never pollutes your Healer data.

---

## Installation

1. Download or clone this repository
2. Copy the `EbonholdEchoBuddy` folder into your WoW addons directory:
   ```
   World of Warcraft\Interface\AddOns\EbonholdEchoBuddy\
   ```
3. The addon requires **ProjectEbonhold** to be present (it ships with the Valanior / Project Ebonhold client)
4. Log in and type `/eb` to open the window

---

## Slash Commands

| Command | Effect |
|---|---|
| `/eb` or `/echobuild` | Open / close the main window |
| `/ebauto` | Toggle auto-select on or off |
| `/ebstats` | Print AI learning stats to chat for all roles |
| `/ebreset [role]` | Wipe AI data for a specific role (or all roles if omitted) |
| `/eb help` | List all commands |

---

## Scoring Formula

```
Static score  =  QualityBase[quality]
               + primaryBonus   (if echo family matches your role's primary family)
               + secondaryBonus (if echo family matches your role's secondary family)

ELO adjustment  = clamp((ELO − 1200) / 400 × 25,  −25, +25)
Run adjustment  = clamp((avgLevelReached / 80 − 0.5) × 30,  −15, +15)
UCB1 bonus      = min(8 × √(ln(totalComparisons) / comparisons),  10)

confidence      = min(1.0, comparisons / 30)

Final score     = StaticScore
                + (ELO_adj + Run_adj) × confidence
                + UCB1_bonus × (1 − confidence)
```

Quality base values: Common=10, Uncommon=20, Rare=30, Epic=40, Legendary=50
Role primary bonus: +40 | Secondary bonus: +5 to +20 depending on role

---

## Role Configurations

| Role | Primary Family | Secondary Family |
|---|---|---|
| Tank | Tank | Survivability |
| Healer | Healer | Survivability |
| Melee DPS | Melee DPS | Survivability |
| Ranged DPS | Ranged DPS | Survivability |
| Caster DPS | Caster DPS | Survivability |

---

## Saved Variables

| Variable | Contents |
|---|---|
| `EchoBuddyDB` | Settings: selected role, auto-select toggle, delay, AI toggle |
| `EchoBuddyLearnDB` | Per-role, per-echo AI data: ELO rating, wins, losses, run count, average level reached |

---

## Requirements

- WoW client: **3.3.5a (build 12340)**
- Server: **Project Ebonhold** (requires `ProjectEbonhold.PerkDatabase` and `ProjectEbonhold.PerkService`)
- The addon is a **passive observer** — it wraps existing server functions non-destructively and never modifies the base addon

---

## Version History

| Version | Changes |
|---|---|
| 3.0 | AI learning engine (ELO + EMA + UCB1), confidence blending, visual redesign, overflow fix |
| 2.0 | Auto-select engine, PerkUI hook, toast notifications |
| 1.0 | Build Advisor GUI, static scoring, class/role filtering |

---

## Author

**Ebonhold** — built for the Valanior / Project Ebonhold community.
