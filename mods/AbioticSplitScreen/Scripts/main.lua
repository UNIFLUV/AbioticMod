local Probe = require("split_probe")
local probe = Probe.new({
    FindFirstOf = FindFirstOf,
    StaticFindObject = StaticFindObject,
    log = function(message) print("[AbioticSplitScreen] " .. message .. "\n") end,
})

local function log(message)
    print("[AbioticSplitScreen] " .. message .. "\n")
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function same(left, right)
    return valid(left) and valid(right) and left:GetAddress() == right:GetAddress()
end

local function name(object)
    return valid(object) and object:GetFullName() or "NONE"
end

local function vector(value)
    return string.format("X=%.1f Y=%.1f Z=%.1f", value.X, value.Y, value.Z)
end

local function report(label, read)
    local ok, value = pcall(read)
    log(label .. ": " .. (ok and tostring(value) or ("unavailable: " .. tostring(value))))
end

local function inspect_cameras()
    local context = probe:context()
    for index = 0, #context.instance.LocalPlayers - 1 do
        local controller = context.statics:GetPlayerController(context.world, index)
        if valid(controller) then
            local prefix = "Player " .. index .. " "
            report(prefix .. "controller ID", function() return controller.Player.ControllerId end)
            report(prefix .. "pawn location", function() return vector(controller.Pawn:K2_GetActorLocation()) end)
            report(prefix .. "view target", function() return name(controller:GetViewTarget()) end)
            report(prefix .. "camera manager", function() return name(controller.PlayerCameraManager) end)
            report(prefix .. "camera location", function()
                return vector(controller.PlayerCameraManager:GetCameraLocation())
            end)
            report(prefix .. "camera fade", function() return controller.PlayerCameraManager.FadeAmount end)
        end
    end
end

