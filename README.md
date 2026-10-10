# TRMNL Display Plugin for KOReader

Turn a Kindle, Kobo, or any KOReader-compatible e-reader into a [TRMNL](https://trmnl.com) dashboard.

A spiritual successor to the [TRMNL Kindle Script](https://github.com/usetrmnl/trmnl-kindle).

## What You Need

- A KOReader-compatible device with [KOReader](https://github.com/koreader/koreader) installed
  - Kindles need jailbreaking first: [instructions](https://github.com/usetrmnl/trmnl-kindle)
- A TRMNL [BYOD license](https://shop.trmnl.com/products/byod), a [BYOD/S setup](https://docs.trmnl.com/go/diy/byod-s), or your own BYOS server

## Install

1. Register your device at [trmnl.com](https://trmnl.com): gear icon (⚙️) → BYOD device settings. Pick a device model and enter your MAC address, which KOReader shows under **Menu → Network → Info**.
2. Download this repository (green **Code** button → **Download ZIP**) and unzip it.
3. Open `trmnl.koplugin/apikey.txt` and replace its contents with your device API key.
4. Copy the whole `trmnl.koplugin` folder into KOReader's `plugins/` directory. On a Kindle: connect over USB, open the mounted drive, and drop the folder into `/koreader/plugins/`.
5. Restart KOReader.
6. Open **Tools → TRMNL Display** to confirm the plugin loaded, then choose **Fetch screen now**.

If the screen appears, you are done. Tap it (or press a button on non-touch devices) to dismiss it.

## Run It as a Dashboard

For a device that sits on a desk and updates itself:

1. Stop KOReader from sleeping:
   - **Tools → More tools → Keep alive** — enable
   - **Settings → Device → Auto suspend timeout** — disable
2. **Tools → TRMNL Display → Enable auto-refresh**. The first fetch happens immediately, then repeats on your refresh interval.
3. Leave KOReader on that screen.

Tap the display to stop. To start again later, use **Start TRMNL (interactive)**.

On a shared dashboard, set **Dashboard gestures** to **Hold closes, tap fetches a new screen** so a stray tap shows the next screen instead of closing it.

## Make the Battery Last

This is the difference between a few days and a few weeks of runtime.

- **Settings → Frontlight** — set to zero
- **Settings → Network:**
  - Uncheck **Wi-Fi connection** so Wi-Fi is not permanently on
  - **Action when Wi-Fi is off**: `turn on`
  - **Action when done with Wi-Fi**: `turn off`
- Use a longer refresh interval. Every fetch wakes the radio and repaints the screen.
- Keep **E-ink refresh type** on **UI (balanced)**. Only switch to **Full** when image quality matters more than power.

## Settings

**Tools → TRMNL Display → Configure TRMNL**

| Setting | What it does |
|---|---|
| **API Key** | Your device API token |
| **Base URL** | Server to fetch from. Defaults to `https://trmnl.app`; change it for BYOS |
| **Refresh Interval** | Seconds between fetches (default 1800) |
| **MAC address header name** | Header the MAC is sent under. Defaults to `ID`, which is what TRMNL and most BYOS servers expect |
| **MAC address** | Leave blank to auto-detect. Set it manually if detection fails or you need to send a specific value |

Also in the **TRMNL Display** menu:

- **Use server refresh interval** — let the server's `refresh_rate` override your local interval. Recommended, since you can then retune timing from the dashboard without touching the device.
- **E-ink refresh type** — UI (balanced), Full (best quality), Flash UI, or Partial (fastest)
- **Dashboard gestures** — **Tap closes the screen** (default), or **Hold closes, tap fetches a new screen**
- **Show status notifications** — errors are always shown regardless

## Gestures

The plugin registers two actions with KOReader's dispatcher, so you can bind them to gestures, corner taps, or hardware keys via **Settings → Taps and gestures → Gesture manager**:

- **TRMNL: Fetch now** — pull the next screen without opening menus
- **TRMNL: Start (interactive)**

Binding *Fetch now* to a corner tap is a fast way to page through dashboards.

## Using Your Own Server

Set **Base URL** to your server, for example `https://your-server.com`. The plugin calls `GET <base_url>/api/display` and expects a JSON body containing `image_url`, optionally with `refresh_rate` and `filename`.

Requests include the device MAC under the header named in **MAC address header name** (`ID` by default). [Terminus](https://github.com/usetrmnl/terminus) and `byos_laravel` both read `id`, so the default works as-is. If your server expects something else, change the header name rather than patching the plugin.

## Troubleshooting

**"Device not found", or fetches that stopped working after you changed the MAC address**

Changing a device's MAC address on trmnl.com **regenerates its API key**. Official firmware re-registers itself and picks up the new key automatically, but this plugin cannot. Go back into the device settings, copy the API key again, and paste the new one into the plugin.

**Other errors mentioning the server**

The plugin shows whatever the server reported. The same text is written to `koreader/crash.log`, which is the first place to look when reporting a problem.

**"Failed to reach TRMNL API"**

The request never got out. Check Wi-Fi, and check **Base URL** if you are on BYOS.

**Device keeps sleeping**

Use **Enable auto-refresh** rather than **Fetch screen now**, and apply the two sleep settings under [Run It as a Dashboard](#run-it-as-a-dashboard).

**Ghosting or a muddy image**

Set **E-ink refresh type** to **Full**.

## Learn More

- **[DEVELOPMENT.md](DEVELOPMENT.md)** — architecture, API details, development setup
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — code style and contribution workflow
- **[TRMNL API Docs](https://trmnl.com/developers)** — official API reference

---

Made with love by the TRMNL team
