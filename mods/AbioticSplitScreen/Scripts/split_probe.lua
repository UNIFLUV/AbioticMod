-- Experimental UE4SS probe, not a complete local co-op implementation.
local Probe = {}
Probe.__index = Probe

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function require_valid(object, message)
    assert(valid(object), message)
    return object
end

-- Older UE4SS builds may wrap one UObject in different Lua userdata values.
local function same_object(left, right)
    return valid(left) and valid(right) and left:GetAddress() == right:GetAddress()
end

function Probe.new(api)
    return setmetatable({ api = api, attempted = false }, Probe)
end

function Probe:context()
    local viewport = require_valid(self.api.FindFirstOf("GameViewportClient"), "No game viewport.")
    local world = require_valid(viewport:GetWorld(), "No active world.")
    local statics = require_valid(self.api.StaticFindObject("/Script/Engine.Default__GameplayStatics"),
        "GameplayStatics is unavailable.")
    local instance = require_valid(statics:GetGameInstance(world), "No game instance.")
    return { world = world, statics = statics, instance = instance }
end

function Probe:require_function(name)
    require_valid(self.api.StaticFindObject("/Script/Engine.GameplayStatics:" .. name),
        "Required reflected function is unavailable: " .. name)
end

function Probe:require_gameplay(context)
    require_valid(context.statics:GetGameMode(context.world),
        "Host a test world locally; joining a remote server is not supported by this probe.")
    local primary = require_valid(context.statics:GetPlayerController(context.world, 0),
        "Player one has no controller.")
    require_valid(primary.Pawn, "Load a test world and enter gameplay before adding a player.")
end

function Probe:diagnose()
    local context = self:context()
    self.api.log("World: " .. context.world:GetFullName())
    self.api.log("Local player slots: " .. tostring(#context.instance.LocalPlayers))
    for index = 0, #context.instance.LocalPlayers - 1 do
        local controller = context.statics:GetPlayerController(context.world, index)
        if valid(controller) then
            self.api.log("Player " .. index .. " controller: " .. controller:GetFullName())
            self.api.log("Player " .. index .. " pawn: " ..
                (valid(controller.Pawn) and controller.Pawn:GetFullName() or "NONE"))
        else
            self.api.log("Player " .. index .. " controller: NONE")
        end
    end
    local settings = self.api.StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
    if valid(settings) then
        for _, name in ipairs({ "bUseSplitscreen", "TwoPlayerSplitscreenLayout", "bOffsetPlayerGamepadIds" }) do
            self.api.log(name .. "=" .. tostring(settings[name]))
        end
    else
        self.api.log("GameMapsSettings is unavailable; F7 cannot enable the split-screen settings.")
    end
    self.api.log("Diagnostics do not verify camera layout, per-player HUD, or gamepad routing.")
end

function Probe:restore_settings()
    if self.original_settings == nil then return end
    local settings = require_valid(self.settings, "Cannot restore expired GameMapsSettings; restart the game.")
    for name, value in pairs(self.original_settings) do settings[name] = value end
    self.original_settings = nil
    self.settings = nil
end

function Probe:add_player()
    assert(not self.attempted,
        "An add attempt already ran. Remove this probe's player with F8, or restart the game before retrying.")
    local context = self:context()
    self:require_gameplay(context)
    assert(#context.instance.LocalPlayers == 1, "Expected exactly one local player; refusing to add another.")
    self:require_function("CreatePlayer")
    self:require_function("RemovePlayer")
    local settings = require_valid(self.api.StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings"),
        "GameMapsSettings is unavailable.")
    self.original_settings = {
        bUseSplitscreen = settings.bUseSplitscreen,
        TwoPlayerSplitscreenLayout = settings.TwoPlayerSplitscreenLayout,
        bOffsetPlayerGamepadIds = settings.bOffsetPlayerGamepadIds,
    }
    assert(self.original_settings.bUseSplitscreen ~= nil and
        self.original_settings.TwoPlayerSplitscreenLayout ~= nil and
        self.original_settings.bOffsetPlayerGamepadIds ~= nil, "Split-screen properties are unavailable.")
    self.settings = settings
    -- Fail closed after any partially successful engine call. Never create a third player on retry.
    self.attempted = true
    self.instance = context.instance
    local ok, message = pcall(function()
        settings.bUseSplitscreen = true
        settings.TwoPlayerSplitscreenLayout = 0 -- Engine enum: TwoPlayer_Horizontal (top / bottom).
        settings.bOffsetPlayerGamepadIds = false -- Two gamepads: do not reserve player zero for a keyboard.
        self.controller = context.statics:CreatePlayer(context.world, 1, true)
        require_valid(self.controller, "CreatePlayer returned no controller; restart the game before retrying.")
        assert(#context.instance.LocalPlayers == 2, "CreatePlayer did not produce exactly two local slots.")
        assert(same_object(self.controller, context.statics:GetPlayerController(context.world, 1)),
            "Created controller does not match local player two.")
    end)
    if not ok then
        self:restore_settings()
        error(message)
    end
    self.api.log("Second local controller created. Camera, HUD, input and save identity are NOT yet verified.")
    if not valid(self.controller.Pawn) then
        self.api.log("Player two has no pawn yet. Press F6 after gameplay settles; do not create another player.")
    end
    self.api.log("Requested top/bottom split. A game-specific viewport override can still prevent it.")
end

function Probe:remove_player()
    if not self.attempted then
        self.api.log("No player was created by this probe.")
        return
    end
    local context = self:context()
    assert(valid(self.controller) and same_object(self.instance, context.instance),
        "Cannot identify this probe's player in the current game instance. Restart the game.")
    assert(#context.instance.LocalPlayers == 2 and
        same_object(self.controller, context.statics:GetPlayerController(context.world, 1)),
        "Player ownership changed; refusing to remove another controller. Restart the game.")
    self:require_function("RemovePlayer")
    context.statics:RemovePlayer(self.controller, true)
    assert(#context.instance.LocalPlayers == 1, "Player removal was not confirmed; restart the game.")
    self:restore_settings()
    self.controller = nil
    self.instance = nil
    self.attempted = false
    self.api.log("Probe player removed; original split-screen settings restored.")
end

return Probe
