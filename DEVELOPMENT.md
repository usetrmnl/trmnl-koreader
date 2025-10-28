# Development Guide

Technical architecture, development setup, and extension guide for the TRMNL KOReader plugin.

## Architecture

### Components

- **`TrmnlDisplay`** (main.lua:63-1168) - Main plugin class extending `WidgetContainer`
- **`RetryManager`** (main.lua:31-57) - Exponential backoff for failed requests
- **Network layer** - LuaSocket (HTTP/HTTPS)
- **UI integration** - KOReader's `UIManager` and widget system

### Key Files

- `main.lua` - Plugin implementation
- `_meta.lua` - Plugin metadata
- `apikey.txt` - Optional auto-configuration file

### Lifecycle Hooks

The plugin implements standard KOReader hooks:

- **`init()`** (main.lua:109) - Load settings, restore state, schedule auto-refresh
- **`onSuspend()`** (main.lua:893) - Pause refresh during sleep (battery savings)
- **`onResume()`** (main.lua:910) - Fetch immediately on wake if auto-refresh enabled
- **`onFlushSettings()`** (main.lua:140) - Persist settings to disk
- **`onCloseWidget()`** (main.lua:935) - Cleanup on shutdown

### Data Flow

See main.lua:745-796 for complete fetch cycle implementation:

1. `fetchAndDisplay()` → `NetworkMgr:runWhenConnected()`
2. `fetchScreenMetadata()` → API request with device headers
3. `downloadImageIfNeeded()` → Smart caching, cleanup old files
4. `displayImage()` → Render with tap handler
5. `scheduleNextRefresh()` → Queue next cycle

## API Details

### Endpoint

```html
GET https://trmnl.app/api/display
```

### Request Headers

| Header | Description | Example |
|--------|-------------|---------|
| `access-token` | User's API key | `abc123...` |
| `battery-voltage` | Battery % (0-100) | `85` |
| `png-width` / `png-height` | Screen dimensions | `1448` / `1072` |
| `rssi` | WiFi signal strength | `0` (TODO) |


### Response

```json
{
  "image_url": "https://...",
  "filename": "screen_xyz.png",
  "refresh_rate": 1800
}
```

**Status codes:** 200 (OK), 401 (invalid key), 403 (forbidden), 404 (not found), 500 (server error)

## Development Environment

### Setup

```bash
# Clone and build KOReader
git clone https://github.com/koreader/koreader.git
cd koreader
./kodev build

# Run emulator with debug logging
./kodev run --debug
```

**Options:** `--device=kindle|kobo|remarkable` to emulate specific devices

### Development Tips

- **Plugin location:** `koreader/plugins/trmnl.koplugin/`
- **Settings:** Stored in `koreader/settings.reader.lua`
- **Logging:** Terminal shows all output (use `logger.info()`, `logger.dbg()`, `logger.err()`)
- **No hot-reload:** Restart emulator to see changes
- **WiFi testing:** Emulator can connect to real networks

See [KOReader build docs](https://github.com/koreader/koreader/blob/master/doc/Building.md) for platform-specific prerequisites.

## Extending the Plugin

- main.lua is well-commented for expanding on implementation patterns

## Resources

- **[main.lua](trmnl.koplugin/main.lua)** - Plugin implementation
- [TRMNL API Docs](https://usetrmnl.com/developers) - Official API reference
- [KOReader Plugin Dev Wiki](https://github.com/koreader/koreader/wiki/Plugin-Development)
- [Lua 5.1 Reference](https://www.lua.org/manual/5.1/)
