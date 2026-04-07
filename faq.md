# Frequently Asked Questions

## How do I install this plugin in KOReader?

1. Replace the text in `trmnl.koplugin/apikey.txt` with your API key.
2. Copy the entire `trmnl.koplugin` folder (now containing your `apikey.txt`) into your KOReader `plugins/` directory. Typical Kindle workflow: connect the Kindle to your computer via USB, open the mounted Kindle drive, and drag and drop `trmnl.koplugin` into `/koreader/plugins/`.
3. Restart KOReader.
4. Open **Tools -> TRMNL Display** to verify the plugin loaded.

## How do I configure this plugin to work with my own server?

Use **Tools -> TRMNL Display -> Configure TRMNL** and set:

- **API Key**: your server token (change only if needed)
- **Base URL**: your server URL (for example: `https://your-server.com`)
- **Refresh Interval**: optional manual interval in seconds

The plugin calls `GET <base_url>/api/display`, so your server should expose a compatible endpoint.

Refresh interval precedence:

- By default, the manual **Refresh Interval** on the device is used.
- If **Use server refresh interval** is enabled and the server returns a valid `refresh_rate`, the server value overrides the manual one.

Recommended workflow: enable **Use server refresh interval** so you can adjust timing from your server or dashboard without changing Kindle settings.

## How do I run the plugin to turn my Kindle into a TRMNL?

In KOReader, make sure sleep prevention is enabled so the device stays awake while acting as a dashboard. I changed two settings:

1. **Tools -> More tools -> Keep alive** (enable it).
2. **Settings -> Device -> Auto suspend timeout** (disable it).

Once configured, open **Tools -> TRMNL Display** and:

1. Enable **Auto refresh**. The first time you enable it, the plugin automatically fetches and displays the current screen.
2. Leave KOReader open on that screen to use the Kindle as a passive dashboard.

To stop the plugin, tap the display. To restart it after auto-refresh has been enabled, use **Start TRMNL (interactive)**.

If **Use server refresh interval** is enabled, the server-provided `refresh_rate` controls update timing. Otherwise, the device's local **Refresh Interval** setting is used.

## What can I do to extend battery life?

- Set **Settings -> Frontlight** to zero.
- Set the following in KOReader under **Settings -> Network**:
  - Uncheck **Wi-Fi connection** (do not keep Wi-Fi permanently on).
  - **Action when Wi-Fi is off**: `turn on`
  - **Action when done with Wi-Fi**: `turn off`
- Use a longer refresh interval to reduce Wi-Fi activity and screen updates. If you enable **Use server refresh interval**, make sure your server returns a sensible refresh rate (not too aggressive).
- Set **E-ink refresh type** to **UI (balanced)** for normal use; switch it to **Full** only when image quality is more important than power.