-- Explicit experiment for a black second view. Never run this automatically: it can interrupt a cinematic.
local function repair_second_camera()
    local context = probe:context()
    assert(#context.instance.LocalPlayers == 2, "F9 needs exactly two local players; use F7 first.")
    local controller = context.statics:GetPlayerController(context.world, 1)
    assert(same(probe.instance, context.instance) and same(probe.controller, controller),
        "Cannot identify this probe's second player; restart the game rather than using hot reload.")
    local pawn = controller.Pawn
    local primary = context.statics:GetPlayerController(context.world, 0)
    assert(valid(primary) and valid(pawn) and not same(pawn, primary.Pawn),
        "Player two needs a separate valid pawn before repairing its camera.")
    local camera = controller.PlayerCameraManager
    assert(valid(camera), "Player two has no camera manager.")
    assert(valid(StaticFindObject("/Script/Engine.PlayerController:SetViewTargetWithBlend")),
        "SetViewTargetWithBlend is not available.")
    assert(valid(StaticFindObject("/Script/Engine.PlayerCameraManager:StopCameraFade")),
        "StopCameraFade is not available.")
    inspect_cameras()
    controller:SetViewTargetWithBlend(pawn, 0.0, 0, 1.0, false)
    camera:StopCameraFade()
    log("F9 requested player two's own pawn as view target and stopped its camera fade. Verify the image in-game.")
    inspect_cameras()
end

-- Key callbacks are not assumed to run on Unreal's game thread.
local busy = false
local function dispatch(action)
    if busy then return end
    busy = true
    local scheduled, scheduling_error = pcall(ExecuteInGameThread, function()
        local ok, message = pcall(action)
        busy = false
        if not ok then print("[AbioticSplitScreen] ERROR: " .. tostring(message) .. "\n") end
    end)
    if not scheduled then
        busy = false
        print("[AbioticSplitScreen] Cannot schedule game-thread task: " .. tostring(scheduling_error) .. "\n")
    end
end

RegisterKeyBind(Key.F6, function() dispatch(function() probe:diagnose(); inspect_cameras() end) end)
RegisterKeyBind(Key.F7, function() dispatch(function() probe:add_player(); inspect_cameras() end) end)
RegisterKeyBind(Key.F8, function() dispatch(function() probe:remove_player() end) end)
RegisterKeyBind(Key.F9, function() dispatch(repair_second_camera) end)
log("Experimental probe v0.2 loaded. F6: diagnose cameras; F7: add player; F8: remove; F9: reset second camera.")

-- v0.3: opt-in spawn experiment; never move either player automatically.
local function move_second_near_primary()
    local context = probe:context()
    assert(#context.instance.LocalPlayers == 2, "F5 needs exactly two local players; use F7 first.")
    local second = context.statics:GetPlayerController(context.world, 1)
    local first = context.statics:GetPlayerController(context.world, 0)
    assert(same(probe.instance, context.instance) and same(probe.controller, second),
        "Cannot identify this probe's second player; restart the game.")
    assert(valid(first) and valid(first.Pawn) and valid(second.Pawn) and
        not same(first.Pawn, second.Pawn), "Two separate valid pawns are required.")
    assert(valid(StaticFindObject("/Script/Engine.Actor:K2_TeleportTo")),
        "K2_TeleportTo is not available.")
    local origin = first.Pawn:K2_GetActorLocation()
    local right = first.Pawn:GetActorRightVector()
    local destination = {
        X = origin.X + right.X * 200.0,
        Y = origin.Y + right.Y * 200.0,
        Z = origin.Z + 5.0,
    }
    log("F5 player two before: " .. vector(second.Pawn:K2_GetActorLocation()))
    log("F5 requested destination: " .. vector(destination))
    local moved = second.Pawn:K2_TeleportTo(destination, first.Pawn:K2_GetActorRotation())
    assert(moved == true, "Teleport was not confirmed; do not force movement through collision.")
    log("F5 player two after: " .. vector(second.Pawn:K2_GetActorLocation()))
    log("F5 teleport returned true. Wait a few seconds, press F6, and verify player two's image and controls.")
end

RegisterKeyBind(Key.F5, function() dispatch(move_second_near_primary) end)
log("Experimental probe v0.3 add-on loaded. F5: move player two near player one with collision checking.")

-- v0.4: read-only HUD inspection. Do not reparent unidentified UI or alter widget ownership.
local original_diagnose = probe.diagnose
function probe:diagnose()
    original_diagnose(self)
    report("HUD scan", function()
        local context = self:context()
        local first = context.statics:GetPlayerController(context.world, 0)
        local second = context.statics:GetPlayerController(context.world, 1)
        local widgets = FindAllOf("UserWidget") or {}
        local roots, errors = 0, 0
        for _, widget in ipairs(widgets) do
            local ok, in_viewport = pcall(function() return valid(widget) and widget:IsInViewport() end)
            if not ok then errors = errors + 1 end
            if ok and in_viewport == true then
                roots = roots + 1
                local prefix = "HUD root " .. roots .. " "
                log(prefix .. name(widget))
                report(prefix .. "owner", function()
                    local owner = widget:GetOwningPlayer()
                    if same(owner, first) then return "Player 0" end
                    if same(owner, second) then return "Player 1" end
                    return name(owner)
                end)
                report(prefix .. "visibility", function() return widget:GetVisibility() end)
                report(prefix .. "parent", function() return name(widget:GetParent()) end)
                if roots >= 40 then
                    log("HUD output capped at 40 roots; scan is incomplete.")
                    break
                end
            end
        end
        return string.format("%d widget instances; %d viewport roots reported; %d filter errors", #widgets, roots, errors)
    end)
end
log("Experimental probe v0.4 HUD diagnostics loaded. F6 also lists viewport widgets and owners.")

-- v0.5: opt-in HUD layout experiment. Blueprint data bindings still need in-game validation.
local hud_trial
local function restore_hud()
    if not hud_trial then return end
    local trial = hud_trial
    local context = probe:context()
    assert(same(trial.instance, context.instance) and
        same(trial.first, context.statics:GetPlayerController(context.world, 0)),
        "HUD context changed; restart the game instead of restoring old widgets.")
    if valid(trial.guest) then trial.guest:RemoveFromParent() end
    assert(valid(trial.main), "Original HUD expired; restart the game.")
    trial.main:RemoveFromParent()
    trial.main:AddToViewport(trial.z)
    trial.subsystem:SetWidgetSlot(trial.main, trial.slot)
    assert(trial.main:IsInViewport(), "Original HUD restoration was not confirmed.")
    hud_trial = nil
    log("Original HUD restored; experimental second HUD removed.")
end

local before_guest_hud_visible
local function split_hud()
    assert(not hud_trial, "HUD experiment already ran; F3 restores it before another attempt.")
    local context = probe:context()
    assert(#context.instance.LocalPlayers == 2, "F4 needs exactly two local players; use F7 first.")
    local first = context.statics:GetPlayerController(context.world, 0)
    local second = context.statics:GetPlayerController(context.world, 1)
    assert(valid(first) and same(probe.instance, context.instance) and same(probe.controller, second),
        "Cannot identify this probe's players; restart the game.")
    local main
    for _, widget in ipairs(FindAllOf("W_PlayerHUD_Main_C") or {}) do
        if valid(widget) then
            assert(not same(widget:GetOwningPlayer(), second), "A HUD already belongs to player two; refusing to duplicate it.")
            if widget:IsInViewport() and same(widget:GetOwningPlayer(), first) then
                assert(main == nil, "Multiple primary HUDs found; refusing to guess.")
                main = widget
            end
        end
    end
    assert(valid(main), "No active W_PlayerHUD_Main_C owned by player one was found.")
    local subsystem = FindFirstOf("GameViewportSubsystem")
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    assert(valid(subsystem) and valid(library), "UMG viewport subsystem or widget library is unavailable.")
    for _, path in ipairs({
        "/Script/UMG.UserWidget:AddToPlayerScreen", "/Script/UMG.UserWidget:AddToViewport",
        "/Script/UMG.Widget:RemoveFromParent", "/Script/UMG.WidgetBlueprintLibrary:Create",
        "/Script/UMG.GameViewportSubsystem:GetWidgetSlot", "/Script/UMG.GameViewportSubsystem:SetWidgetSlot",
    }) do assert(valid(StaticFindObject(path)), "Missing reflected UI function: " .. path) end
    local slot = subsystem:GetWidgetSlot(main)
    local z = slot.ZOrder
    assert(type(z) == "number", "Cannot read original HUD Z order; refusing to change it.")
    hud_trial = { main = main, subsystem = subsystem, slot = slot, z = z, instance = context.instance, first = first }
    local ok, message = pcall(function()
        main:RemoveFromParent()
        assert(main:AddToPlayerScreen(z) == true, "Player one's HUD could not be added to its player screen.")
        local guest = library:Create(context.world, main:GetClass(), second)
        assert(valid(guest) and not same(guest, main), "A separate second HUD was not created.")
        hud_trial.guest = guest
        assert(same(guest:GetOwningPlayer(), second), "Created HUD has the wrong owner.")
        if before_guest_hud_visible then before_guest_hud_visible() end
        assert(guest:AddToPlayerScreen(z) == true, "Player two's HUD could not be added to its player screen.")
        assert(same(guest:GetOwningPlayer(), second), "HUD owner changed during construction.")
        log("F4 HUD layout experiment applied: " .. name(main) .. " / " .. name(guest))
        log("Verify both HUDs in-game. Independent health/inventory bindings and popup layout are NOT yet verified. F3 restores the original HUD.")
    end)
    if not ok then
        local restored, restoration_error = pcall(restore_hud)
        if not restored then log("HUD rollback failed: " .. tostring(restoration_error) .. "; restart the game.") end
        error(message)
    end
end

local original_remove_player = probe.remove_player
function probe:remove_player()
    restore_hud()
    original_remove_player(self)
end
RegisterKeyBind(Key.F4, function() dispatch(split_hud) end)
RegisterKeyBind(Key.F3, function() dispatch(restore_hud) end)
log("Experimental probe v0.5 HUD layout loaded. F4: trial two HUDs; F3: restore original HUD.")

-- v0.6: combined startup, test input handoff, read-only menu/profile discovery.
local SessionTools = require("session_tools")
local session = SessionTools.new({
    probe = probe, log = log, find = StaticFindObject, find_all = FindAllOf,
    delay = ExecuteWithDelay, game_thread = ExecuteInGameThread,
    add_player = function() probe:add_player() end,
    move_second = move_second_near_primary, split_hud = split_hud,
    hud_active = function() return hud_trial ~= nil end,
    hud_ready = function()
        local context = probe:context()
        local first = context.statics:GetPlayerController(context.world, 0)
        for _, widget in ipairs(FindAllOf("W_PlayerHUD_Main_C") or {}) do
            if valid(widget) and widget:IsInViewport() and same(widget:GetOwningPlayer(), first) then return true end
        end
        return false
    end,
})
local manual_diagnose = probe.diagnose
function probe:diagnose()
    manual_diagnose(self)
    local ok, message = pcall(function() session:describe() end)
    if not ok then log("SDK scan unavailable: " .. tostring(message)) end
end
local manual_remove_player = probe.remove_player
function probe:remove_player()
    session:cancel()
    session:restore_input()
    manual_remove_player(self)
end
RegisterKeyBind(Key.F1, function() dispatch(function() session:start() end) end)
RegisterKeyBind(Key.F2, function() dispatch(function() session:switch_input() end) end)
log("Experimental probe v0.6 loaded. F1: combined setup; F2: test keyboard/mouse handoff; F6: menu/profile diagnostics. Fullscreen pause and guest persistence are pending.")

-- v0.7: scoped game bindings and shared Esc presentation.
-- Disabled after a reported Fatal error when player two attacked. Keep the
-- earlier F1/F2/HUD behavior while crash logs are collected; Lua mocks cannot
-- validate UE4SS hooks or native gameplay calls in the actual Windows game.
local ENABLE_V07_EXPERIMENT = false
if ENABLE_V07_EXPERIMENT then
local PlayerBindings = require("player_bindings")
local bindings = PlayerBindings.new({
    pair = function() return session:pair() end,
    context = function() return probe:context() end,
    huds = function() return hud_trial end,
    guest_active = function() return session.input_backup ~= nil end, fname = FName,
    find = StaticFindObject, find_first = FindFirstOf,
    hook = RegisterHook, delay = ExecuteWithDelay, game_thread = ExecuteInGameThread, log = log,
})
local setup_finish = session.finish
function session:finish(ticket)
    setup_finish(self, ticket)
    bindings:repair()
    bindings:install_local_hooks()
    bindings:install_input_hooks()
    bindings:refresh_mappings()
    bindings:watch_pause()
end
local switch_input = session.switch_input
function session:switch_input()
    local checked, message = pcall(function() bindings:snapshot() end)
    if not checked then log("BIND snapshot unavailable: " .. tostring(message)) end
    bindings:repair()
    local restoring = self.input_backup ~= nil
    switch_input(self)
    if not restoring then bindings:refresh_mappings() end
end
local restore_input = session.restore_input
function session:restore_input()
    local active = self.input_backup ~= nil
    restore_input(self)
    if active then bindings:refresh_mappings() end
end
local binding_diagnose = probe.diagnose
function probe:diagnose()
    local ok, message = pcall(function() bindings:diagnose() end)
    if not ok then log("BIND diagnostics unavailable: " .. tostring(message)) end
    binding_diagnose(self)
end
local remove_bound_player = probe.remove_player
function probe:remove_player()
    bindings:stop()
    remove_bound_player(self)
end
RegisterKeyBind(0x1B, function()
    if bindings.pause then dispatch(function() bindings:close_pause() end)
    else dispatch(function() bindings:key_action("escape") end) end
end)
RegisterKeyBind(0x09, function() dispatch(function() bindings:key_action("inventory") end) end)
log("Experimental probe v0.7 loaded. F1/F2 repair scoped cached references; shared Esc menu/pause trial enabled. Guest profile creation and persistence remain pending.")
else
    log("v0.7 bindings experiment disabled after a reported native crash. v0.6 F1/F2/HUD behavior retained; collect UE4SS/game crash logs before further trials.")
end

-- v0.7.1: explicit guest controller-to-HUD link; previous v0.7 stays disabled.
local HudLink = require("hud_link")
local hud_link = HudLink.new({pair = function() return session:pair() end, huds = function() return hud_trial end, log = log})
local create_huds = split_hud
split_hud = function()
    create_huds()
    local ok, message = pcall(function() hud_link:bind() end)
    if not ok then restore_hud(); error(message) end
end
session.api.split_hud = split_hud
local teardown_huds = restore_hud
restore_hud = function() hud_link:restore(); teardown_huds() end
local handoff = session.switch_input
function session:switch_input()
    if not self.input_backup then hud_link:bind() end
    handoff(self)
end
local inspect = probe.diagnose
function probe:diagnose()
    local ok, message = pcall(function() hud_link:diagnose() end)
    if not ok then log("HUDLINK diagnostics unavailable: " .. tostring(message)) end
    inspect(self)
end
log("Experimental probe v0.7.1 loaded. Explicit guest HUD link only; v0.7 hooks/pause/input fallbacks removed. Animation and independent profiles remain pending.")

-- v0.7.1d: automatic read-only routing snapshot; no extra diagnostic hotkey required.
local RoutingProbe = require("routing_probe")
local routing_probe = RoutingProbe.new({pair = function() return session:pair() end, huds = function() return hud_trial end, log = log})
local route_handoff = session.switch_input
function session:switch_input()
    route_handoff(self)
    local ok, message = pcall(function() routing_probe:capture() end)
    if not ok then log("ROUTE snapshot unavailable: " .. tostring(message)) end
end
log("Routing diagnostics v0.7.1d loaded. F2 records object references and event signatures automatically; gameplay unchanged.")

-- v0.7.2: bind the pawn's existing inventory UI; inspect its input events.
local InventoryHudLink = require("hud_link")
hud_link = InventoryHudLink.new({pair = function() return session:pair() end, huds = function() return hud_trial end, log = log})
local inventory_input_seen = {}
local function inspect_inventory_input(object)
    if not valid(object) then return end
    local class = object:GetClass()
    for _ = 1, 4 do
        if not valid(class) then break end
        local id = class:GetAddress()
        if not inventory_input_seen[id] then
            inventory_input_seen[id] = true
            local count = 0
            class:ForEachFunction(function(func)
                local key = func:GetFName():ToString():lower()
                if key:find('^inp') or key:find('key', 1, true) or key:find('toggle', 1, true) or key:find('open', 1, true) or key:find('close', 1, true) then
                    count = count + 1
                    if count > 80 then log('INVROUTE input scan truncated'); return true end
                    log('INVROUTE FUNCTION ' .. func:GetFullName())
                    local n = 0
                    func:ForEachProperty(function(p)
                        n = n + 1
                        if n > 12 then log('INVROUTE metadata truncated'); return true end
                        log('INVROUTE FIELD ' .. p:GetFullName())
                    end)
                end
            end)
        end
        class = class:GetSuperStruct()
    end
end
local previous_capture = routing_probe.capture
function routing_probe:capture()
    previous_capture(self)
    local _, first, second = session:pair()
    local h = hud_trial or {}
    log('INVROUTE BEGIN')
    for i, hud in ipairs({h.main, h.guest}) do
        if valid(hud) and valid(hud.W_PlayerInventory_Main) then
            local widget = hud.W_PlayerInventory_Main
            self:object('Inventory' .. (i-1), widget)
            log('INVROUTE owner ' .. (i-1) .. ' ' .. name(widget:GetOwningPlayer()))
            inspect_inventory_input(widget)
        end
    end
    inspect_inventory_input(first.Pawn)
    inspect_inventory_input(second.Pawn)
    log('INVROUTE END')
end
log('Experimental probe v0.7.2 loaded. Guest pawn inventory UI link enabled; animation, shared pause and independent saves remain pending.')

-- v0.7.3: character ownership inside inventory widgets, keyboard focus and cursor.
local InventoryUi = require("inventory_ui")
local inventory_ui = InventoryUi.new({pair=function() return session:pair() end, huds=function() return hud_trial end,
    guest_active=function() return session.input_backup~=nil end, find=StaticFindObject,
    delay=ExecuteWithDelay, game_thread=ExecuteInGameThread, log=log})
local link_inventory = hud_link.bind
function hud_link:bind() inventory_ui:bind(); link_inventory(self) end
local unlink_inventory = hud_link.restore
function hud_link:restore() inventory_ui:restore(); unlink_inventory(self) end
before_guest_hud_visible=function() hud_link:bind() end
local focused_handoff = session.switch_input
function session:switch_input()
    inventory_ui.generation=inventory_ui.generation+1
    focused_handoff(self)
    local ok,message=pcall(function() inventory_ui:sync() end)
    if not ok then log('UIFOCUS handoff: ' .. tostring(message)) end
end
RegisterKeyBind(0x09,function() dispatch(function() inventory_ui:key('tab') end) end)
RegisterKeyBind(0x1B,function() dispatch(function() inventory_ui:key('escape') end) end)
log('Experimental probe v0.7.3 loaded. Inventory UI character links and focus/cursor trial; Esc retries the owned close handler when needed. Independent saves and animation remain pending.')

-- v0.7.4: displayed-widget checks and owned inventory close remain active.
-- The user's v0.7.4 log ends inside the marker scan after F2; the user
-- confirmed a crash/hang. Disable the entire automatic marker experiment,
-- including enumeration and restoration, until native evidence is available.
local ENABLE_WAYPOINT_EXPERIMENT = false
if ENABLE_WAYPOINT_EXPERIMENT then
local WaypointUi = require("waypoint_ui")
local waypoint_ui = WaypointUi.new({pair=function() return session:pair() end, huds=function() return hud_trial end, find_all=FindAllOf, log=log})
local marker_handoff = session.switch_input
function session:switch_input()
    marker_handoff(self)
    local ok,message=pcall(function() waypoint_ui:repair() end)
    if not ok then log('WAYPOINT unavailable: '..tostring(message)) end
end
local marker_teardown = hud_link.restore
function hud_link:restore() waypoint_ui:restore(); marker_teardown(self) end
end
local completed_handoff = session.switch_input
function session:switch_input()
    completed_handoff(self)
    log('F2 handoff complete; automatic waypoint scan disabled.')
end
log('Experimental probe v0.7.4a loaded. Automatic waypoint experiment disabled after a reported crash/hang during its scan. Inventory ownership, focus and owned safe-close trial retained. Marker projection, shared pause, animation and profiles remain pending.')
log('Experimental probe v0.7.5 loaded. Guest Tab/Esc close fallback uses its own Pawn.ToggleInventory with ForceClose=true; settled visibility is logged. Waypoint scan remains disabled. Native closure still needs game validation.')

-- Recovery: run the user-verified v0.7.5 UI path; no v0.8 modules or hooks.
log('v0.8.1 recovery base retained. Legacy v0.8 native UI/projection/pause hooks, container_ui and preview_ui remain disabled. User-verified v0.7.5 inventory close retained; independent profiles remain unfinished.')

-- v0.8.2: isolate container repair from the disabled native-hook experiments.
local ContainerHandoff=require('container_handoff')
local ContainerEvents=require('container_delegates')
local container_events=ContainerEvents.new({pair=function() return session:pair() end,
    huds=function() return hud_trial end,
    bind=function() inventory_ui:bind() end,log=log})
local container_handoff=ContainerHandoff.new({pair=function() return session:pair() end,
    huds=function() return hud_trial end,guest_active=function() return session.input_backup~=nil end,
    visible=InventoryUi.visible,property=InventoryUi.property,find=StaticFindObject,
    delay=ExecuteWithDelay,game_thread=ExecuteInGameThread,log=log,
    bind_container=function(component) return container_events:repair(component) end,
    sync=function() inventory_ui:sync() end})
local inventory_sync=inventory_ui.sync
function inventory_ui:sync()
    inventory_sync(self)
    local ok,message=pcall(function() container_handoff:remember() end)
    if not ok then log('CONTAINER prior state unavailable: '..tostring(message)) end
end
local inventory_key=inventory_ui.key
function inventory_ui:key(kind) container_handoff:cancel(); inventory_key(self,kind) end
local container_switch=session.switch_input
function session:switch_input() container_handoff:cancel(); container_switch(self) end
local container_restore=hud_link.restore
function hud_link:restore() container_handoff:clear(); container_events:clear(); container_restore(self) end
RegisterKeyBind(0x45,function() dispatch(function() container_handoff:key() end) end)
log('Experimental probe v0.8.2a container-only trial loaded. Guest container open/close was observed in v0.8.2; an absent E target is now re-read once after native interaction. Valid mismatched targets still block handoff. Native hooks, shared pause, marker and preview experiments remain disabled. Independent profiles remain unfinished.')
log('v0.8.3 container cache experiment retired: no matching character/backpack cache fields were found on the container widget and Take All still delivered items to host.')
log('Experimental probe v0.8.4 owned inventory event trial loaded. UE4SS delegate GetBindings/Add/Remove can retarget a proven host UI receiver to its corresponding guest object using the same existing handler. LOOTBIND reports actual bindings; no Broadcast, native hooks, F observer or item/save calls added. Native Take All destination remains unverified.')
