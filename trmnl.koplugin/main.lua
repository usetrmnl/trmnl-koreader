--[[--
TRMNL Display Plugin for KOReader

Fetches and displays personalized screens from the TRMNL API.
Supports automatic periodic refresh, full-screen display, and WiFi management.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local Screen = Device.screen
local Input = Device.input
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

--[[--
Retry Manager - handles exponential backoff for failed requests.
Implements: 60s, 120s, 240s, 480s, etc., capped at max_delay.
--]]
local RetryManager = {}
RetryManager.__index = RetryManager
RetryManager.BASE_DELAY = 60
RetryManager.MIN_DELAY = 60

function RetryManager:new(max_delay)
    local instance = {
        count = 0,
        max_delay = max_delay or 1800
    }
    setmetatable(instance, self)
    return instance
end

function RetryManager:getDelay()
    local delay = self.BASE_DELAY * (2 ^ self.count)
    return math.min(delay, math.max(self.max_delay, self.MIN_DELAY))
end

function RetryManager:increment()
    self.count = self.count + 1
    return self:getDelay()
end

function RetryManager:reset()
    self.count = 0
end

--[[--
Main plugin class extending WidgetContainer.
Provides lifecycle hooks (init, onSuspend, onResume) and menu integration.
]]
local TrmnlDisplay = WidgetContainer:extend {
    name = "trmnl",
    is_doc_only = false,

    settings = nil,
    settings_file = nil,

    refresh_task = nil,
    auto_refresh_enabled = false,
    auto_refresh_scheduled = false,
    image_widget = nil,
    last_image_path = nil,
    last_image_filename = nil,
    last_fetch_timestamp = 0,

    retry_manager = nil,
}

TrmnlDisplay.CONSTANTS = {
    RETRY = {
        BASE_DELAY = 60,
        MIN_DELAY = 60,
    },
    TIMING = {
        DEFAULT_REFRESH_INTERVAL = 1800,
        DEBOUNCE_DELAY = 25,
    },
    FILES = {
        DEFAULT_IMAGE = "trmnl_screen.png",
        API_KEY = "apikey.txt",
    }
}

TrmnlDisplay.default_settings = {
    api_key = nil,
    base_url = "https://trmnl.app",
    refresh_interval = 1800,
    user_agent = "trmnl-display/0.1.0-koreader",
    use_server_refresh_rate = false,
    refresh_type = "ui",
    show_notifications = true,
    mac_header_name = nil,  -- Header name for MAC address (configurable for BYOS)
    mac_address = nil,  -- Manual MAC address override (nil = auto-detect)
}

--[[--
Plugin initialization - loads settings, initializes managers, and restores state.
]]
function TrmnlDisplay:init()
    self.settings_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/trmnl.lua")
    self.settings = self.settings_file:readSetting("settings") or util.tableDeepCopy(self.default_settings)
    self.auto_refresh_enabled = self.settings_file:readSetting("auto_refresh_enabled") or false

    self.retry_manager = RetryManager:new(self.settings.refresh_interval or
        self.CONSTANTS.TIMING.DEFAULT_REFRESH_INTERVAL)

    -- Try auto-loading API key from file
    local file_api_key = self:loadApiKeyFromFile()
    if file_api_key then
        self.settings.api_key = file_api_key
        self:saveSettings()
        logger.info("TRMNL: API key auto-configured from file")
    end

    -- Must be instance-specific for UIManager to track properly
    self.refresh_task = function()
        self:fetchAndDisplay()
    end

    self.ui.menu:registerToMainMenu(self)

    if self.auto_refresh_enabled then
        self:startAutoRefresh()
    end
end

--[[--
Save settings to disk (called automatically on suspend/exit).
]]
function TrmnlDisplay:onFlushSettings()
    if self.settings_file then
        self.settings_file:saveSetting("settings", self.settings)
        self.settings_file:saveSetting("auto_refresh_enabled", self.auto_refresh_enabled)
        self.settings_file:flush()
    end
end

function TrmnlDisplay:saveSettings()
    self:onFlushSettings()
end

function TrmnlDisplay:getPluginDir()
    local info = debug.getinfo(1, "S")
    local filepath = info.source:match("^@(.+)$")
    if filepath then
        return filepath:match("(.*/)")
    end
    return nil
end

--[[--
Load API key from apikey.txt in plugin directory (if present).
]]
function TrmnlDisplay:loadApiKeyFromFile()
    local plugin_dir = self:getPluginDir()
    if not plugin_dir then
        return nil
    end

    local apikey_path = plugin_dir .. self.CONSTANTS.FILES.API_KEY
    local file = io.open(apikey_path, "r")
    if not file then
        return nil
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil
    end

    local api_key = content:match("^%s*(.-)%s*$")
    if api_key and api_key ~= "" then
        logger.info("TRMNL: API key loaded from file")
        return api_key
    end

    return nil
end

--[[--
Get MAC address of the wireless network interface.

Uses FFI (Foreign Function Interface) to call POSIX system calls:
- getifaddrs(): Enumerate all network interfaces
- ioctl(SIOCGIWNAME): Check if interface is wireless
- ioctl(SIOCGIFHWADDR): Get hardware (MAC) address

@treturn string|nil MAC address (format: "XX:XX:XX:XX:XX:XX") or nil if not available
]]
function TrmnlDisplay:getMacAddress()
    local ffi = require("ffi")
    local C = ffi.C
    require("ffi/posix_h")

    -- Create socket for ioctl calls
    local socket = C.socket(C.PF_INET, C.SOCK_DGRAM, C.IPPROTO_IP)
    if socket == -1 then
        logger.warn("TRMNL: Could not create socket for MAC address retrieval")
        return nil
    end

    -- Get network interfaces
    local ifaddr = ffi.new("struct ifaddrs *[1]")
    if C.getifaddrs(ifaddr) == -1 then
        C.close(socket)
        logger.warn("TRMNL: Could not get network interfaces")
        return nil
    end

    local mac_address = nil
    local ifa = ifaddr[0]

    -- Loop through interfaces to find wireless one
    while ifa ~= nil do
        if ifa.ifa_addr ~= nil and
           bit.band(ifa.ifa_flags, C.IFF_UP) ~= 0 and
           bit.band(ifa.ifa_flags, C.IFF_LOOPBACK) == 0 then

            -- Check if wireless interface
            local iwr = ffi.new("struct iwreq")
            ffi.copy(iwr.ifr_ifrn.ifrn_name, ifa.ifa_name, C.IFNAMSIZ)
            if C.ioctl(socket, C.SIOCGIWNAME, iwr) ~= -1 then
                -- This is a wireless interface, get its MAC address
                local ifr = ffi.new("struct ifreq")
                ffi.copy(ifr.ifr_ifrn.ifrn_name, ifa.ifa_name, C.IFNAMSIZ)
                if C.ioctl(socket, C.SIOCGIFHWADDR, ifr) ~= -1 then
                    mac_address = string.format("%02X:%02X:%02X:%02X:%02X:%02X",
                        bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[0], 0xFF),
                        bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[1], 0xFF),
                        bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[2], 0xFF),
                        bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[3], 0xFF),
                        bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[4], 0xFF),
                        bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[5], 0xFF))
                    logger.info("TRMNL: Auto-detected MAC address:", mac_address)
                    break -- Found wireless interface MAC
                end
            end
        end
        ifa = ifa.ifa_next
    end

    C.freeifaddrs(ifaddr[0])
    C.close(socket)

    if not mac_address then
        logger.info("TRMNL: No wireless interface MAC address found")
    end

    return mac_address
