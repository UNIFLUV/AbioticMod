local Probe = require("split_probe")
local tests_run = 0
local next_address = 0

local function object(fields)
    next_address = next_address + 1
    local result = fields or {}
    result.address = next_address
    function result:IsValid() return self.alive ~= false end
    function result:GetAddress() return self.address end
    function result:GetFullName() return "MockObject " .. self.address end
    return result
end

local function fixture(options)
    options = options or {}
    local f = { logs = {}, creates = 0, removes = 0 }
    f.world = object()
    f.primary = object({ Pawn = object() })
    f.instance = object({ LocalPlayers = { object() } })
    f.settings = object({ bUseSplitscreen = false, TwoPlayerSplitscreenLayout = 1, bOffsetPlayerGamepadIds = true })
    f.game_mode = object()
    local viewport = object()
    function viewport:GetWorld() return f.world end
    f.statics = object()
    function f.statics:GetGameInstance(world)
        assert(world == f.world)
        return f.instance
    end
    function f.statics:GetGameMode() return f.game_mode end
    function f.statics:GetPlayerController(_, index)
        if index == 0 then return f.primary end
        return f.secondary
    end
    function f.statics:CreatePlayer(world, controller_id, spawn_controller)
        assert(world == f.world and controller_id == 1 and spawn_controller == true)
        f.creates = f.creates + 1
        if options.create_throws then error("engine creation failed") end
        if options.create_fails then return nil end
        f.instance.LocalPlayers[2] = object()
        f.secondary = object({ Pawn = options.no_pawn and nil or object() })
        if options.no_pawn then f.secondary.Pawn = nil end
        if options.partial_create then return nil end
        -- Return a distinct wrapper for the same UObject address.
        local wrapper = object({ Pawn = f.secondary.Pawn })
        wrapper.address = f.secondary.address
        return wrapper
    end
    function f.statics:RemovePlayer(controller, destroy_pawn)
        assert(controller:GetAddress() == f.secondary:GetAddress() and destroy_pawn)
        f.removes = f.removes + 1
        if options.remove_fails then return end
        f.secondary.alive = false
        f.secondary = nil
        f.instance.LocalPlayers[2] = nil
    end
    f.api = {
        FindFirstOf = function(name)
            if name == "GameViewportSubsystem" then return f.subsystem end
            assert(name == "GameViewportClient")
            return options.no_viewport and nil or viewport
        end,
        StaticFindObject = function(path)
            if path == "/Script/Engine.Default__GameplayStatics" then return f.statics end
            if path == "/Script/EngineSettings.Default__GameMapsSettings" then return f.settings end
            if path == "/Script/Engine.GameplayStatics:" .. (options.missing_function or "MISSING") then return nil end
            if path == "/Script/Engine.GameplayStatics:CreatePlayer" or
                path == "/Script/Engine.GameplayStatics:RemovePlayer" then return object() end
            if path == "/Script/Engine.PlayerController:SetViewTargetWithBlend" then return object() end
            if path == "/Script/Engine.PlayerCameraManager:StopCameraFade" then
                if options.missing_camera_function == "StopCameraFade" then return nil end
                return object()
            end
            if path == "/Script/Engine.Actor:K2_TeleportTo" then return object() end
            if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return f.widget_library end
            if path == "/Script/UMG.UserWidget:AddToPlayerScreen" or
                path == "/Script/UMG.UserWidget:AddToViewport" or
                path == "/Script/UMG.Widget:RemoveFromParent" or
                path == "/Script/UMG.WidgetBlueprintLibrary:Create" or
                path == "/Script/UMG.GameViewportSubsystem:GetWidgetSlot" or
                path == "/Script/UMG.GameViewportSubsystem:SetWidgetSlot" then return object() end
            error("Unexpected lookup: " .. path)
        end,
        log = function(message) f.logs[#f.logs + 1] = message end,
    }
    f.probe = Probe.new(f.api)
    return f
end

local function fails(callback, pattern)
    local ok, message = pcall(callback)
    assert(not ok, "Expected failure")
    assert(tostring(message):find(pattern, 1, true), tostring(message))
end

local function restored(f)
    assert(f.settings.bUseSplitscreen == false)
    assert(f.settings.TwoPlayerSplitscreenLayout == 1)
    assert(f.settings.bOffsetPlayerGamepadIds == true)
end

local function test(name, callback)
    callback()
    tests_run = tests_run + 1
    print("PASS " .. name)
end

test("diagnostics do not create players or change settings", function()
    local f = fixture()
    f.probe:diagnose()
    assert(f.creates == 0 and f.removes == 0 and #f.logs > 0)
    restored(f)
end)

test("missing gameplay pawn blocks creation", function()
    local f = fixture()
    f.primary.Pawn = nil
    fails(function() f.probe:add_player() end, "enter gameplay")
    assert(f.creates == 0)
    restored(f)
end)

test("remote client is rejected", function()
    local f = fixture()
    f.game_mode = nil
    fails(function() f.probe:add_player() end, "Host a test world")
    assert(f.creates == 0)
end)

test("existing second local player is preserved", function()
    local f = fixture()
    f.instance.LocalPlayers[2] = object()
    fails(function() f.probe:add_player() end, "exactly one local player")
    assert(f.creates == 0 and f.removes == 0)
    restored(f)
end)

test("missing reflected function blocks all mutations", function()
    local f = fixture({ missing_function = "RemovePlayer" })
    fails(function() f.probe:add_player() end, "Required reflected function")
    assert(f.creates == 0)
    restored(f)
end)

test("add and remove use identity across different UObject wrappers", function()
    local f = fixture()
    f.probe:add_player()
    assert(f.creates == 1 and #f.instance.LocalPlayers == 2)
    assert(f.settings.bUseSplitscreen == true and f.settings.TwoPlayerSplitscreenLayout == 0)
    assert(f.settings.bOffsetPlayerGamepadIds == false)
    f.probe:remove_player()
    assert(f.removes == 1 and #f.instance.LocalPlayers == 1)
    restored(f)
    f.probe:add_player()
    assert(f.creates == 2)
end)

test("repeated add cannot create a third player", function()
    local f = fixture()
    f.probe:add_player()
    fails(function() f.probe:add_player() end, "already ran")
    assert(f.creates == 1 and #f.instance.LocalPlayers == 2)
end)

test("failed CreatePlayer restores settings and blocks retries", function()
    local f = fixture({ create_fails = true })
    fails(function() f.probe:add_player() end, "returned no controller")
    restored(f)
    fails(function() f.probe:add_player() end, "already ran")
    assert(f.creates == 1)
end)

test("engine creation exception restores settings", function()
    local f = fixture({ create_throws = true })
    fails(function() f.probe:add_player() end, "engine creation failed")
    restored(f)
    fails(function() f.probe:add_player() end, "already ran")
end)

test("partially created unidentified player is never removed", function()
    local f = fixture({ partial_create = true })
    fails(function() f.probe:add_player() end, "returned no controller")
    assert(#f.instance.LocalPlayers == 2)
    fails(function() f.probe:add_player() end, "already ran")
    fails(function() f.probe:remove_player() end, "Cannot identify")
    assert(f.creates == 1 and f.removes == 0)
    restored(f)
end)

test("unspawned second pawn is reported without adding another player", function()
    local f = fixture({ no_pawn = true })
    f.probe:add_player()
    assert(table.concat(f.logs, "\n"):find("no pawn yet", 1, true))
    fails(function() f.probe:add_player() end, "already ran")
    f.probe:remove_player()
    restored(f)
end)

test("changed game instance prevents removal", function()
    local f = fixture()
    f.probe:add_player()
    f.instance = object({ LocalPlayers = { object(), object() } })
    fails(function() f.probe:remove_player() end, "Cannot identify")
    assert(f.removes == 0)
end)

test("replacement controller is not removed", function()
    local f = fixture()
    f.probe:add_player()
    f.secondary = object()
    fails(function() f.probe:remove_player() end, "ownership changed")
    assert(f.removes == 0)
end)

test("failed removal is not reported as success", function()
    local f = fixture({ remove_fails = true })
    f.probe:add_player()
    fails(function() f.probe:remove_player() end, "not confirmed")
    assert(f.probe.attempted and f.settings.bUseSplitscreen == true)
end)

test("remove before add is harmless", function()
    local f = fixture()
    f.probe:remove_player()
    assert(f.creates == 0 and f.removes == 0)
    restored(f)
end)

local function entrypoint_fixture(scheduler, options)
    local f = fixture(options)
    local keys, queued = {}, {}
    local scope = setmetatable({
        FindFirstOf = f.api.FindFirstOf,
        StaticFindObject = f.api.StaticFindObject,
        FindAllOf = function(class_name)
            if class_name == "W_PlayerHUD_Main_C" then return f.main_huds end
            assert(class_name == "UserWidget")
            return f.widgets
        end,
        print = function(message) f.logs[#f.logs + 1] = message end,
        Key = { F1 = "F1", F2 = "F2", F3 = "F3", F4 = "F4", F5 = "F5", F6 = "F6", F7 = "F7", F8 = "F8", F9 = "F9" },
        RegisterKeyBind = function(key, callback) keys[key] = callback end,
        ExecuteInGameThread = scheduler or function(callback) queued[#queued + 1] = callback end,
    }, { __index = _G })
    assert(loadfile("mods/AbioticSplitScreen/Scripts/main.lua", "t", scope))()
    return f, keys, queued
end

test("key callbacks defer mutations to game thread and suppress pending duplicates", function()
    local f, keys, queued = entrypoint_fixture()
    keys.F7()
    keys.F7()
    assert(#queued == 1 and f.creates == 0)
    queued[1]()
    assert(f.creates == 1)
    keys.F8()
    assert(#queued == 2 and f.removes == 0)
    queued[2]()
    assert(f.removes == 1)
    restored(f)
end)

test("action error releases dispatch lock for diagnostics", function()
    local f, keys, queued = entrypoint_fixture()
    f.primary.Pawn = nil
    keys.F7()
    queued[1]()
    keys.F6()
    assert(#queued == 2)
    queued[2]()
    assert(f.creates == 0 and table.concat(f.logs, "\n"):find("ERROR", 1, true))
end)

test("scheduler error releases dispatch lock", function()
    local attempts = 0
    local f, keys = entrypoint_fixture(function()
        attempts = attempts + 1
        error("scheduler unavailable")
    end)
    keys.F6()
    keys.F6()
    assert(attempts == 2 and f.creates == 0)
    assert(table.concat(f.logs, "\n"):find("Cannot schedule", 1, true))
end)

local function camera_fixture(options)
    local f, keys, queued = entrypoint_fixture(nil, options)
    keys.F7()
    queued[1]()
    f.camera_resets, f.fade_stops = 0, 0
    f.secondary.PlayerCameraManager = object({ FadeAmount = 1 })
    function f.secondary.PlayerCameraManager:StopCameraFade()
        f.fade_stops = f.fade_stops + 1
        self.FadeAmount = 0
    end
    function f.secondary:SetViewTargetWithBlend(target, time, blend, exponent, lock)
        assert(target == f.secondary.Pawn and target ~= f.primary.Pawn)
        assert(time == 0 and blend == 0 and exponent == 1 and lock == false)
        f.camera_resets = f.camera_resets + 1
        f.view_target = target
    end
    return f, keys, queued
end

test("camera reset before adding a player does not mutate the world", function()
    local f, keys, queued = entrypoint_fixture()
    keys.F9()
    queued[1]()
    assert(f.creates == 0 and f.removes == 0 and #f.instance.LocalPlayers == 1)
    assert(table.concat(f.logs, "\n"):find("exactly two local players", 1, true))
end)

test("camera reset changes only the probe's second player's camera", function()
    local f, keys, queued = camera_fixture()
    local original_pawn = f.primary.Pawn
    keys.F9()
    assert(f.camera_resets == 0 and f.fade_stops == 0)
    queued[2]()
    assert(f.camera_resets == 1 and f.fade_stops == 1)
    assert(f.view_target == f.secondary.Pawn and f.primary.Pawn == original_pawn)
    assert(f.creates == 1 and f.removes == 0 and #f.instance.LocalPlayers == 2)
end)

test("camera reset rejects a replacement second player", function()
    local f, keys, queued = camera_fixture()
    f.secondary = object({ Pawn = object() })
    keys.F9()
    queued[2]()
    assert(f.camera_resets == 0 and f.fade_stops == 0)
    assert(table.concat(f.logs, "\n"):find("Cannot identify this probe", 1, true))
end)

test("camera reset rejects a missing second pawn", function()
    local f, keys, queued = camera_fixture()
    f.secondary.Pawn = nil
    keys.F9()
    queued[2]()
    assert(f.camera_resets == 0 and f.fade_stops == 0)
end)

test("unsupported camera function prevents partial repair", function()
    local f, keys, queued = camera_fixture({ missing_camera_function = "StopCameraFade" })
    keys.F9()
    queued[2]()
    assert(f.camera_resets == 0 and f.fade_stops == 0)
    assert(table.concat(f.logs, "\n"):find("StopCameraFade is not available", 1, true))
end)

local function teleport_fixture(succeeds)
    local f, keys, queued = entrypoint_fixture()
    keys.F7()
    queued[1]()
    f.teleports = 0
    local origin = { X = 1000, Y = 2000, Z = 208 }
    local rotation = { Pitch = 0, Yaw = 90, Roll = 0 }
    function f.primary.Pawn:K2_GetActorLocation() return origin end
    function f.primary.Pawn:GetActorRightVector() return { X = 0, Y = 1, Z = 0 } end
    function f.primary.Pawn:K2_GetActorRotation() return rotation end
    f.second_location = { X = -13507, Y = 16473, Z = 21608 }
    function f.secondary.Pawn:K2_GetActorLocation() return f.second_location end
    function f.secondary.Pawn:K2_TeleportTo(destination, orientation)
        assert(orientation == rotation)
        assert(destination.X == 1000 and destination.Y == 2200 and destination.Z == 213)
        f.teleports = f.teleports + 1
        if succeeds then f.second_location = destination end
        return succeeds
    end
    return f, keys, queued
end

test("teleport before adding a player does not mutate anything", function()
    local f, keys, queued = entrypoint_fixture()
    keys.F5()
    queued[1]()
    assert(f.creates == 0 and f.removes == 0)
    assert(table.concat(f.logs, "\n"):find("F5 needs exactly two", 1, true))
end)

test("manual spawn experiment moves only the owned second pawn on game thread", function()
    local f, keys, queued = teleport_fixture(true)
    keys.F5()
    assert(f.teleports == 0)
    queued[2]()
    assert(f.teleports == 1 and f.second_location.Z == 213)
    assert(f.primary.Pawn:K2_GetActorLocation().Z == 208)
    assert(f.creates == 1 and f.removes == 0 and #f.instance.LocalPlayers == 2)
end)

test("collision rejection is reported without a forced teleport or false success", function()
    local f, keys, queued = teleport_fixture(false)
    keys.F5()
    queued[2]()
    assert(f.teleports == 1 and f.second_location.Z == 21608)
    local logs = table.concat(f.logs, "\n")
    assert(logs:find("Teleport was not confirmed", 1, true))
    assert(not logs:find("F5 teleport returned true", 1, true))
end)

test("spawn experiment refuses a replacement controller", function()
    local f, keys, queued = teleport_fixture(true)
    f.secondary = object({ Pawn = object() })
    keys.F5()
    queued[2]()
    assert(f.teleports == 0)
    assert(table.concat(f.logs, "\n"):find("Cannot identify this probe", 1, true))
end)

local function widget(owner, in_viewport)
    local result = object()
    function result:IsInViewport() return in_viewport end
    function result:GetOwningPlayer() return owner end
    function result:GetVisibility() return 0 end
    function result:GetParent() return nil end
    return result
end

test("HUD diagnostics distinguish owners and omit widgets not directly in viewport", function()
    local f, keys, queued = entrypoint_fixture()
    keys.F7()
    queued[1]()
    f.widgets = { widget(f.primary, true), widget(f.secondary, true), widget(f.primary, false), widget(nil, true) }
    local wrapper = object()
    wrapper.address = f.primary.address
    f.widgets[1] = widget(wrapper, true)
    keys.F6()
    queued[2]()
    local logs = table.concat(f.logs, "\n")
    assert(logs:find("HUD root 1 owner: Player 0", 1, true))
    assert(logs:find("HUD root 2 owner: Player 1", 1, true))
    assert(logs:find("HUD root 3 owner: NONE", 1, true))
    assert(logs:find("4 widget instances; 3 viewport roots reported; 0 filter errors", 1, true))
    assert(f.creates == 1 and f.removes == 0 and #f.instance.LocalPlayers == 2)
end)

test("expired widget does not stop the HUD scan", function()
    local f, keys, queued = entrypoint_fixture()
    f.widgets = { object(), widget(f.primary, true) }
    keys.F6()
    queued[1]()
    local logs = table.concat(f.logs, "\n")
    assert(logs:find("HUD root 1 owner: Player 0", 1, true))
    assert(logs:find("1 viewport roots reported; 1 filter errors", 1, true))
    assert(f.creates == 0 and f.removes == 0)
end)

test("HUD inspection bounds log output and reports truncation", function()
    local f, keys, queued = entrypoint_fixture()
    f.widgets = {}
    for index = 1, 50 do f.widgets[index] = widget(f.primary, true) end
    keys.F6()
    queued[1]()
    local logs = table.concat(f.logs, "\n")
    assert(logs:find("HUD output capped at 40 roots; scan is incomplete", 1, true))
    assert(not logs:find("HUD root 41", 1, true))
    assert(f.creates == 0 and f.removes == 0)
end)

local function hud_fixture(options)
    options = options or {}
    local f, keys, queued = entrypoint_fixture()
    keys.F7()
    queued[1]()
    f.hud_creates, f.slot_restores = 0, 0
    f.hud_class = object()
    function f.hud_class:ForEachProperty(callback)
        local p = object()
        function p:GetFName() return {ToString = function() return 'OwningCharacter' end} end
        function p:GetFullName() return 'ObjectProperty HUD:OwningCharacter' end
        callback(p)
    end
    local pc_class = object()
    function pc_class:ForEachProperty(callback)
        local p = object()
        function p:GetFName() return {ToString = function() return 'PlayerHUDRef' end} end
        function p:GetFullName() return 'ObjectProperty Controller:PlayerHUDRef' end
        callback(p)
    end
    function f.secondary:GetClass() return pc_class end
    local pawn_class = object()
    function pawn_class:ForEachProperty(callback)
        local p = object()
        function p:GetFName() return {ToString = function() return 'InventoryReference' end} end
        function p:GetFullName() return 'ObjectProperty Pawn:InventoryReference' end
        callback(p)
    end
    function f.secondary.Pawn:GetClass() return pawn_class end
    local function hud(owner, visible)
        local item = object({ owner = owner, visible = visible, mode = "global", z = 17, OwningCharacter = f.primary.Pawn })
        item.W_PlayerInventory_Main = object({OwningCharacter=f.primary.Pawn})
        function item.W_PlayerInventory_Main:GetClass() return f.hud_class end
        function item.W_PlayerInventory_Main:GetOwningPlayer() return owner end
        function item:GetOwningPlayer() return self.owner end
        function item:IsInViewport() return self.visible end
        function item:GetClass() return f.hud_class end
        function item:RemoveFromParent() self.visible = false end
        function item:AddToViewport(z) self.visible, self.mode, self.z = true, "global", z end
        function item:AddToPlayerScreen(z)
            if self == f.guest and options.guest_add_fails then return false end
            if self == f.guest and not f.character_at_first_show then
                f.character_at_first_show = self.W_PlayerInventory_Main.OwningCharacter
            end
            self.visible, self.mode, self.z = true, "player", z
            return true
        end
        return item
    end
    f.main_hud = hud(f.primary, true)
    f.primary.PlayerHUDRef = f.main_hud
    f.primary.Pawn.InventoryReference = f.main_hud.W_PlayerInventory_Main
    f.main_huds = { f.main_hud }
    f.subsystem = object()
    f.slot = { ZOrder = 17, original_layout = "unchanged" }
    function f.subsystem:GetWidgetSlot(item)
        assert(item == f.main_hud)
        return f.slot
    end
    function f.subsystem:SetWidgetSlot(item, slot)
        assert(item == f.main_hud and slot == f.slot)
        f.slot_restores = f.slot_restores + 1
    end
    f.widget_library = object()
    function f.widget_library:Create(world, class, owner)
        assert(world == f.world and class == f.hud_class and owner == f.secondary)
        f.hud_creates = f.hud_creates + 1
        if options.create_fails then return nil end
        f.guest = hud(options.wrong_owner and f.primary or owner, false)
        f.main_huds[2] = f.guest
        return f.guest
    end
    return f, keys, queued
end

test("HUD split before player creation has no UI side effects", function()
    local f, keys, queued = entrypoint_fixture()
    keys.F4()
    queued[1]()
    assert(f.creates == 0 and f.removes == 0)
    assert(table.concat(f.logs, "\n"):find("F4 needs exactly two", 1, true))
end)

test("HUD experiment uses separate player-owned widgets on the game thread", function()
    local f, keys, queued = hud_fixture()
    keys.F4()
    assert(f.hud_creates == 0 and f.main_hud.mode == "global")
    queued[2]()
    assert(f.hud_creates == 1 and f.main_hud.mode == "player" and f.guest.mode == "player")
    assert(f.main_hud.owner == f.primary and f.guest.owner == f.secondary and f.guest ~= f.main_hud)
    assert(f.secondary.PlayerHUDRef == f.guest and f.guest.OwningCharacter == f.secondary.Pawn)
    assert(f.secondary.Pawn.InventoryReference == f.guest.W_PlayerInventory_Main)
    assert(f.character_at_first_show == f.secondary.Pawn)
    assert(f.primary.PlayerHUDRef == f.main_hud and f.main_hud.OwningCharacter == f.primary.Pawn)
    assert(f.creates == 1 and f.removes == 0)
end)

test("HUD restore removes only the experimental copy and restores the saved slot", function()
    local f, keys, queued = hud_fixture()
    keys.F4()
    queued[2]()
    keys.F3()
    queued[3]()
    assert(f.main_hud.visible and f.main_hud.mode == "global" and f.main_hud.z == 17)
    assert(not f.guest.visible and f.slot_restores == 1)
    assert(f.secondary.PlayerHUDRef == nil and f.primary.PlayerHUDRef == f.main_hud)
    assert(f.secondary.Pawn.InventoryReference == nil)
end)

test("repeated HUD split cannot create another copy", function()
    local f, keys, queued = hud_fixture()
    keys.F4()
    queued[2]()
    keys.F4()
    queued[3]()
    assert(f.hud_creates == 1)
end)

test("failed HUD creation restores the original HUD", function()
    local f, keys, queued = hud_fixture({ create_fails = true })
    keys.F4()
    queued[2]()
    assert(f.main_hud.visible and f.main_hud.mode == "global" and f.slot_restores == 1)
    assert(table.concat(f.logs, "\n"):find("separate second HUD was not created", 1, true))
end)

test("failed guest screen insertion rolls back both widgets", function()
    local f, keys, queued = hud_fixture({ guest_add_fails = true })
    keys.F4()
    queued[2]()
    assert(f.main_hud.visible and f.main_hud.mode == "global" and not f.guest.visible)
    assert(f.slot_restores == 1)
end)

test("HUD with an incorrect owner is never displayed", function()
    local f, keys, queued = hud_fixture({ wrong_owner = true })
    keys.F4()
    queued[2]()
    assert(not f.guest.visible and f.main_hud.mode == "global")
end)

test("player removal restores the HUD before removing player two", function()
    local f, keys, queued = hud_fixture()
    keys.F4()
    queued[2]()
    keys.F8()
    queued[3]()
    assert(not f.guest.visible and f.main_hud.mode == "global" and f.slot_restores == 1)
    assert(f.removes == 1 and #f.instance.LocalPlayers == 1)
end)

test("a pre-existing second HUD is preserved and not duplicated", function()
    local f, keys, queued = hud_fixture()
    f.main_huds[2] = widget(f.secondary, true)
    keys.F4()
    queued[2]()
    assert(f.hud_creates == 0 and f.main_hud.mode == "global")
    assert(table.concat(f.logs, "\n"):find("HUD already belongs to player two", 1, true))
end)

print(string.format("%d tests passed (mock Unreal API; no in-game validation).", tests_run))
