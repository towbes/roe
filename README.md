
# RoE – Records of Eminence Profile Helper (Ashita v4)

**Author:** Original by Cair, ported by Commandobill  
**Version:** 1.0  
**License:** [MIT License](https://opensource.org/licenses/MIT)

RoE is an Ashita v4 addon designed to help players manage Records of Eminence (RoE) objectives by allowing them to create, save, load, and manage named profiles. It includes functionality to automate the setting and clearing of objectives based on customizable settings, blacklist management, and auto-refreshing of RoE status at startup.

---

## 📦 Features

- Save current RoE objectives to named profiles
- Load saved profiles and apply objectives intelligently
- Automatically clear inactive or in-progress objectives
- Maintain a blacklist of objectives that should never be removed
- Toggle settings via command line
- Auto-request RoE status refresh on zone-in
- Fully manual or semi-automated operation
- Supports legacy string-based profiles

---

## 🚀 Getting Started

### ✅ Requirements

- [Ashita v4](https://ashita.atom0s.com/)
- Final Fantasy XI with active RoE system

### 📁 Installation

1. Download or clone this repository into your Ashita `addons` folder:

```
addons/
└── roe/
    ├── roe.lua
```

2. Launch Ashita and load the addon in-game:

```bash
/addon load roe
```

---

## 🧪 Usage

### 🔧 Base Command

All commands use the `/roe` prefix:

```bash
/roe <subcommand> [arguments]
```

### ➕ Add/Remove an RoE by ID or Name

```bash
/roe add <id or name>
    Add a specific ROE objective by its ID number or name.
    Examples:
    /roe add 77
    /roe add "spoils light crystal"
    /roe add "vanquish enemy"

/roe rem <id or name>
    Remove a specific ROE objective by its ID number or name.
    Examples:
    /roe rem 77
    /roe rem "spoils light crystal"
    /roe rem "vanquish enemy"
```

### 💾 Save a Profile

```bash
/roe save <profile_name>
```

Saves your currently active RoE objectives under a named profile.

---

### 📥 Load a Profile

```bash
/roe set <profile_name>
```

Loads and applies a saved profile. It will:

- Cancel incomplete or complete objectives if needed (based on settings)
- Leave blacklisted objectives untouched
- Alert you if not enough slots are available

---

### 🧹 Unset Objectives

```bash
/roe unset [profile_name]
```

- If a profile name is provided, removes only those objectives
- If no name is provided, clears only unprogressed objectives (or in-progress if `clearprogress` is on)

---

### 📋 List Profiles

```bash
/roe list
```

Displays all saved profile names in the console.

---

### ⚙️ Toggle Settings

```bash
/roe settings <name> [true|false]
```

Toggles or sets one of the following options:

| Setting        | Description                                                   | Default |
|----------------|---------------------------------------------------------------|---------|
| `clear`        | Remove incomplete objectives if needed                        | `true`  |
| `clearprogress`| Also remove in-progress objectives                            | `false` |
| `clearall`     | Remove all objectives before loading a profile                | `false` |

Example:

```bash
/roe settings clearprogress true
```

---

### 🚫 Blacklist Management

```bash
/roe blacklist [add|remove] <id>
```

Adds or removes an objective ID from the blacklist. Blacklisted objectives will not be removed even when clearing objectives.

Example:

```bash
/roe blacklist add 3001
```

---

### ❓ Help

```bash
/roe help
```

Prints the full list of commands and usage.

---

## 🔄 Startup Behavior

- When the addon loads and you are in a safe state (not zoning), it will send a blank 0x112 packet to request your current RoE status.
- This ensures the internal `active` and `complete` objective states are accurate even if you load the addon after logging in.

---

## 🧠 Internals

- Uses a custom `Set` implementation for efficient ID tracking
- Profiles are saved using Ashita's `settings.lua` persistence system
- Packet IDs:
  - `0x10C` – Accept RoE objective
  - `0x10D` – Cancel RoE objective
  - `0x111` – Current active objectives
  - `0x112` – Completed objective bitmap (can be used as a refresh request)

---

## 🧾 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