end

--============================================================================--
-- Network and API Methods
--
-- These methods handle:
-- - HTTP/HTTPS requests to TRMNL API
-- - JSON parsing
-- - Image downloads
-- - Error handling and retry logic
--============================================================================--

--[[--
Fetch screen metadata from TRMNL API.

Makes HTTP GET request to /api/display endpoint with headers:
- access-token: User's API key
- battery-voltage: Device battery percentage
- png-width/png-height: Screen dimensions in pixels
- rssi: WiFi signal strength (hardcoded to 0 for now)
- User-Agent: Plugin version string

@treturn table|nil Decoded JSON response table, or nil on error
]]
function TrmnlDisplay:fetchScreenMetadata()
    if not self.settings.api_key or self.settings.api_key == "" then
        self:showError("Please configure your TRMNL API key first.")
        return nil
    end

    -- LuaSocket libraries for HTTP/HTTPS requests
    local http = require("socket.http") -- HTTP protocol
    local https = require("ssl.https")  -- HTTPS/TLS protocol
    local ltn12 = require("ltn12")      -- Streaming data I/O filters
    local JSON = require("json")        -- JSON parsing

    -- ltn12.sink.table accumulates response body into a Lua table
    local sink = {}
    local request_url = self.settings.base_url .. "/api/display"

    -- Get device information for API headers
    -- Device:hasBattery() checks if device has battery capability
    -- Device:getPowerDevice() returns power device object with getCapacity() method
    local battery_voltage = "0"
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        battery_voltage = tostring(powerd:getCapacity()) -- Returns 0-100 percentage
    end

    -- Screen:getWidth()/getHeight() return pixel dimensions
    -- TRMNL uses this to generate appropriately sized images
    local png_width = tostring(Screen:getWidth())
    local png_height = tostring(Screen:getHeight())

    -- Get MAC address: manual entry wins (if not empty), otherwise auto-detect
    local mac_address
    local manual_mac = self.settings.mac_address
    if manual_mac and manual_mac ~= "" then
        -- Manual MAC provided - use it
        mac_address = manual_mac
        logger.dbg("TRMNL: Using manual MAC address:", mac_address)
    else
        -- No manual MAC or empty string - try auto-detection
        mac_address = self:getMacAddress() or "00:00:00:00:00:00"
        logger.dbg("TRMNL: Using MAC address:", mac_address)
    end

    -- Get custom header name for MAC address
    local mac_header_name = self.settings.mac_header_name or "ID"

    logger.info("TRMNL: Fetching screen from", request_url)
    logger.dbg("TRMNL: Screen dimensions:", png_width, "x", png_height)

    -- Build HTTP request table (LuaSocket format)
    local request = {
        url = request_url,
        method = "GET",
        headers = {
            ["access-token"] = self.settings.api_key,  -- TRMNL API authentication
            ["battery-voltage"] = battery_voltage,     -- Device battery level
            ["png-width"] = png_width,                 -- Screen width in pixels
            ["png-height"] = png_height,               -- Screen height in pixels
            ["rssi"] = "0",                            -- WiFi signal strength (TODO: implement)
            [mac_header_name] = mac_address,           -- MAC address with custom header name
            ["User-Agent"] = self.settings.user_agent, -- Plugin identification
        },
        sink = ltn12.sink.table(sink),                 -- Response body stored in 'sink' table
        -- SSL/TLS configuration for HTTPS
        protocol = "any",                              -- Accept any SSL/TLS version
        options = { "all", "no_sslv2", "no_sslv3" },   -- Disable insecure SSL versions
        verify = "none",                               -- Skip certificate verification (required for Kindles with outdated cert stores)
    }

    -- Choose HTTP or HTTPS based on URL scheme
    local httpx = request_url:match("^https://") and https or http
    local success_code, status_code = httpx.request(request)

    logger.dbg("TRMNL: Success code:", success_code)
    logger.dbg("TRMNL: HTTP status code:", status_code)

    if not success_code or success_code ~= 1 then
        logger.err("TRMNL: Request failed - success code:", success_code)
        local context = "Network error - check WiFi connection\nURL: " .. request_url
        self:showError(T(_("Failed to reach TRMNL API (code: %1)"), tostring(success_code)), context)
        return nil
    end

    if status_code ~= 200 then
        logger.err("TRMNL: API returned HTTP", status_code)
        local context_msg
        if status_code == 401 or status_code == 403 then
            context_msg = "Check your API key in settings"
        elseif status_code == 404 then
            context_msg = "Endpoint not found - verify base URL"
        elseif status_code >= 500 then
            context_msg = "Server error - try again later"
        else
            context_msg = "HTTP " .. tostring(status_code)
        end
        self:showError("API request failed", context_msg)
        return nil
    end

    local response_body = table.concat(sink)
    logger.dbg("TRMNL: Received response:", response_body:sub(1, 200))

    local ok, response = pcall(JSON.decode, response_body)
    if not ok or not response then
        logger.err("TRMNL: Failed to parse JSON response")
        return nil
    end

    return response
