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

    it("shows one message saying why a request could not reach the server", function()
        local shown = {}
        local real_http = package.loaded["socket.http"]
        package.loaded["socket.http"] = {
            request = function() return nil, "host or service not provided, or not known" end,
        }
        local instance = setmetatable({
            settings  = { api_key = "test-key", base_url = "http://truenas.local:4567" },
            auto_refresh_enabled = true,
            retry_manager = { count = 1, getDelay = function() return 120 end },
            showError = function(_, message) table.insert(shown, message) end,
        }, { __index = TrmnlDisplay })

        instance:_performFetch()
        package.loaded["socket.http"] = real_http
        assert.same({ "Failed to reach the server: host or service not provided, or not known. Will retry in 120 seconds." }, shown)
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

        it("books the next refresh when Wi-Fi restores itself after sleep", function()
            local Device = require("device")
            stub(Device, "hasWifiRestore", true)
            local wifi_was_on, auto_restore = NetworkMgr.wifi_was_on, G_reader_settings:readSetting("auto_restore_wifi")
            NetworkMgr.wifi_was_on = true
            G_reader_settings:saveSetting("auto_restore_wifi", true)
            local instance = setmetatable({
                auto_refresh_enabled = true,
                settings = { refresh_interval = 900 },
                refresh_task = function() end,
            }, { __index = TrmnlDisplay })

            instance:onResume()
            Device.hasWifiRestore:revert()
            NetworkMgr.wifi_was_on = wifi_was_on
            G_reader_settings:saveSetting("auto_restore_wifi", auto_restore)
            local scheduled = is_scheduled(instance.refresh_task)
            UIManager:unschedule(instance.refresh_task)
            assert.is_true(scheduled)
        end)
    end)

    it("identifies the running plugin version even when old settings saved another", function()
        local headers = headers_for({ user_agent = "trmnl-display/0.1.0-koreader" }, nil, nil)
        assert.is_equal(TrmnlDisplay.USER_AGENT, headers["User-Agent"])
    end)

    it("sends the measured signal level", function()
        assert.is_equal("-56", headers_for({}, nil, -56)["rssi"])
    end)

    it("omits rssi when the signal level is unknown", function()
        assert.is_nil(headers_for({}, nil, nil)["rssi"])
    end)

    local function charging_header(charging)
        local Device = require("device")
        stub(Device, "getPowerDevice", { getCapacity = function() return 80 end, isCharging = function() return charging end })
        local headers = headers_for({}, nil, nil)
        Device.getPowerDevice:revert()
        return headers["battery-charging"]
    end

    it("sends 1 when the battery is charging", function()
        assert.is_equal("1", charging_header(true))
    end)

    it("sends 0 when the battery is not charging", function()
        assert.is_equal("0", charging_header(false))
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

        it("reads an unsigned level as dBm, as older Kindle drivers report it", function()
            -- Kindle Paperwhite 1 (AR6000): 192 is -64 dBm, which iwconfig shows.
            assert.is_equal(-64, rssi_from("192"))
        end)

        it("ignores a level too small to be dBm", function()
            assert.is_nil(rssi_from("31"))
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
            stub(Device, "hasKeys", true)
            stub(RenderImage, "renderImageFile", function()
                return require("ffi/blitbuffer").new(Device.screen:getWidth(), Device.screen:getHeight())
            end)
            stub(UIManager, "show")
            stub(UIManager, "close")
            stub(UIManager, "setDirty")
        end)

        after_each(function()
            Device.isTouchDevice:revert()
            Device.hasKeys:revert()
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

        it("stops refreshing when the dashboard is closed", function()
            local instance = dashboard(nil)
            instance.auto_refresh_enabled = true
            send(instance, "tap")
            assert.is_false(instance.auto_refresh_enabled)
        end)

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

        local function press(instance, key_name)
            local Key = require("device/key")
            instance.image_widget:onKeyPress(Key:new(key_name, {}))
        end

        it("fetches the next screen on a page key and stays open", function()
            local instance = dashboard(nil)
            press(instance, "RPgFwd")
            assert.is_equal(1, instance.fetches)
            assert.is_not_nil(instance.image_widget)
        end)

        it("closes on any other key", function()
            local instance = dashboard(nil)
            press(instance, "Back")
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

    it("follows the server's refresh rate", function()
        local instance = setmetatable({ settings = { refresh_interval = 1800 }, saveSettings = function() end },
            { __index = TrmnlDisplay })
        instance:updateRefreshInterval({ refresh_rate = 600 })
        assert.is_equal(600, instance.settings.refresh_interval)
    end)

    it("saves each connection setting from the form", function()
        local UIManager = require("ui/uimanager")
        stub(UIManager, "show")
        stub(UIManager, "close")
        local instance = setmetatable({
            settings = {}, getMacAddress = function() return nil end,
            saveSettings = function() end, showInfo = function() end,
        }, { __index = TrmnlDisplay })
        instance:showConfigDialog()
        local typed = { "key-123", "http://192.168.1.7:2300", "MAC", "AA:BB:CC:DD:EE:FF" }
        for index, text in ipairs(typed) do instance.config_dialog.input_fields[index]:setText(text) end
        for _, row in ipairs(instance.config_dialog.buttons) do
            for _, button in ipairs(row) do if button.text == "Save" then button.callback() end end
        end
        UIManager.show:revert()
        UIManager.close:revert()
        assert.same({ "key-123", "http://192.168.1.7:2300", "MAC", "AA:BB:CC:DD:EE:FF" },
            { instance.settings.api_key, instance.settings.base_url, instance.settings.mac_header_name, instance.settings.mac_address })
    end)

    it("puts itself first in the Tools tab, once", function()
        TrmnlDisplay:pinToTopOfTools()
        TrmnlDisplay:pinToTopOfTools()
        for _, order_module in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
            local tools = require(order_module).tools
            local count = 0
            for _, id in ipairs(tools) do if id == "trmnl" then count = count + 1 end end
            assert.same({ "trmnl", 1 }, { tools[1], count })
        end
    end)

    describe("screens on disk", function()
        local DataStorage, lfs, data_dir

        setup(function()
            DataStorage = require("datastorage")
            lfs = require("libs/libkoreader-lfs")
        end)

        before_each(function()
            data_dir = os.tmpname()
            os.remove(data_dir)
            lfs.mkdir(data_dir)
            stub(DataStorage, "getDataDir", data_dir)
        end)

        after_each(function()
            DataStorage.getDataDir:revert()
            os.execute("rm -rf '" .. data_dir .. "'")
        end)

        local function files_in(dir)
            local names = {}
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then table.insert(names, name) end
            end
            table.sort(names)
            return names
        end

        local function touch(path) local file = io.open(path, "w"); file:write("png"); file:close() end

        it("keeps only the newest screen", function()
            local instance = setmetatable({
                showProgress = function() end,
                downloadImage = function(_, _, path) touch(path) return true end,
            }, { __index = TrmnlDisplay })
            instance:downloadImageIfNeeded({ image_url = "https://example.invalid/1", filename = "plugin-ab12-1" })
            instance:downloadImageIfNeeded({ image_url = "https://example.invalid/2", filename = "plugin-ab12-2" })
            assert.same({ "plugin-ab12-2.png" }, files_in(data_dir .. "/trmnl-screens"))
        end)

        it("clears screens older versions left in the data folder and nothing else", function()
            for _, name in ipairs({ "plugin-ab12cd-1761612285.png", "trmnl_screen.png", "notes.png" }) do
                touch(data_dir .. "/" .. name)
            end
            TrmnlDisplay:removeScreensLeftByOlderVersions()
            assert.same({ "notes.png" }, files_in(data_dir))
        end)
    end)

    describe("sleep between refreshes", function()
        local Device, UIManager

        setup(function()
            Device = require("device")
            UIManager = require("ui/uimanager")
        end)

        local function fake_wakeup_mgr()
            local mgr = {}
            mgr.addTask = spy.new(function() end)
            mgr.removeTasks = spy.new(function() end)
            return mgr
        end

        local real_toggle_suspend

        before_each(function()
            Device.wakeup_mgr = fake_wakeup_mgr()
            stub(os, "time", 1000)
            stub(Device, "isKindle", true)
            -- Only Kindle's power driver has it; the emulator's does not.
            real_toggle_suspend = Device.powerd.toggleSuspend
            Device.powerd.toggleSuspend = function() end
        end)

        after_each(function()
            Device.wakeup_mgr = nil
            os.time:revert()
            Device.isKindle:revert()
            Device.powerd.toggleSuspend = real_toggle_suspend
            Device.screen_saver_mode = false
        end)

        local function instance(settings, running)
            local merged = require("util").tableDeepCopy(TrmnlDisplay.default_settings)
            for key, value in pairs(settings or {}) do merged[key] = value end
            local i = setmetatable({
                settings = merged,
                auto_refresh_enabled = running or false,
                saveSettings = function() end,
                refresh_task = function() end,
            }, { __index = TrmnlDisplay })
            i:createSleepTasks()
            return i
        end

        it("is off by default", function()
            assert.is_false(TrmnlDisplay.default_settings.sleep_between_refreshes)
        end)

        it("is unavailable without a wake alarm", function()
            Device.wakeup_mgr = nil
            assert.is_false(instance():sleepModeAvailable())
        end)

        it("is available with a wake alarm", function()
            assert.is_true(instance():sleepModeAvailable())
        end)

        it("is unavailable on a non-Kindle with a wake alarm, such as a Kobo", function()
            Device.isKindle:revert()
            stub(Device, "isKindle", false)
            assert.is_false(instance():sleepModeAvailable())
        end)

        it("is unavailable when the power driver cannot leave the sleep screen", function()
            Device.powerd.toggleSuspend = nil
            assert.is_false(instance():sleepModeAvailable())
        end)

        it("stays inactive on a device without a wake alarm even if the setting is on", function()
            Device.wakeup_mgr = nil
            assert.is_false(instance({ sleep_between_refreshes = true }, true):sleepModeActive())
        end)

        it("is active only with the setting on and the dashboard running", function()
            assert.is_true(instance({ sleep_between_refreshes = true }, true):sleepModeActive())
            assert.is_false(instance({ sleep_between_refreshes = true }, false):sleepModeActive())
            assert.is_false(instance({ sleep_between_refreshes = false }, true):sleepModeActive())
        end)

        it("greys out the menu item without a wake alarm", function()
            Device.wakeup_mgr = nil
            assert.is_false(instance():createSleepModeToggle().enabled_func())
        end)

        it("saves the choice from the menu", function()
            local i = instance()
            stub(UIManager, "show")
            i:createSleepModeToggle().callback()
            UIManager.show:revert()
            assert.is_true(i.settings.sleep_between_refreshes)
        end)

        local function queued(task)
            for _, item in ipairs(UIManager._task_queue) do
                if item.action == task then return item.time end
            end
        end

        local function clear_queue(i)
            for _, task in ipairs({ i.refresh_task, i.wake_alarm_task, i.sleep_task, i.watchdog_task, i.wifi_guard_task }) do
                UIManager:unschedule(task)
            end
        end

        describe("arming the wake alarm", function()
            after_each(function()
                Device.canDeepSleep, Device.hibernationDelay = nil, nil
            end)

            it("records when the next refresh is due", function()
                local i = instance({ sleep_between_refreshes = true, refresh_interval = 900 }, true)
                stub(i, "requestSleep")
                i:scheduleNextRefresh()
                clear_queue(i)
                assert.is_equal(1900, i.next_refresh_epoch)
            end)

            it("records when a retry is due", function()
                local NetworkMgr = require("ui/network/manager")
                stub(NetworkMgr, "runWhenConnected")
                local i = instance({ sleep_between_refreshes = true }, true)
                i.retry_manager = { increment = function() return 120 end }
                i:fetchAndDisplay()
                NetworkMgr.runWhenConnected:revert()
                clear_queue(i)
                assert.is_equal(1120, i.next_refresh_epoch)
            end)

            it("arms the alarm for the next refresh when the Kindle sleeps", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 1900
                i:onSuspend()
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.addTask).was_called_with(Device.wakeup_mgr, 900, i.wake_alarm_task)
            end)

            it("replaces an earlier alarm instead of adding a second one", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 1900
                i:onSuspend()
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.removeTasks).was_called_with(Device.wakeup_mgr, nil, i.wake_alarm_task)
            end)

            it("waits at least a minute when the refresh is already due", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 990
                assert.is_equal(60, i:alarmDelay(1000))
            end)

            it("waits a minute when no refresh was booked yet", function()
                assert.is_equal(60, instance({ sleep_between_refreshes = true }, true):alarmDelay(1000))
            end)

            it("wakes before the Kindle hibernates", function()
                Device.canDeepSleep, Device.hibernationDelay = true, 3600
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 1000 + 8 * 3600
                assert.is_equal(3480, i:alarmDelay(1000))
            end)

            it("keeps the backup refresh booked while asleep", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 1900
                UIManager:scheduleIn(900, i.refresh_task)
                i:onSuspend()
                local kept = queued(i.refresh_task)
                clear_queue(i)
                assert.is_not_nil(kept)
            end)

            it("arms no alarm with the setting off", function()
                local i = instance({ sleep_between_refreshes = false }, true)
                i.next_refresh_epoch = 1900
                i:onSuspend()
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.addTask).was_not_called()
            end)
        end)

        describe("waking up", function()
            before_each(function()
                stub(Device.powerd, "toggleSuspend")
            end)

            after_each(function()
                Device.powerd.toggleSuspend:revert()
                Device.screen_saver_mode = false
            end)

            it("leaves the sleep screen when the alarm is due", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 1010
                i:onWakeAlarm()
                assert.stub(Device.powerd.toggleSuspend).was_called()
                assert.is_true(i.alarm_wake_pending)
            end)

            it("goes back to sleep after an early wake that only avoided hibernation", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.next_refresh_epoch = 1000 + 4 * 3600
                i:onWakeAlarm()
                assert.stub(Device.powerd.toggleSuspend).was_not_called()
                assert.spy(Device.wakeup_mgr.addTask).was_called()
            end)

            it("fetches on an alarm wake and starts the watchdog", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.alarm_wake_pending = true
                stub(i, "fetchAndDisplay")
                i:onResume()
                local watchdog = queued(i.watchdog_task)
                clear_queue(i)
                assert.is_equal("alarm", i.wake_kind)
                assert.is_false(i.alarm_wake_pending)
                assert.stub(i.fetchAndDisplay).was_called()
                assert.is_not_nil(watchdog)
            end)

            it("removes the queued alarm when the user wakes the Kindle", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                stub(i, "fetchAndDisplay")
                i:onResume()
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.removeTasks).was_called_with(Device.wakeup_mgr, nil, i.wake_alarm_task)
            end)

            it("fetches at once when the user wakes the Kindle, even with Wi-Fi restore on", function()
                stub(Device, "hasWifiRestore", true)
                local NetworkMgr = require("ui/network/manager")
                local wifi_was_on, auto_restore = NetworkMgr.wifi_was_on, G_reader_settings:readSetting("auto_restore_wifi")
                NetworkMgr.wifi_was_on = true
                G_reader_settings:saveSetting("auto_restore_wifi", true)
                local i = instance({ sleep_between_refreshes = true }, true)
                stub(i, "fetchAndDisplay")
                i:onResume()
                Device.hasWifiRestore:revert()
                NetworkMgr.wifi_was_on = wifi_was_on
                G_reader_settings:saveSetting("auto_restore_wifi", auto_restore)
                local watchdog = queued(i.watchdog_task)
                clear_queue(i)
                assert.is_equal("user", i.wake_kind)
                assert.stub(i.fetchAndDisplay).was_called()
                assert.is_nil(watchdog)
            end)

            it("wakes the Kindle itself when it shows the sleep screen without suspending", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                stub(i, "fetchAndDisplay")
                Device.screen_saver_mode = true
                i.refresh_task()
                assert.stub(Device.powerd.toggleSuspend).was_called()
                assert.stub(i.fetchAndDisplay).was_not_called()
            end)

            it("fetches as before when the backup refresh fires while awake", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                stub(i, "fetchAndDisplay")
                i.refresh_task()
                assert.stub(i.fetchAndDisplay).was_called()
            end)

            describe("getting Wi-Fi back", function()
                local NetworkMgr
                local pending, pending_connection

                before_each(function()
                    NetworkMgr = require("ui/network/manager")
                    pending, pending_connection = NetworkMgr.pending_connectivity_check, NetworkMgr.pending_connection
                    NetworkMgr.pending_connectivity_check = false
                    NetworkMgr.pending_connection = false
                    stub(NetworkMgr, "isConnected", false)
                    stub(NetworkMgr, "restoreWifiAsync")
                    stub(NetworkMgr, "scheduleConnectivityCheck", function()
                        NetworkMgr.pending_connectivity_check = true
                    end)
                    stub(NetworkMgr, "unscheduleConnectivityCheck")
                    stub(NetworkMgr, "runWhenConnected")
                    stub(Device, "hasWifiRestore", true)
                    -- Run deferred work at once, so each example sees its effect.
                    stub(UIManager, "nextTick", function(_, action) action() end)
                end)

                after_each(function()
                    NetworkMgr.pending_connectivity_check = pending
                    NetworkMgr.pending_connection = pending_connection
                    NetworkMgr.isConnected:revert()
                    NetworkMgr.restoreWifiAsync:revert()
                    NetworkMgr.scheduleConnectivityCheck:revert()
                    NetworkMgr.unscheduleConnectivityCheck:revert()
                    NetworkMgr.runWhenConnected:revert()
                    Device.hasWifiRestore:revert()
                    UIManager.nextTick:revert()
                end)

                local function fetching_instance(settings)
                    local i = instance(settings, true)
                    i.retry_manager = { increment = function() return 120 end }
                    return i
                end

                it("restores Wi-Fi in the background after a wake instead of scanning", function()
                    local i = instance({ sleep_between_refreshes = true }, true)
                    local callback = spy.new(function() end)
                    i:connectAfterWake(callback)
                    assert.stub(NetworkMgr.restoreWifiAsync).was_called()
                    assert.stub(NetworkMgr.scheduleConnectivityCheck).was_called()
                    assert.stub(NetworkMgr.runWhenConnected).was_not_called()
                    NetworkMgr.scheduleConnectivityCheck.calls[1].vals[2]()
                    assert.spy(callback).was_called(1)
                end)

                it("fetches at once after a wake when Wi-Fi is already connected", function()
                    NetworkMgr.isConnected:revert()
                    stub(NetworkMgr, "isConnected", true)
                    local i = instance({ sleep_between_refreshes = true }, true)
                    local callback = spy.new(function() end)
                    i:connectAfterWake(callback)
                    assert.spy(callback).was_called()
                    assert.stub(NetworkMgr.restoreWifiAsync).was_not_called()
                    assert.stub(NetworkMgr.scheduleConnectivityCheck).was_not_called()
                end)

                it("takes over a Wi-Fi restore KOReader already started, without restarting it", function()
                    NetworkMgr.pending_connectivity_check = true
                    local i = instance({ sleep_between_refreshes = true }, true)
                    i:connectAfterWake(function() end)
                    assert.stub(NetworkMgr.unscheduleConnectivityCheck).was_called()
                    assert.stub(NetworkMgr.restoreWifiAsync).was_not_called()
                    assert.stub(NetworkMgr.scheduleConnectivityCheck).was_called()
                end)

                -- KOSync's resume handler, for one, cancels every pending check and starts its own.
                it("fetches when a check another plugin started brings Wi-Fi back", function()
                    local i = instance({ sleep_between_refreshes = true }, true)
                    local callback = spy.new(function() end)
                    i:connectAfterWake(callback)
                    i:onNetworkConnected()
                    assert.spy(callback).was_called(1)
                end)

                it("fetches only once when both the event and its own check report Wi-Fi", function()
                    local i = instance({ sleep_between_refreshes = true }, true)
                    local callback = spy.new(function() end)
                    i:connectAfterWake(callback)
                    i:onNetworkConnected()
                    NetworkMgr.scheduleConnectivityCheck.calls[1].vals[2]()
                    assert.spy(callback).was_called(1)
                end)

                it("ignores Wi-Fi coming back when no wake fetch waits", function()
                    local i = instance({ sleep_between_refreshes = true }, true)
                    stub(i, "fetchAndDisplay")
                    i:onNetworkConnected()
                    assert.stub(i.fetchAndDisplay).was_not_called()
                end)

                it("drops the waiting wake fetch when the Kindle goes back to sleep", function()
                    local i = instance({ sleep_between_refreshes = true }, true)
                    local callback = spy.new(function() end)
                    i:connectAfterWake(callback)
                    i:onSuspend()
                    i:onNetworkConnected()
                    clear_queue(i)
                    assert.spy(callback).was_not_called()
                end)

                it("drops the waiting wake fetch when a new fetch starts", function()
                    local i = fetching_instance({ sleep_between_refreshes = true })
                    local callback = spy.new(function() end)
                    i:connectAfterWake(callback)
                    i:fetchAndDisplay()
                    i:onNetworkConnected()
                    clear_queue(i)
                    assert.spy(callback).was_not_called()
                end)

                -- KOSync asks for Wi-Fi 1 s after a resume. Its scan finds nothing that early,
                -- and KOReader then turns Wi-Fi off and cancels every check, with no event.
                describe("when another caller turns Wi-Fi off", function()
                    local function abort()
                        NetworkMgr.pending_connectivity_check = false
                        NetworkMgr.pending_connection = false
                    end

                    -- Run the guard task the way UIManager does: take it off the queue first.
                    local function run_guard(i)
                        UIManager:unschedule(i.wifi_guard_task)
                        i.wifi_guard_task()
                    end

                    it("marks a connection as pending, so another caller does not start its own scan", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        i:connectAfterWake(function() end)
                        clear_queue(i)
                        assert.is_true(NetworkMgr.pending_connection)
                    end)

                    it("marks a connection as pending when it takes over KOReader's restore", function()
                        NetworkMgr.pending_connectivity_check = true
                        local i = instance({ sleep_between_refreshes = true }, true)
                        i:connectAfterWake(function() end)
                        clear_queue(i)
                        assert.is_true(NetworkMgr.pending_connection)
                    end)

                    it("restores Wi-Fi again after the restore is cancelled", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        local callback = spy.new(function() end)
                        i:connectAfterWake(callback)
                        assert.is_not_nil(queued(i.wifi_guard_task))
                        abort()
                        run_guard(i)
                        local again = queued(i.wifi_guard_task)
                        clear_queue(i)
                        assert.stub(NetworkMgr.restoreWifiAsync).was_called(2)
                        assert.stub(NetworkMgr.scheduleConnectivityCheck).was_called(2)
                        assert.is_true(NetworkMgr.pending_connection)
                        assert.is_not_nil(again)
                        NetworkMgr.scheduleConnectivityCheck.calls[2].vals[2]()
                        assert.spy(callback).was_called(1)
                    end)

                    it("leaves a running check alone", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        i:connectAfterWake(function() end)
                        run_guard(i)
                        local again = queued(i.wifi_guard_task)
                        clear_queue(i)
                        assert.stub(NetworkMgr.restoreWifiAsync).was_called(1)
                        assert.is_not_nil(again)
                    end)

                    it("fetches when Wi-Fi is up but the check was cancelled", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        local callback = spy.new(function() end)
                        i:connectAfterWake(callback)
                        abort()
                        NetworkMgr.isConnected:revert()
                        stub(NetworkMgr, "isConnected", true)
                        run_guard(i)
                        local again = queued(i.wifi_guard_task)
                        clear_queue(i)
                        assert.spy(callback).was_called(1)
                        assert.stub(NetworkMgr.restoreWifiAsync).was_called(1)
                        assert.is_nil(again)
                    end)

                    it("stops restoring after a few tries and leaves the rest to the watchdog", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        i:connectAfterWake(function() end)
                        for _ = 1, 10 do
                            abort()
                            if queued(i.wifi_guard_task) then run_guard(i) end
                        end
                        local again = queued(i.wifi_guard_task)
                        clear_queue(i)
                        assert.stub(NetworkMgr.restoreWifiAsync).was_called(TrmnlDisplay.CONSTANTS.SLEEP.WIFI_RESTORES)
                        assert.is_nil(again)
                    end)

                    it("stops checking once the fetch ran", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        i:connectAfterWake(function() end)
                        i:onNetworkConnected()
                        abort()
                        run_guard(i)
                        local again = queued(i.wifi_guard_task)
                        clear_queue(i)
                        assert.stub(NetworkMgr.restoreWifiAsync).was_called(1)
                        assert.is_nil(again)
                    end)

                    it("stops checking when the Kindle goes back to sleep", function()
                        local i = instance({ sleep_between_refreshes = true }, true)
                        i:connectAfterWake(function() end)
                        i:onSuspend()
                        local again = queued(i.wifi_guard_task)
                        clear_queue(i)
                        assert.is_nil(again)
                    end)
                end)

                it("fetches through the background restore on an alarm wake", function()
                    local i = fetching_instance({ sleep_between_refreshes = true })
                    i.alarm_wake_pending = true
                    stub(i, "_doFetchAndDisplay")
                    i:onResume()
                    local watchdog = queued(i.watchdog_task)
                    local retry = queued(i.refresh_task)
                    clear_queue(i)
                    assert.stub(NetworkMgr.runWhenConnected).was_not_called()
                    assert.stub(NetworkMgr.scheduleConnectivityCheck).was_called()
                    -- KOReader gives up after 45 s. The watchdog and the booked retry then put the Kindle back to sleep.
                    assert.is_not_nil(watchdog)
                    assert.is_not_nil(retry)
                    local callback = NetworkMgr.scheduleConnectivityCheck.calls[1].vals[2]
                    callback()
                    assert.stub(i._doFetchAndDisplay).was_called()
                end)

                it("fetches through the background restore on a user wake", function()
                    local i = fetching_instance({ sleep_between_refreshes = true })
                    i:onResume()
                    clear_queue(i)
                    assert.stub(NetworkMgr.runWhenConnected).was_not_called()
                    assert.stub(NetworkMgr.restoreWifiAsync).was_called()
                end)

                it("keeps KOReader's usual connection when the backup refresh fires while awake", function()
                    local i = fetching_instance({ sleep_between_refreshes = true })
                    i.refresh_task()
                    clear_queue(i)
                    assert.stub(NetworkMgr.runWhenConnected).was_called()
                    assert.stub(NetworkMgr.restoreWifiAsync).was_not_called()
                end)

                it("keeps KOReader's usual connection on wake with the setting off", function()
                    Device.hasWifiRestore:revert()
                    stub(Device, "hasWifiRestore", false)
                    local i = fetching_instance({ sleep_between_refreshes = false })
                    i:onResume()
                    clear_queue(i)
                    assert.stub(NetworkMgr.runWhenConnected).was_called()
                    assert.stub(NetworkMgr.restoreWifiAsync).was_not_called()
                end)
            end)
        end)

        describe("going back to sleep", function()
            local function after_screen(kind)
                local i = instance({ sleep_between_refreshes = true, refresh_interval = 900 }, true)
                i.wake_kind = kind
                UIManager:scheduleIn(90, i.watchdog_task)
                i:scheduleNextRefresh()
                return i
            end

            it("sleeps right after the screen on an alarm wake", function()
                local i = after_screen("alarm")
                local sleep, watchdog = queued(i.sleep_task), queued(i.watchdog_task)
                clear_queue(i)
                assert.is_not_nil(sleep)
                assert.is_nil(watchdog)
            end)

            it("stays awake for the grace period after a user wake", function()
                local alarm = after_screen("alarm")
                local alarm_sleep = queued(alarm.sleep_task)
                clear_queue(alarm)
                local user = after_screen("user")
                local user_sleep = queued(user.sleep_task)
                clear_queue(user)
                local time = require("ui/time")
                local gap = time.to_number(user_sleep - alarm_sleep)
                local constants = TrmnlDisplay.CONSTANTS.SLEEP
                assert.is_true(math.abs(gap - (constants.GRACE_SECONDS - constants.AFTER_DRAW_DELAY)) < 1)
            end)

            it("restarts the grace period with each new screen", function()
                local i = after_screen("user")
                i:scheduleNextRefresh()
                local count = 0
                for _, item in ipairs(UIManager._task_queue) do
                    if item.action == i.sleep_task then count = count + 1 end
                end
                clear_queue(i)
                assert.is_equal(1, count)
            end)

            it("goes back to sleep when an alarm wake fails", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.wake_kind = "alarm"
                i.retry_manager = { count = 1, getDelay = function() return 120 end }
                stub(i, "showError")
                i:handleFetchError("Failed to fetch screen metadata")
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.is_not_nil(sleep)
            end)

            it("keeps the user's grace period when a fetch fails after a user wake", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.wake_kind = "user"
                i.retry_manager = { count = 1, getDelay = function() return 120 end }
                stub(i, "showError")
                i:handleFetchError("Failed to fetch screen metadata")
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.is_nil(sleep)
            end)

            it("shows no error popup when an alarm wake fails, so none stays on the screen", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.wake_kind = "alarm"
                i.retry_manager = { count = 1, getDelay = function() return 120 end }
                stub(i, "showError")
                i:handleFetchError("Failed to fetch screen metadata")
                clear_queue(i)
                assert.stub(i.showError).was_not_called()
            end)

            it("still shows the error popup when a fetch fails after a user wake", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.wake_kind = "user"
                i.retry_manager = { count = 1, getDelay = function() return 120 end }
                stub(i, "showError")
                i:handleFetchError("Failed to fetch screen metadata")
                clear_queue(i)
                assert.stub(i.showError).was_called()
            end)

            it("gives up on a stuck alarm wake after the watchdog", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i:onAlarmWakeTimeout()
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.is_not_nil(sleep)
            end)

            it("cancels pending sleep and watchdog when the user puts it to sleep", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i:requestSleep(120)
                UIManager:scheduleIn(90, i.watchdog_task)
                i:onSuspend()
                local sleep, watchdog = queued(i.sleep_task), queued(i.watchdog_task)
                clear_queue(i)
                assert.is_nil(sleep)
                assert.is_nil(watchdog)
            end)

            it("never toggles the Kindle out of the sleep screen to put it to sleep", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                Device.screen_saver_mode = true
                stub(UIManager, "suspend")
                i.sleep_task()
                local called = #UIManager.suspend.calls
                UIManager.suspend:revert()
                assert.is_equal(0, called)
            end)

            it("re-arms the alarm when a screen arrives after the user put it to sleep", function()
                local i = instance({ sleep_between_refreshes = true, refresh_interval = 900 }, true)
                i.wake_kind = "alarm"
                Device.screen_saver_mode = true
                i:scheduleNextRefresh()
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.is_nil(sleep)
                assert.spy(Device.wakeup_mgr.addTask).was_called_with(Device.wakeup_mgr, 900, i.wake_alarm_task)
            end)

            it("re-arms the alarm when a fetch fails after the user put it to sleep", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.wake_kind = "alarm"
                i.next_refresh_epoch = 1120
                i.retry_manager = { count = 1, getDelay = function() return 120 end }
                stub(i, "showError")
                Device.screen_saver_mode = true
                i:handleFetchError("Failed to fetch screen metadata")
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.is_nil(sleep)
                assert.spy(Device.wakeup_mgr.addTask).was_called_with(Device.wakeup_mgr, 120, i.wake_alarm_task)
            end)

            it("does not draw over the sleep screen", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i.retry_manager = { reset = function() end }
                stub(i, "displayImage")
                stub(i, "showSuccess")
                Device.screen_saver_mode = true
                i:finalizeFetchSuccess("dashboard.png")
                clear_queue(i)
                assert.stub(i.displayImage).was_not_called()
            end)

            describe("with Keep alive on", function()
                local PluginShare

                setup(function()
                    PluginShare = require("pluginshare")
                end)

                before_each(function()
                    PluginShare.keepalive = true
                end)

                after_each(function()
                    PluginShare.keepalive = nil
                end)

                it("says why the device cannot sleep, once", function()
                    local i = instance({ sleep_between_refreshes = true }, true)
                    local shown = {}
                    i.showError = function(_, message) table.insert(shown, message) end
                    stub(UIManager, "suspend")
                    i.sleep_task()
                    i.sleep_task()
                    local suspended = #UIManager.suspend.calls
                    UIManager.suspend:revert()
                    assert.same({ "Keep alive is on, so the device cannot sleep. Turn it off in Tools > More tools." }, shown)
                    assert.is_equal(0, suspended)
                end)

                it("asks to turn Keep alive off when sleep mode is turned on", function()
                    local i = instance()
                    local text
                    stub(UIManager, "show", function(_, widget) text = widget.text end)
                    i:createSleepModeToggle().callback()
                    UIManager.show:revert()
                    assert.truthy(text:find("Turn off Keep alive", 1, true))
                end)
            end)

            it("does not request sleep with the setting off", function()
                local i = instance({ sleep_between_refreshes = false }, true)
                i:scheduleNextRefresh()
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.is_nil(sleep)
            end)
        end)

        describe("cleanup", function()
            it("removes the wake alarm when the dashboard stops", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i:requestSleep(120)
                i:stopAutoRefresh()
                local sleep = queued(i.sleep_task)
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.removeTasks).was_called_with(Device.wakeup_mgr, nil, i.wake_alarm_task)
                assert.is_nil(sleep)
            end)

            it("removes the wake alarm and keeps refreshing when the toggle goes off", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i:setSleepBetweenRefreshes(false)
                local refresh = queued(i.refresh_task)
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.removeTasks).was_called_with(Device.wakeup_mgr, nil, i.wake_alarm_task)
                assert.is_not_nil(refresh)
            end)

            it("removes the wake alarm when the plugin closes", function()
                local i = instance({ sleep_between_refreshes = true }, true)
                i:onCloseWidget()
                clear_queue(i)
                assert.spy(Device.wakeup_mgr.removeTasks).was_called_with(Device.wakeup_mgr, nil, i.wake_alarm_task)
            end)
        end)
    end)
end)
