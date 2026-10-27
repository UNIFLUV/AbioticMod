local Runtime = require("player_bindings")
local serial, passed = 0, 0
local function object(fields)
    serial = serial + 1
    local value = fields or {}
    value.address = serial
    function value:IsValid() return self.alive ~= false end
    function value:GetAddress() return self.address end
    function value:GetFullName() return "Fixture " .. self.address end
    return value
end

local function class(fields)
    local value = object()
    function value:ForEachProperty(callback)
        for name, kind in pairs(fields) do
            local property = object()
            function property:GetFName() return { ToString = function() return name end } end
            function property:GetFullName() return kind .. " Fixture:" .. name end
            if callback(property) == true then break end
        end
    end
    function value:GetSuperStruct() return nil end
    function value:ForEachFunction() end
    return value
end

local function typed(fields, schema)
    local value = object(fields)
    local type_class = class(schema or {})
    function value:GetClass() return type_class end
    return value
end

local function fixture(options)
    options = options or {}
    local f = { logs = {}, hooks = {}, timers = {}, paused = options.prepaused == true, pause_calls = {}, pair_calls = 0 }
    f.world, f.instance = object(), object()
    f.first = typed({}, { MyPlayerCharacter = "ObjectProperty", PlayerCharacter = "ObjectProperty" })
    f.second = typed({}, { MyPlayerCharacter = "ObjectProperty", PlayerCharacter = "ObjectProperty", MyHUD = "ObjectProperty", TargetHUD = "ObjectProperty" })
    f.first.Pawn = typed({}, {})
    f.second.Pawn = typed({}, { MyController = "ObjectProperty", MyTargetCharacter = "ObjectProperty" })
    function f.second.Pawn:IsLocallyControlled() return not options.not_local end
    f.first.MyPlayerCharacter, f.first.PlayerCharacter = f.first.Pawn, f.first.Pawn
    f.second.MyPlayerCharacter, f.second.PlayerCharacter = f.first.Pawn, f.first.Pawn
    f.second.Pawn.MyController, f.second.Pawn.MyTargetCharacter = f.first, f.first.Pawn
    f.first.PlayerState = object({ UniquePlayerID = "ACCOUNT-PRIVATE", PlayerSaveID = "SAVE-PRIVATE" })
    f.second.PlayerState = object({ UniquePlayerID = "ACCOUNT-PRIVATE", PlayerSaveID = "GUEST-SAVE-PRIVATE" })
    local function hud(owner)
        local value = typed({ owner = owner, OwningCharacter = f.first.Pawn, mode = "player", visible = true }, { OwningCharacter = "ObjectProperty" })
        value.W_EscapeMenu_Main = object({ visibility = 1 })
        function value.W_EscapeMenu_Main:GetVisibility() return self.visibility end
        function value.W_EscapeMenu_Main:SetVisibility(v) self.visibility = v end
        value.W_EscapeMenu_Main.GamePausedText = object({ visibility = 0 })
        function value.W_EscapeMenu_Main.GamePausedText:GetVisibility() return self.visibility end
        function value.W_EscapeMenu_Main.GamePausedText:SetVisibility(v) self.visibility = v end
        function value:GetOwningPlayer() return self.owner end
        function value:RemoveFromParent() self.visible = false end
        function value:AddToViewport(z)
            if options.insert_fails then error("viewport insertion failed") end
            self.mode, self.visible, self.z = "global", true, z
            self.W_EscapeMenu_Main.visibility = 1 -- Simulate a Construct reset.
        end
        function value:AddToPlayerScreen(z)
            self.mode, self.visible, self.z = "player", true, z
            self.W_EscapeMenu_Main.visibility = 1
            return true
        end
        function value:IsInViewport() return self.visible end
        return value
    end
    f.main, f.guest = hud(f.first), hud(f.second)
    f.second.MyHUD, f.second.TargetHUD = f.main, f.main
    f.hud_state = { main = f.main, guest = f.guest }
    function f.first:CloseEscapeMenuAndResumeGame() f.main.W_EscapeMenu_Main.visibility = 1 end
    function f.second:CloseEscapeMenuAndResumeGame() f.guest.W_EscapeMenu_Main.visibility = 1 end
    f.subsystem = object()
    f.slot = { ZOrder = 17 }
    function f.subsystem:GetWidgetSlot() return f.slot end
    function f.subsystem:SetWidgetSlot(hud, slot) assert(slot == f.slot); f.last_restored_hud = hud end
    f.statics = object()
    function f.statics:IsGamePaused(world) assert(world == f.world); return f.paused end
    function f.statics:GetRealTimeSeconds() return f.time or 10 end
    function f.statics:GetPlayerControllerID(controller) return controller == f.second and 0 or 1 end
    function f.statics:SetGamePaused(world, paused)
        assert(world == f.world)
        f.pause_calls[#f.pause_calls + 1] = paused
        if options.pause_denied and paused then return false end
        f.paused = paused
        return true
    end
    function f.instance:MappingsChanged(controller)
        assert(controller == f.first or controller == f.second)
        f.mapping_refreshes = (f.mapping_refreshes or 0) + 1
    end
    local function signature(path)
        local func = class(options.bad_return and { ReturnValue = "ObjectProperty" } or { ReturnValue = "BoolProperty" })
        return func
    end
    f.api = {
        pair = function()
            f.pair_calls = f.pair_calls + 1
            return { world = f.world, instance = f.instance, statics = f.statics }, f.first, f.second
        end,
        huds = function() return f.hud_state end,
        find = signature,
        find_first = function(name) assert(name == "GameViewportSubsystem"); return f.subsystem end,
        log = function(message) f.logs[#f.logs + 1] = message end,
        hook = function(path, before, after) f.hooks[path] = after or before end,
        delay = function(ms, callback) f.timers[#f.timers + 1] = callback end,
        game_thread = function(callback) callback() end,
        guest_active = function() return not options.host_active end,
        fname = function(name) return name end,
    }
    f.runtime = Runtime.new(f.api)
    return f
end

local function test(name, callback)
    callback()
    passed = passed + 1
    print("PASS " .. name)
end

test("repair updates only guest ownership caches and preserves interaction targets", function()
    local f = fixture()
    f.runtime:repair()
    assert(f.second.MyPlayerCharacter == f.second.Pawn and f.second.PlayerCharacter == f.second.Pawn)
    assert(f.second.MyHUD == f.guest and f.guest.OwningCharacter == f.second.Pawn)
    assert(f.second.Pawn.MyController == f.second)
    assert(f.second.Pawn.MyTargetCharacter == f.first.Pawn and f.second.TargetHUD == f.main)
    assert(f.first.MyPlayerCharacter == f.first.Pawn and f.main.OwningCharacter == f.first.Pawn)
end)

test("unknown foreign character references are not overwritten", function()
    local f = fixture()
    local foreign = object()
    f.second.MyPlayerCharacter = foreign
    f.runtime:repair()
    assert(f.second.MyPlayerCharacter == foreign)
end)

test("native mapping refresh is scoped to the two validated controllers", function()
    local f = fixture()
    f.runtime:refresh_mappings()
    assert(f.mapping_refreshes == 2)
end)

test("predicate hooks apply only to the locally controlled guest without scanning the world", function()
    local f = fixture()
    f.runtime:repair()
    f.runtime:install_local_hooks()
    local count = f.pair_calls
    for _, callback in pairs(f.hooks) do
        assert(callback({ get = function() return f.second.Pawn end }) == true)
        assert(callback({ get = function() return f.first.Pawn end }) == nil)
        assert(callback({ get = function() return object() end }) == nil)
    end
    assert(f.pair_calls == count)
end)

test("predicate hooks preserve nonlocal and unknown return types", function()
    local f = fixture({ not_local = true })
    f.runtime:repair()
    f.runtime:install_local_hooks()
    for _, callback in pairs(f.hooks) do assert(callback({ get = function() return f.second.Pawn end }) == nil) end
    local g = fixture({ bad_return = true })
    g.runtime:repair()
    g.runtime:install_local_hooks()
    assert(next(g.hooks) == nil)
end)

test("predicate overrides remain disabled for a shared or empty guest save namespace", function()
    local f = fixture()
    f.runtime:repair()
    f.runtime:install_local_hooks()
    f.second.PlayerState.PlayerSaveID = f.first.PlayerState.PlayerSaveID
    for _, callback in pairs(f.hooks) do assert(callback({ get = function() return f.second.Pawn end }) == nil) end
    f.second.PlayerState.PlayerSaveID = ""
    for _, callback in pairs(f.hooks) do assert(callback({ get = function() return f.second.Pawn end }) == nil) end
    assert(f.first.PlayerState.PlayerSaveID == "SAVE-PRIVATE")
end)

test("identifier diagnostics compare values without printing account or save strings", function()
    local f = fixture()
    f.runtime:snapshot()
    local logs = table.concat(f.logs, "\n")
    assert(logs:find("PROFILE PlayerSaveID equal=false", 1, true))
    assert(not logs:find("ACCOUNT-PRIVATE", 1, true) and not logs:find("SAVE-PRIVATE", 1, true))
end)

test("Esc moves only the opened HUD to full viewport and pauses the world", function()
    local f = fixture()
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    assert(f.main.mode == "global" and f.main.z == 10000 and f.guest.mode == "player")
    assert(f.main.W_EscapeMenu_Main.visibility == 0 and f.paused)
    assert(f.main.W_EscapeMenu_Main.GamePausedText.visibility == 1)
    assert(f.runtime.pause ~= nil)
end)

test("closing Esc restores layout and releases only the pause created by this mod", function()
    local f = fixture()
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.runtime:close_pause()
    assert(f.runtime.pause == nil and not f.paused and f.main.mode == "player")
    assert(f.main.z == 17 and f.main.W_EscapeMenu_Main.visibility == 1)
    assert(f.main.W_EscapeMenu_Main.GamePausedText.visibility == 0)
    assert(f.pause_calls[1] == true and f.pause_calls[2] == false)
end)

test("a second player's Esc uses the guest's HUD and owner", function()
    local f = fixture()
    f.guest.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    assert(f.runtime.pause.owner == f.second and f.guest.mode == "global" and f.main.mode == "player")
    f.runtime:close_pause()
    assert(f.guest.mode == "player" and not f.paused)
end)

test("pre-existing pause is not released by layout restoration", function()
    local f = fixture({ prepaused = true })
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.runtime:close_pause()
    assert(f.paused and #f.pause_calls == 0)
end)

test("pause refusal is reported without claiming a frozen world", function()
    local f = fixture({ pause_denied = true })
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    assert(not f.paused and f.main.mode == "global")
    assert(f.main.W_EscapeMenu_Main.GamePausedText.visibility == 0)
    assert(table.concat(f.logs, "\n"):find("world paused=false", 1, true))
end)

test("a failed fullscreen insertion restores player layout before propagating the error", function()
    local f = fixture({ insert_fails = true })
    f.main.W_EscapeMenu_Main.visibility = 0
    local ok = pcall(function() f.runtime:poll_pause() end)
    assert(not ok and f.main.mode == "player" and not f.paused and f.runtime.pause == nil)
end)

test("HUD teardown releases a mod-owned pause without moving a restored global HUD", function()
    local f = fixture()
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.hud_state = nil
    f.runtime:poll_pause()
    assert(not f.paused and f.main.mode == "global" and f.runtime.pause == nil)
end)

test("stopped pause watchers cannot change UI when a stale timer fires", function()
    local f = fixture()
    f.runtime:watch_pause()
    f.runtime:stop()
    f.main.W_EscapeMenu_Main.visibility = 0
    f.timers[1]()
    assert(f.main.mode == "player" and not f.paused and f.runtime.pause == nil)
end)

local function input_fixture(options)
    local f = fixture(options)
    f.forwarded = 0
    local funcs = {}
    for _, kind in ipairs({ "Inventory", "EscapeMenu" }) do
        local name = "InpActEvt_" .. kind .. "_K2Node_InputActionEvent_23"
        local func = class({ Key = "StructProperty" })
        function func:GetFName() return { ToString = function() return name end } end
        function func:GetFullName() return "Function /Game/Controller.Controller_C:" .. name end
        setmetatable(func, { __call = function(_, controller, key)
            assert(controller == f.second and (key.KeyName == "Tab" or key.KeyName == "Escape"))
            f.forwarded = f.forwarded + 1
        end })
        funcs[#funcs + 1] = func
    end
    local controller_class = f.second:GetClass()
    function controller_class:ForEachFunction(callback)
        for _, func in ipairs(funcs) do if callback(func) == true then break end end
    end
    f.runtime:repair()
    f.runtime:install_input_hooks()
    return f, funcs
end

test("missing native menu input is forwarded to the owned guest after a guarded delay", function()
    local f = input_fixture()
    f.runtime:key_action("inventory")
    assert(f.forwarded == 0 and #f.timers == 1)
    f.time = 10.12
    f.timers[1]()
    assert(f.forwarded == 1)
end)

test("a native guest input event prevents a double menu toggle", function()
    local f, funcs = input_fixture()
    f.runtime:key_action("inventory")
    f.time = 10.03
    f.hooks[funcs[1]:GetFullName():gsub("^Function ", "")]({ get = function() return f.second end })
    f.time = 10.12
    f.timers[1]()
    assert(f.forwarded == 0)
end)

test("a host event during guest handoff is diagnosed without opening a second inventory", function()
    local f, funcs = input_fixture()
    f.runtime:key_action("inventory")
    f.time = 10.03
    f.hooks[funcs[1]:GetFullName():gsub("^Function ", "")]({ get = function() return f.first end })
    f.time = 10.12
    f.timers[1]()
    assert(f.forwarded == 0)
    assert(table.concat(f.logs, "\n"):find("action reached the host", 1, true))
end)

test("pending input fallback is cancelled when control returns to the host", function()
    local options = {}
    local f = input_fixture(options)
    f.runtime:key_action("inventory")
    options.host_active = true
    f.timers[1]()
    assert(f.forwarded == 0)
end)

test("input fallback never runs while the shared pause menu is active", function()
    local f = input_fixture()
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.runtime:key_action("inventory")
    assert(#f.timers == 0 and f.forwarded == 0)
end)

test("opening pause cancels an inventory fallback already waiting on its timer", function()
    local f = input_fixture()
    f.runtime:key_action("inventory")
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.timers[1]()
    assert(f.forwarded == 0 and f.runtime.pause ~= nil)
end)

test("pause cleanup can release its world pause even if player two disappeared", function()
    local f = fixture()
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.api.context = function() return { world = f.world, statics = f.statics } end
    f.api.pair = function() error("second player disappeared") end
    f.runtime:leave_pause(true)
    assert(not f.paused and f.runtime.pause == nil)
end)

test("close restores game-only input through the confirmed native argument names", function()
    local f = fixture()
    local native = class({ bFlushInput = "BoolProperty", PlayerController = "ObjectProperty" })
    local library = object()
    local calls = 0
    setmetatable(native, { __call = function(_, context, controller, flush)
        assert(context == library and controller == f.first and flush == true)
        calls = calls + 1
    end })
    f.api.find = function(path)
        if path == "/Script/UMG.WidgetBlueprintLibrary:SetInputMode_GameOnly" then return native end
        if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return library end
        return nil
    end
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.runtime:close_pause()
    assert(calls == 1 and f.first.bShowMouseCursor == false and not f.paused)
end)

test("a reentrant pause observer cannot restore the same HUD twice during native unpause", function()
    local f = fixture()
    local original_pause = f.statics.SetGamePaused
    function f.statics:SetGamePaused(world, paused)
        local result = original_pause(self, world, paused)
        if not paused then f.runtime:poll_pause() end
        return result
    end
    local restores = 0
    local original_slot = f.subsystem.SetWidgetSlot
    function f.subsystem:SetWidgetSlot(hud, slot)
        restores = restores + 1
        original_slot(self, hud, slot)
    end
    f.main.W_EscapeMenu_Main.visibility = 0
    f.runtime:poll_pause()
    f.runtime:close_pause()
    assert(restores == 1 and not f.paused and f.runtime.pause == nil)
end)

print(string.format("%d binding/pause tests passed (mock API; game animation, UI and persistence still require in-game validation).", passed))