end

function TrmnlDisplay:downloadImage(image_url, filepath)
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")

    logger.info("TRMNL: Downloading image from", image_url)

    local file = io.open(filepath, "wb")
    if not file then
        logger.err("TRMNL: Failed to open file for writing:", filepath)
        return false
    end

    local request = {
        url = image_url,
        sink = ltn12.sink.file(file),
        headers = {
            ["User-Agent"] = self.settings.user_agent,
        },
        -- SSL/TLS configuration (same as API request)
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3" },
        verify = "none", -- Skip certificate verification (required for Kindles)
    }

    local httpx = image_url:match("^https://") and https or http
    local success_code, status_code = httpx.request(request)

    logger.dbg("TRMNL: Image download success code:", success_code)
    logger.dbg("TRMNL: Image download HTTP status:", status_code)

    if not success_code or success_code ~= 1 then
        logger.err("TRMNL: Image download failed - success code:", success_code)
        os.remove(filepath)
        return false
    end

    if status_code ~= 200 then
        logger.err("TRMNL: Image download failed - HTTP", status_code)
        os.remove(filepath)
        return false
    end

    logger.info("TRMNL: Image downloaded successfully")
    return true
end

function TrmnlDisplay:displayImage(image_path)
    -- NOTE: Keep old image visible while rendering new one
    -- Only close it if we successfully render the replacement
    -- This prevents empty screens during network/rendering errors

    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    logger.info("TRMNL: Rendering image", image_path)

    local image_bb = RenderImage:renderImageFile(
        image_path,
        true, -- enable caching
        screen_width,
        screen_height
    )

    if not image_bb then
        logger.err("TRMNL: Failed to render image")
        return false
    end

    -- Close previous image widget only after successfully rendering new one
    if self.image_widget then
        UIManager:close(self.image_widget)
        self.image_widget = nil
    end

    local image = ImageWidget:new {
        image = image_bb,
        image_disposable = true,
        width = screen_width,
        height = screen_height,
        alpha = true,
    }

    -- Wrap in InputContainer to handle tap events
    self.image_widget = InputContainer:new {
        dimen = {
            x = 0,
            y = 0,
            w = screen_width,
            h = screen_height,
        },
        image,
    }

    -- Add tap handler to close the image
    self.image_widget.onTapClose = function()
        logger.info("TRMNL: Closing image via tap")
        UIManager:close(self.image_widget)
        self.image_widget = nil
        return true
    end

    -- Add key press handler for non-touch devices
    self.image_widget.onAnyKeyPressed = function()
        logger.info("TRMNL: Closing image via button press")
        UIManager:close(self.image_widget)
        self.image_widget = nil
        return true
    end

    -- Register tap gesture
    if Device:isTouchDevice() then
        self.image_widget.ges_events = {
            TapClose = {
                GestureRange:new {
                    ges = "tap",
                    range = Geom:new {
                        x = 0, y = 0,
                        w = screen_width,
                        h = screen_height,
                    }
                }
            }
        }
    end

    -- Register key events for non-touch devices
    if Device:hasKeys() then
        self.image_widget.key_events = {
            AnyKeyPressed = { { Input.group.Any } }
        }
    end

    -- Add widget to UIManager's display stack
    UIManager:show(self.image_widget)

    --[[--
    E-ink refresh optimization

    E-ink displays have several refresh modes with tradeoffs:
    - "ui": Balanced speed/quality (default)
    - "full": Slowest but best quality, clears ghosting
    - "flashui": With screen flash for better contrast
    - "partial": Fastest but may cause ghosting
    ]]
    local refresh_type = self.settings.refresh_type or "ui"
    logger.info("TRMNL: Applying refresh type:", refresh_type)

    -- UIManager:setDirty() marks widget for screen update with specified refresh mode
    -- This triggers the e-ink controller to redraw the widget's area
    UIManager:setDirty(self.image_widget, refresh_type)

    logger.info("TRMNL: Image displayed")
    return true
