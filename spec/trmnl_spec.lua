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
    local function message_for(response, image_path)
        local seen
        local instance = setmetatable({
            fetchScreenMetadata   = function() return response end,
            handleFetchError      = function(_, msg) seen = msg end,
            updateRefreshInterval = function() end,
            downloadImageIfNeeded = function() return image_path end,
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

    -- Captures the headers of a real fetchScreenMetadata call by standing in for
    -- the HTTPS transport. The response never parses, which is fine - only the
    -- outgoing request is under test.
    local function headers_for(settings, detected_mac)
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
end)
