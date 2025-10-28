# TRMNL Display Plugin for KOReader

Display your personalized [TRMNL](https://trmnl.app) dashboard on your e-ink device.

A spiritual successor to the [TRMNL Kindle Script](https://github.com/usetrmnl/trmnl-kindle).

## Table of Contents

- [TRMNL Display Plugin for KOReader](#trmnl-display-plugin-for-koreader)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Quick Start](#quick-start)
    - [1. Register Device](#1-register-device)
    - [2. Configure API Key](#2-configure-api-key)
    - [3. Configure WiFi (Recommended)](#3-configure-wifi-recommended)
    - [4. Fetch](#4-fetch)
  - [Usage](#usage)
  - [Configuration](#configuration)
  - [Troubleshooting](#troubleshooting)
  - [Learn More](#learn-more)

## Prerequisites

- KOReader-compatible device with [KOReader](https://github.com/koreader/koreader) installed
  - Kindle requires jailbreaking: [instructions](https://github.com/usetrmnl/trmnl-kindle)
- TRMNL [BYOD license](https://shop.usetrmnl.com/products/byod) or [BYOD/S setup](https://docs.usetrmnl.com/go/diy/byod-s)

## Quick Start

### 1. Register Device

1. Log in to [usetrmnl.com](https://usetrmnl.com)
2. Click gear icon (⚙️) → BYOD device settings
3. Select your device model and add MAC address (find in KOReader: **Menu → Network → Info**)

### 2. Configure API Key

**Option A:** Create `apikey.txt` in `plugins/trmnl.koplugin/` with your API key, then restart KOReader

**Option B:** In KOReader: **Tools → TRMNL Display → Configure TRMNL**

### 3. Configure WiFi (Recommended)

**Settings → Network** and set:

- "Action when Wi-Fi is off: `turn on`"
- "Action when done with Wi-Fi: `turn off`"

### 4. Fetch

**Tools → TRMNL Display → Fetch screen now**

## Usage

- **Manual fetch:** **Tools → TRMNL Display → Fetch screen now**
- **Auto-refresh mode:** **Tools → TRMNL Display → Enable auto-refresh** (prevents sleep, refreshes every 30 min by default)
- **Tap screen** to close displayed image

## Configuration

Access via **Tools → TRMNL Display → Configure TRMNL**

- **API Key** - Your TRMNL auth token
- **Refresh Interval** - Seconds between fetches (default: 1800)
- **Use Server Refresh Interval** - Let TRMNL control timing
- **E-ink Refresh Type** - UI (balanced), Full (best quality), Flash UI, or Partial (fastest)
- **Show Status Notifications** - Toggle info messages (errors always shown)

## Troubleshooting

**"API request failed (401/403)"**

- Verify API key in settings
- Ensure device is registered at usetrmnl.com
- Check BYOD license is active

**"Failed to reach TRMNL API"**

- Check WiFi connection

**Device keeps sleeping**

- Use **Enable auto-refresh** (not "Fetch screen now")
- Disable "Auto-suspend timeout" in **Settings → Device**
- Use KOReader's "keep awake" feature to prevent sleep during refresh (Tools > More Tools > Page 2 > Keep alive)

**Ghosting/unclear image**
- Change E-ink refresh type to **Full** for better quality

## Learn More

- **[DEVELOPMENT.md](DEVELOPMENT.md)** - Architecture, API details, development setup
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Code style, contribution workflow
- **[main.lua](trmnl.koplugin/main.lua)** - Plugin implementation
- **[TRMNL API Docs](https://usetrmnl.com/developers)** - Official API reference

---

Made with love by the TRMNL team