end

--============================================================================--
-- Helper Methods
--============================================================================--

--[[--
Smart notification system - shows informative messages without overwhelming.

Types: "error", "info", "success", "progress"
Can be toggled on/off via settings.show_notifications
@tparam string message Main message text
@tparam table opts Optional: {type, context, timeout, force}
]]
function TrmnlDisplay:notify(message, opts)
    opts = opts or {}
    local msg_type = opts.type or "info"
    local context = opts.context

    -- Always log, even if notifications disabled
    logger.info("TRMNL [" .. msg_type .. "]: " .. message)
    if context then
        logger.dbg("TRMNL Context: " .. context)
    end

    -- Skip showing notification if disabled (unless force = true)
    -- Always show errors though, they're important
    if not self.settings.show_notifications and msg_type ~= "error" and not opts.force then
        return
    end

    local timeout
    if opts.timeout then
        timeout = opts.timeout
    elseif msg_type == "error" then
        timeout = 5
    elseif msg_type == "progress" then
        timeout = 3
    else
        timeout = 2
    end

    local full_message = _(message)
    if context and context ~= "" then
        full_message = full_message .. "\n\n" .. context
    end

    local prefix = ""
    if msg_type == "error" then
        prefix = "⚠ "
    elseif msg_type == "success" then
        prefix = "✓ "
    elseif msg_type == "progress" then
        prefix = "⟳ "
    end

    UIManager:show(InfoMessage:new {
        text = prefix .. full_message,
        timeout = timeout,
    })
end

function TrmnlDisplay:showError(message, context)
    self:notify(message, { type = "error", context = context })
end

function TrmnlDisplay:showInfo(message)
    self:notify(message, { type = "info" })
end

function TrmnlDisplay:showSuccess(message)
    self:notify(message, { type = "success" })
end

function TrmnlDisplay:showProgress(message, context)
    self:notify(message, { type = "progress", context = context })
end

--[[--
Unschedule any pending refresh task.

Safely removes any scheduled refresh task and updates the flag.
Safe to call even if no task is scheduled.
]]
function TrmnlDisplay:unscheduleRefreshTask()
    if self.refresh_task then
        UIManager:unschedule(self.refresh_task)
        self.auto_refresh_scheduled = false
        logger.dbg("TRMNL: Unscheduled refresh task")
    end
end

