# Contributing to TRMNL Display Plugin

Thank you for contributing! This plugin values simplicity, user experience, and battery consciousness.

## Getting Started

1. Read [DEVELOPMENT.md](DEVELOPMENT.md) for architecture overview
2. Set up emulator (see DEVELOPMENT.md)
3. Check open issues or propose new features
4. For large changes, discuss in an issue first

## Core Principles

### Simplicity Over Cleverness

Boring code is good code

### User Experience First

- Clear, actionable error messages
- Helpful but not overwhelming notifications
- Never fail silently

```lua
-- Good
text = _("Failed to reach TRMNL API. Check your WiFi connection and try again.")

-- Bad
text = _("Error occurred")
```

### Battery Conscious

E-ink devices have limited power. Be mindful of:

- WiFi connections (connect only when needed)
- Screen refreshes (use appropriate e-ink modes)
- Background tasks (respect sleep states)

### Follow KOReader Conventions

- Use KOReader's widget system
- Leverage `UIManager` for scheduling
- Use `G_reader_settings` for persistence
- Implement standard lifecycle hooks

## Code Style

**Read main.lua for patterns**

## Testing

### Manual Testing Checklist

Before submitting:

- [ ] Plugin loads without errors
- [ ] Configuration saves correctly
- [ ] Manual fetch works with valid API key
- [ ] Auto-refresh schedules and runs correctly
- [ ] WiFi connects/disconnects as expected
- [ ] Device wake from sleep works correctly
- [ ] Error messages are clear and helpful
- [ ] No duplicate scheduled tasks (check logs)

### Test Scenarios

- Fresh install (no saved settings)
- Upgrade from previous version
- Network failures (disconnect WiFi mid-fetch)
- Invalid API keys
- Sleep/wake cycles during auto-refresh

### Run Emulator

```bash
cd koreader
./kodev run --debug
```

Watch terminal for errors and log output.

## Resources

- **[main.lua](trmnl.koplugin/main.lua)** - Read for implementation patterns
- [DEVELOPMENT.md](DEVELOPMENT.md) - Architecture and setup
- [KOReader Plugin Wiki](https://github.com/koreader/koreader/wiki/Plugin-Development)
- [TRMNL API Docs](https://usetrmnl.com/developers)
