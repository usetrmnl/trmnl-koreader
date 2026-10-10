--[[--
Runs inside KOReader's busted suite. From a KOReader checkout with this plugin
and this spec symlinked in (plugins/trmnl.koplugin, spec/unit/trmnl_spec.lua):

    ./kodev test --busted front spec/front/unit/trmnl_spec.lua

Covers the /api/display outcomes that matter: the API reports device and token
problems as HTTP 200 with an error body, so "no image_url" is the only signal
the plugin gets, and it has to say something useful about it.
]]

describe("TRMNL display plugin", function()
    local TrmnlDisplay

    setup(function()
        require("commonrequire")
        require("ui/network/manager").afterWifiAction = function() end
        TrmnlDisplay = dofile("plugins/trmnl.koplugin/main.lua")
    end)

    -- Drives the real _performFetch with a canned API response and returns the
    -- message the user would have been shown.
    local function message_for(response, image_path, download_error)
        local seen
        local instance = setmetatable({
            fetchScreenMetadata   = function() return response end,
            handleFetchError      = function(_, msg) seen = msg end,
            updateRefreshInterval = function() end,
            downloadImageIfNeeded = function() return image_path, download_error end,
            finalizeFetchSuccess  = function() end,
        }, { __index = TrmnlDisplay })

        instance:_performFetch()
        return seen
    end

    it("surfaces the server's error text", function()
        assert.is_equal("Device not found",
            message_for({ status = 500, error = "Device not found" }))
    end)

    it("falls back to the status when the body carries no error text", function()
        assert.is_equal("status 500", message_for({ status = 500 }))
    end)

    it("stays generic when the request itself failed", function()
        assert.is_equal("Failed to fetch screen metadata", message_for(nil))
    end)

    it("stays generic for an empty body", function()
        assert.is_equal("Failed to fetch screen metadata", message_for({}))
    end)

    it("leaves download failures to the download path", function()
        assert.is_equal("Failed to download image",
            message_for({ image_url = "https://example.invalid/a.png" }, nil))
    end)

    it("says why the image download failed", function()
        assert.is_equal("Failed to download image: host not found",
            message_for({ image_url = "http://truenas.local/a.png" }, nil, "host not found"))
    end)

    -- Captures the headers of a real fetchScreenMetadata call by standing in for
    -- the HTTPS transport. The response never parses, which is fine - only the
    -- outgoing request is under test.
    local function headers_for(settings, detected_mac, rssi)
        local captured
        local real_https = package.loaded["ssl.https"]
        package.loaded["ssl.https"] = {
            request = function(request) captured = request; return 1, 200 end,
        }

        settings.api_key = "test-key"
        settings.base_url = "https://example.invalid"
        local instance = setmetatable({
            settings      = settings,
            getMacAddress = function() return detected_mac end,
            getRssi       = function() return rssi end,
            showError     = function() end,
        }, { __index = TrmnlDisplay })

        instance:fetchScreenMetadata()
        package.loaded["ssl.https"] = real_https
        return captured.headers
    end

    it("sends the detected MAC under the ID header by default", function()
        assert.is_equal("AA:BB:CC:DD:EE:FF", headers_for({}, "AA:BB:CC:DD:EE:FF")["ID"])
    end)

    it("omits the header entirely when no MAC can be detected", function()
        assert.is_nil(headers_for({}, nil)["ID"])
    end)

    it("prefers a manually configured MAC over the detected one", function()
        local headers = headers_for({ mac_address = "11:22:33:44:55:66" }, "AA:BB:CC:DD:EE:FF")
        assert.is_equal("11:22:33:44:55:66", headers["ID"])
    end)

    it("honours a custom header name for BYOS servers", function()
        local headers = headers_for({ mac_header_name = "MAC Address" }, "AA:BB:CC:DD:EE:FF")
        assert.is_equal("AA:BB:CC:DD:EE:FF", headers["MAC Address"])
        assert.is_nil(headers["ID"])
    end)

    it("shows why a request could not reach the server", function()
        local seen
        local real_http = package.loaded["socket.http"]
        package.loaded["socket.http"] = {
            request = function() return nil, "host or service not provided, or not known" end,
        }
        local instance = setmetatable({
            settings  = { api_key = "test-key", base_url = "http://truenas.local:4567" },
            showError = function(_, msg) seen = msg end,
        }, { __index = TrmnlDisplay })

        instance:fetchScreenMetadata()
        package.loaded["socket.http"] = real_http
        assert.matches("host or service not provided", seen)
    end)

    describe("auto-refresh", function()
        local NetworkMgr, UIManager

        setup(function()
            NetworkMgr = require("ui/network/manager")
            UIManager = require("ui/uimanager")
        end)

        local function is_scheduled(task)
            for _, item in ipairs(UIManager._task_queue) do
                if item.action == task then return true end
            end
            return false
        end

        it("books the next attempt when Wi-Fi never connects", function()
            -- A failed connection drops the callback, which is what this stub does.
            stub(NetworkMgr, "runWhenConnected")
            local instance = setmetatable({
                auto_refresh_enabled = true,
                retry_manager = { increment = function() return 120 end },
                refresh_task = function() end,
            }, { __index = TrmnlDisplay })

            instance:fetchAndDisplay()
            NetworkMgr.runWhenConnected:revert()
            local scheduled = is_scheduled(instance.refresh_task)
            UIManager:unschedule(instance.refresh_task)
            assert.is_true(scheduled)
        end)
    end)

    it("sends the measured signal level", function()
        assert.is_equal("-56", headers_for({}, nil, -56)["rssi"])
    end)

    it("omits rssi when the signal level is unknown", function()
        assert.is_nil(headers_for({}, nil, nil)["rssi"])
    end)

    it("sends whether the battery is charging", function()
        local Device = require("device")
        stub(Device, "getPowerDevice", { getCapacity = function() return 80 end, isCharging = function() return true end })
        local headers = headers_for({}, nil, nil)
        Device.getPowerDevice:revert()
        assert.is_equal("true", headers["battery-charging"])
    end)

    describe("getRssi", function()
        local function rssi_from(level)
            local path = os.tmpname()
            local file = io.open(path, "w")
            file:write("Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n",
                       " face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n",
                       " wlan0: 0000   54.  " .. level .. ".  -256        0      0      0      0      0        0\n")
            file:close()
            local rssi = TrmnlDisplay:getRssi(path)
            os.remove(path)
            return rssi
        end

        it("reads the wireless interface level in dBm", function()
            assert.is_equal(-56, rssi_from("-56"))
        end)

        it("ignores a level that is not in dBm", function()
            assert.is_nil(rssi_from("200"))
        end)

        it("returns nil without wireless statistics", function()
            assert.is_nil(TrmnlDisplay:getRssi("/nonexistent/wireless"))
        end)
    end)

    describe("request timeouts", function()
        local socketutil

        setup(function()
            socketutil = require("socketutil")
        end)

        local function block_timeout_during(call)
            local seen
            local real_http = package.loaded["socket.http"]
            package.loaded["socket.http"] = {
                request = function() seen = socketutil.block_timeout; return nil, "timeout" end,
            }
            call(setmetatable({
                settings  = { api_key = "test-key", base_url = "http://example.invalid" },
                showError = function() end,
            }, { __index = TrmnlDisplay }))
            package.loaded["socket.http"] = real_http
            return seen
        end

        it("bounds the screen request", function()
            assert.is_equal(socketutil.LARGE_BLOCK_TIMEOUT,
                block_timeout_during(function(instance) instance:fetchScreenMetadata() end))
        end)

        it("bounds the image download", function()
            local path = os.tmpname()
            local timeout = block_timeout_during(function(instance)
                instance:downloadImage("http://example.invalid/a.png", path)
            end)
            os.remove(path)
            assert.is_equal(socketutil.FILE_BLOCK_TIMEOUT, timeout)
        end)

        it("restores the default timeout afterwards", function()
            block_timeout_during(function(instance) instance:fetchScreenMetadata() end)
            assert.is_equal(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
        end)
    end)

    describe("dashboard gestures", function()
        local Device, Geom, RenderImage, UIManager

        setup(function()
            Device = require("device")
            Geom = require("ui/geometry")
            RenderImage = require("ui/renderimage")
            UIManager = require("ui/uimanager")
        end)

        before_each(function()
            stub(Device, "isTouchDevice", true)
            stub(RenderImage, "renderImageFile", function()
                return require("ffi/blitbuffer").new(Device.screen:getWidth(), Device.screen:getHeight())
            end)
            stub(UIManager, "show")
            stub(UIManager, "close")
            stub(UIManager, "setDirty")
        end)

        after_each(function()
            Device.isTouchDevice:revert()
            RenderImage.renderImageFile:revert()
            UIManager.show:revert()
            UIManager.close:revert()
            UIManager.setDirty:revert()
        end)

        local function dashboard(close_gesture)
            local instance = setmetatable({
                settings = { close_gesture = close_gesture },
                fetches = 0,
                onTrmnlFetch = function(self) self.fetches = self.fetches + 1 end,
            }, { __index = TrmnlDisplay })
            instance:displayImage("dashboard.png")
            return instance
        end

        local function send(instance, ges)
            instance.image_widget:onGesture({ ges = ges, pos = Geom:new{ x = 10, y = 10 } })
        end

        it("closes on tap for installs without the setting", function()
            local instance = dashboard(nil)
            send(instance, "tap")
            assert.is_nil(instance.image_widget)
        end)

        it("fetches a new screen on tap and stays open when hold closes it", function()
            local instance = dashboard("hold")
            send(instance, "tap")
            assert.is_equal(1, instance.fetches)
            assert.is_not_nil(instance.image_widget)
        end)

        it("closes on hold when hold is the close gesture", function()
            local instance = dashboard("hold")
            send(instance, "hold")
            assert.is_nil(instance.image_widget)
        end)

        it("goes back to tap closing when chosen from the menu", function()
            local instance = setmetatable({ settings = { close_gesture = "hold" }, saveSettings = function() end },
                { __index = TrmnlDisplay })
            local menu = {}
            instance:addToMainMenu(menu)
            for _, item in ipairs(menu.trmnl.sub_item_table) do
                if item.text == "Dashboard gestures" then item.sub_item_table[1].callback() end
            end
            instance:displayImage("dashboard.png")
            send(instance, "tap")
            assert.is_nil(instance.image_widget)
        end)
    end)
end)