--[[--
Prevent device from automatically suspending (sleeping).

Uses KOReader's standby prevention API to keep device awake while auto-refresh is active.
This ensures the dashboard remains visible and refreshes continue.
Works on all devices (Kindle, Kobo, PocketBook, etc.).
]]
function TrmnlDisplay:preventAutoSuspend()
    UIManager:preventStandby()
    logger.info("TRMNL: Device sleep prevented (auto-refresh active)")
end

--[[--
Re-enable device auto-suspend (sleeping).

Restores normal power management behavior when auto-refresh is disabled.
]]
function TrmnlDisplay:allowAutoSuspend()
    UIManager:allowStandby()
    logger.info("TRMNL: Device sleep re-enabled (normal behavior)")
end

--[[--
Schedule the next refresh if auto-refresh is enabled.

Uses the configured refresh_interval to schedule the next fetch cycle.
Unschedules any existing pending task to prevent double-scheduling.
]]
function TrmnlDisplay:scheduleNextRefresh()
    if not self.auto_refresh_enabled then
        logger.info("TRMNL: Auto-refresh disabled, not scheduling")
        return
    end

    self:unscheduleRefreshTask()

    local interval = self.settings.refresh_interval or self.CONSTANTS.TIMING.DEFAULT_REFRESH_INTERVAL
    logger.info("TRMNL: Scheduling next refresh in", interval, "seconds")
    UIManager:scheduleIn(interval, self.refresh_task)
    self.auto_refresh_scheduled = true
end

--[[--
Check if scheduling state is valid.
@treturn boolean true if state is valid
]]
function TrmnlDisplay:isScheduleStateValid()
    if self.auto_refresh_enabled then
        return self.auto_refresh_scheduled
    else
        return not self.auto_refresh_scheduled
    end
end

--[[--
Validate and fix scheduling state.
Ensures exactly one task when enabled, zero tasks when disabled.
]]
function TrmnlDisplay:validateAndFixScheduleState()
    if self:isScheduleStateValid() then
        return
    end

    if self.auto_refresh_enabled then
        logger.warn("TRMNL: Auto-refresh enabled but no task scheduled - fixing!")
        self:scheduleNextRefresh()
    else
        logger.warn("TRMNL: Auto-refresh disabled but task still scheduled - fixing!")
        self:unscheduleRefreshTask()
    end
end

--[[--
Handle fetch errors with exponential backoff retry logic.

Increments retry counter, shows user notification,
and schedules retry if auto-refresh is enabled.

@tparam string error_message User-friendly error description
]]
function TrmnlDisplay:handleFetchError(error_message)
    local retry_delay = self.retry_manager:increment()

    logger.err("TRMNL:", error_message, "(attempt", self.retry_manager.count, ")")
    self:showError(T(_("Failed: %1. Will retry in %2 seconds."), _(error_message), retry_delay))

    -- NOTE: afterWifiAction will be called by the caller to clean up WiFi

    if self.auto_refresh_enabled then
        logger.info("TRMNL: Scheduling retry in", retry_delay, "seconds")
        UIManager:scheduleIn(retry_delay, self.refresh_task)
    end
end

--[[--
Update refresh interval from server response if configured to do so.

@tparam table response API response containing optional refresh_rate field
]]
function TrmnlDisplay:updateRefreshInterval(response)
    if not self.settings.use_server_refresh_rate or not response.refresh_rate then
        return
    end

    local new_interval = tonumber(response.refresh_rate)
    if new_interval and new_interval > 0 then
        logger.info("TRMNL: Using server refresh rate:", new_interval, "seconds")
        self.settings.refresh_interval = new_interval
        self:saveSettings()
    end
end

--[[--
Download screen image if it has changed since last fetch.

Compares filename to detect changes. If unchanged, uses cached file.
If changed, downloads new image and updates cache tracking.
Automatically deletes old image file to prevent accumulation.

@tparam table response API response containing image_url and filename
@treturn string|nil Path to image file, or nil on download failure
]]
function TrmnlDisplay:downloadImageIfNeeded(response)
    local filename = response.filename or self.CONSTANTS.FILES.DEFAULT_IMAGE
    if not filename:match("%.png$") then
        filename = filename .. ".png"
    end

    local image_path = DataStorage:getDataDir() .. "/" .. filename

    -- Check if image has changed
    if filename == self.last_image_filename then
        logger.info("TRMNL: Image unchanged, using cached file:", image_path)
        return image_path
    end

    -- Image changed, clean up old file before downloading new one
    logger.info("TRMNL: Image changed, downloading:", filename)
    self:showProgress("Downloading new screen...", filename)

    if self.last_image_path and self.last_image_path ~= image_path then
        logger.info("TRMNL: Removing old image file:", self.last_image_path)
        local success = os.remove(self.last_image_path)
        if success then
            logger.dbg("TRMNL: Old image file deleted successfully")
        else
            logger.warn("TRMNL: Could not delete old image file (may not exist)")
        end
    end

    -- Download new image
    if not self:downloadImage(response.image_url, image_path) then
        return nil -- Download failed
    end

    -- Update cache tracking
    self.last_image_path = image_path
    self.last_image_filename = filename
    return image_path
end

--[[--
Check debounce timing to prevent rapid API calls.
@treturn boolean true if check passed, false if debouncing
]]
function TrmnlDisplay:checkDebounce(skip_debounce)
    if skip_debounce then
        return true
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    local time_since_last = now - self.last_fetch_timestamp

    if time_since_last <= self.CONSTANTS.TIMING.DEBOUNCE_DELAY then
        logger.dbg("TRMNL: Debouncing - last fetch", time_since_last, "seconds ago")
        return false
    end

    self.last_fetch_timestamp = now
    return true
end

--[[--
Finalize successful fetch - cleanup, reset state, and schedule next refresh.
]]
function TrmnlDisplay:finalizeFetchSuccess(image_path)
    self:displayImage(image_path)
    logger.info("TRMNL: Fetch and display completed successfully")

    self:showSuccess("Screen updated successfully")

    -- Clean up WiFi using KOReader's framework
    NetworkMgr:afterWifiAction()

    self.retry_manager:reset()

    self:scheduleNextRefresh()
    self:validateAndFixScheduleState()
end

--[[--
Main workflow - fetches screen from API and displays it.

Called by user action, auto-refresh timer, or network availability callback.
Uses pipeline pattern for clear flow control and early exits on errors.
]]
function TrmnlDisplay:fetchAndDisplay(skip_debounce)
    logger.info("TRMNL: Starting fetch and display cycle")

    if not self:checkDebounce(skip_debounce) then
        return
    end

    -- Use KOReader's WiFi management framework
    -- runWhenConnected will turn on WiFi if needed and wait for connection
    NetworkMgr:runWhenConnected(function()
        self:_doFetchAndDisplay()
    end)
end

--[[--
Internal fetch implementation that runs after WiFi is confirmed connected.
Separated from fetchAndDisplay to work with NetworkMgr:runWhenConnected().

Includes a small delay after WiFi connection to ensure the network stack is fully ready
for HTTP requests, as some devices report "connected" before being able to make requests.
]]
function TrmnlDisplay:_doFetchAndDisplay()
    -- Give WiFi a moment to fully stabilize after connection
    -- This prevents "connected but not really" issues on some devices
    logger.info("TRMNL: WiFi connected, waiting 2 seconds for network to stabilize...")
    UIManager:scheduleIn(2, function()
        self:_performFetch()
    end)
end

--[[--
Perform the actual fetch and display after WiFi is ready.
]]
function TrmnlDisplay:_performFetch()
    local response = self:fetchScreenMetadata()
    if not response or not response.image_url then
        self:handleFetchError("Failed to fetch screen metadata")
        NetworkMgr:afterWifiAction()
        return
    end

    self:updateRefreshInterval(response)

    local image_path = self:downloadImageIfNeeded(response)
    if not image_path then
        self:handleFetchError("Failed to download image")
        NetworkMgr:afterWifiAction()
        return
    end

    self:finalizeFetchSuccess(image_path)
end

--============================================================================--
-- Auto-Refresh Control
--
-- These methods start/stop the automatic refresh cycle.
-- Called by menu actions and lifecycle hooks.
--============================================================================--

--[[--
Start auto-refresh cycle.

Called by:
- User selecting "Enable auto-refresh" menu item
- Plugin init() if auto-refresh was previously enabled

Flow:
1. Enable auto-refresh flag
2. Save state to disk
3. Fetch and display immediately (no delay for first refresh)
4. fetchAndDisplay() will schedule subsequent refreshes
]]
function TrmnlDisplay:startAutoRefresh()
    if self.auto_refresh_enabled and self.auto_refresh_scheduled then
        logger.info("TRMNL: Auto-refresh already active")
        return
    end

    logger.info("TRMNL: Starting auto-refresh")

    -- NOTE: Ensure clean state before starting
    self:unscheduleRefreshTask()

    self.auto_refresh_enabled = true
    self.auto_refresh_scheduled = false -- Will be set to true after first fetch schedules next
    self:saveSettings()                 -- Persist across KOReader restarts

    -- Prevent device from sleeping while displaying dashboard
    self:preventAutoSuspend()

    self:showProgress("Starting auto-refresh...", "Fetching first screen")

    -- Start immediately - will display the image and schedule next refresh
    self:fetchAndDisplay()

    logger.dbg("TRMNL: Auto-refresh started, initial fetch triggered")
end

--[[--
Stop auto-refresh cycle.

Called by:
- User selecting "Disable auto-refresh" menu item
- Device lifecycle events (suspend, plugin close)

Unschedules any pending refresh tasks using UIManager:unschedule().
]]
function TrmnlDisplay:stopAutoRefresh()
    if not self.auto_refresh_enabled then
        logger.dbg("TRMNL: Auto-refresh already stopped")
        return
    end

    logger.info("TRMNL: Stopping auto-refresh")

    -- NOTE: Unschedule first to ensure clean state
    self:unscheduleRefreshTask()

    self.auto_refresh_enabled = false
    self.auto_refresh_scheduled = false
    self:saveSettings() -- Persist across KOReader restarts

    -- Re-enable device sleep
    self:allowAutoSuspend()

    logger.dbg("TRMNL: Auto-refresh stopped, all tasks unscheduled")
end

--============================================================================--
-- Lifecycle Handlers
--
-- These are lifecycle hooks called automatically by KOReader:
-- - onSuspend: Called when device is about to sleep
-- - onResume: Called when device wakes from sleep
-- - onCloseWidget: Called when plugin is disabled or KOReader exits
--
-- Proper lifecycle handling ensures:
-- - Tasks don't run while device is suspended (saves battery)
-- - Fresh data is fetched immediately on wake
-- - No resource leaks when plugin is disabled
--============================================================================--

--[[--
Device is suspending (going to sleep).

Unschedule refresh task to prevent it running during sleep.
]]
function TrmnlDisplay:onSuspend()
    if self.auto_refresh_enabled then
        self:unscheduleRefreshTask()
    end
end

--[[--
Device is resuming (waking from sleep).

If auto-refresh is enabled, fetch immediately rather than waiting for the
scheduled interval. This ensures fresh data after potentially long sleep periods.
Unschedules any pending task first to prevent double-refresh.

NOTE: If auto_restore_wifi is enabled, skip immediate fetch to prevent duplicate
network events and connection UI popups. The WiFi will be auto-restored and we'll
wait for the next scheduled refresh instead.
]]
function TrmnlDisplay:onResume()
    if Device:hasWifiRestore() and NetworkMgr.wifi_was_on and
        G_reader_settings:isTrue("auto_restore_wifi") then
        if self.auto_refresh_enabled then
            self:validateAndFixScheduleState()
        end
        return
    end

    if not self.auto_refresh_enabled then
        return
    end

    self:unscheduleRefreshTask()
    self:fetchAndDisplay()
end

--[[--
Plugin is being disabled or KOReader is exiting.

Clean up:
- Stop auto-refresh cycle
- Close any displayed image widgets
- Settings are automatically flushed by onFlushSettings()
]]
function TrmnlDisplay:onCloseWidget()
    logger.dbg("TRMNL: Plugin closing")
    self:stopAutoRefresh()
    if self.image_widget then
        UIManager:close(self.image_widget)
        self.image_widget = nil
    end
end

--============================================================================--
-- UI Configuration
--
-- These methods create and manage user interface elements:
-- - Configuration dialogs for settings
-- - Main menu integration
-- - Submenus for advanced options
--
-- KOReader UI Components Used:
-- - MultiInputDialog: Multiple text/number fields in one dialog
-- - InfoMessage: Temporary notification pop-ups
-- - menu_items table: Hierarchical menu structure
-- - text_func: Dynamic menu text based on state
-- - checked_func: Radio button/checkbox state
--============================================================================--

--[[--
Show configuration dialog for basic settings.

Uses MultiInputDialog which provides multiple input fields in one dialog:
- API Key (password-masked text input)
- Base URL (text input)
- Refresh Interval (number input)

Fields are retrieved via getFields() which returns array of values in order.
]]
function TrmnlDisplay:showConfigDialog()
    -- Get auto-detected MAC to show as placeholder/hint
    local auto_mac = self:getMacAddress() or "Auto-detect unavailable"
    local mac_hint = auto_mac ~= "Auto-detect unavailable"
        and _("MAC address (leave empty to use:") .. auto_mac .. ")"
        or _("MAC address (auto-detect unavailable)")

    self.config_dialog = MultiInputDialog:new {
        title = _("Configure TRMNL"),
        fields = {
            {
                text = self.settings.api_key or "",
                hint = _("Enter your TRMNL API key"),
                input_type = "string",
                password = true,
            },
            {
                text = self.settings.base_url or "https://trmnl.app",
                hint = _("TRMNL base URL"),
                input_type = "string",
            },
            {
                text = tostring(self.settings.refresh_interval or 1800),
                hint = _("Refresh interval (seconds)"),
                input_type = "number",
            },
            {
                text = self.settings.mac_header_name or "MAC address",
                hint = _("MAC address header name (e.g. ID)"),
                input_type = "string",
            },
            {
                text = self.settings.mac_address or "",
                hint = mac_hint,
                input_type = "string",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.config_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.config_dialog:getFields()
                        self.settings.api_key = fields[1]
                        self.settings.base_url = fields[2]
                        self.settings.refresh_interval = tonumber(fields[3]) or 1800
                        self.settings.mac_header_name = fields[4]
                        self.settings.mac_address = fields[5] ~= "" and fields[5] or nil
                        self:saveSettings()
                        UIManager:close(self.config_dialog)
                        self:showInfo("TRMNL settings saved.")
                    end,
                },
            },
        },
    }

    UIManager:show(self.config_dialog)
end

--============================================================================--
-- Menu Builders
--============================================================================--

--[[--
Create a toggle menu item that switches between two states.
@tparam string label_when_on Text to show when currently on
@tparam string label_when_off Text to show when currently off
@tparam function getter Function that returns current state (boolean)
@tparam function toggler Function called to toggle state, should return success message
@treturn table Menu item configuration
]]
function TrmnlDisplay:createToggleMenuItem(label_when_on, label_when_off, getter, toggler)
    return {
        text_func = function()
            return getter() and _(label_when_on) or _(label_when_off)
        end,
        callback = function()
            local message = toggler()
            if message then
                UIManager:show(InfoMessage:new {
                    text = _(message),
                    timeout = 2,
                })
            end
        end
    }
end

--[[--
Create a radio button menu item for exclusive choices.
@tparam string label Display text
@tparam string setting_key Settings key to check/update
@tparam string value Value to compare and set
@treturn table Menu item configuration
]]
function TrmnlDisplay:createRadioMenuItem(label, setting_key, value)
    return {
        text = _(label),
        checked_func = function()
            return self.settings[setting_key] == value
        end,
        callback = function()
            self.settings[setting_key] = value
            self:saveSettings()
        end
    }
end

--[[--
Create menu item constructors for each feature.
]]
function TrmnlDisplay:createFetchMenuItem()
    return {
        text = _("Fetch screen now"),
        callback = function()
            self:fetchAndDisplay(true)
        end
    }
end

function TrmnlDisplay:createConfigMenuItem()
    return {
        text = _("Configure TRMNL"),
        keep_menu_open = true,
        callback = function()
            self:showConfigDialog()
        end
    }
end

function TrmnlDisplay:createAutoRefreshToggle()
    return self:createToggleMenuItem(
        "Disable auto-refresh",
        "Enable auto-refresh",
        function() return self.auto_refresh_enabled end,
        function()
            if self.auto_refresh_enabled then
                self:stopAutoRefresh()
                return "Auto-refresh disabled."
            else
                self:startAutoRefresh()
                return "Auto-refresh enabled."
            end
        end
    )
end

function TrmnlDisplay:createServerRefreshToggle()
    return self:createToggleMenuItem(
        "Use manual refresh interval",
        "Use server refresh interval",
        function() return self.settings.use_server_refresh_rate end,
        function()
            self.settings.use_server_refresh_rate = not self.settings.use_server_refresh_rate
            self:saveSettings()
            return self.settings.use_server_refresh_rate
                and "Will use server's recommended refresh interval"
                or "Will use your manual refresh interval"
        end
    )
end

function TrmnlDisplay:createNotificationsToggle()
    return self:createToggleMenuItem(
        "Hide status notifications",
        "Show status notifications",
        function() return self.settings.show_notifications end,
        function()
            self.settings.show_notifications = not self.settings.show_notifications
            self:saveSettings()
            return self.settings.show_notifications
                and "Status notifications enabled (errors always shown)"
                or "Status notifications hidden (errors still shown)"
        end
    )
end

--============================================================================--
-- Menu Integration
--============================================================================--

--[[--
Register plugin in KOReader's main menu.
]]
function TrmnlDisplay:addToMainMenu(menu_items)
    menu_items.trmnl = {
        text = _("TRMNL Display"),
        sorting_hint = "tools",
        sub_item_table = {
            self:createFetchMenuItem(),
            self:createConfigMenuItem(),
            self:createAutoRefreshToggle(),
            self:createServerRefreshToggle(),
            self:createNotificationsToggle(),
            {
                text = _("E-ink refresh type"),
                sub_item_table = {
                    self:createRadioMenuItem("UI (balanced)", "refresh_type", "ui"),
                    self:createRadioMenuItem("Full (best quality)", "refresh_type", "full"),
                    self:createRadioMenuItem("Flash UI (with flash)", "refresh_type", "flashui"),
                    self:createRadioMenuItem("Partial (fastest)", "refresh_type", "partial"),
                }
            },
        }
    }
end

return TrmnlDisplay
