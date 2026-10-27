local Session = {}
Session.__index = Session

local function valid(value)
    return value ~= nil and value:IsValid()
end

local function same(left, right)
    return valid(left) and valid(right) and left:GetAddress() == right:GetAddress()
end

function Session.new(api)
    return setmetatable({ api = api, generation = 0, phase = "idle" }, Session)
end

function Session:pair()
    local context = self.api.probe:context()
    assert(#context.instance.LocalPlayers == 2, "Exactly two local players are required.")
    local first = context.statics:GetPlayerController(context.world, 0)
    local second = context.statics:GetPlayerController(context.world, 1)
    assert(valid(first) and same(self.api.probe.instance, context.instance) and
        same(self.api.probe.controller, second), "Player ownership changed; restart the game.")
    return context, first, second
end

function Session:require_function(path)
    assert(valid(self.api.find(path)), "Required function unavailable: " .. path)
end

function Session:cancel()
    self.generation = self.generation + 1
    self.phase = "idle"
    self.record = nil
end

function Session:schedule(delay, ticket, callback)
    self.api.delay(delay, function()
        if self.generation ~= ticket then return end
        local scheduled, scheduling_error = pcall(self.api.game_thread, function()
            if self.generation ~= ticket then return end
            local ok, message = pcall(callback)
            if not ok then
                self.phase = "failed"
                self.api.log("F1 stopped: " .. tostring(message) .. ". F6 diagnoses; F8 removes the probe player.")
            end
        end)
        if not scheduled then
            self.phase = "failed"
            self.api.log("F1 scheduling failed: " .. tostring(scheduling_error))
        end
    end)
end

function Session:check_record()
    local context, first, second = self:pair()
    assert(self.record and same(self.record.world, context.world) and
        same(self.record.instance, context.instance) and same(self.record.first, first),
        "World or controller changed while starting; no further setup was applied.")
    return context, first, second
end

function Session:finish(ticket)
    self:check_record()
    if not self.api.hud_active() then self.api.split_hud() end
    self.phase = "ready"
    self.api.log("F1 setup complete: second player positioned and two HUDs requested. F2 tests input handoff; F6 diagnoses.")
end

function Session:prepare(ticket, attempt)
    local _, first, second = self:check_record()
    if not valid(first.Pawn) or not valid(second.Pawn) or not self.api.hud_ready() then
        assert(attempt < 32, "Timed out waiting for the second pawn and primary HUD.")
        self:schedule(250, ticket, function() self:prepare(ticket, attempt + 1) end)
        return
    end
    assert(not same(first.Pawn, second.Pawn), "Both controllers refer to the same pawn.")
    self.api.move_second()
    self.phase = "waiting_hud"
    self:schedule(500, ticket, function() self:finish(ticket) end)
end

function Session:start()
    if self.phase == "waiting_pawn" or self.phase == "waiting_hud" then
        self.api.log("F1 setup is already pending; no additional player was created.")
        return
    end
    assert(self.phase ~= "failed", "The previous F1 attempt failed; use F8 or restart before retrying.")
    assert(type(self.api.delay) == "function" and type(self.api.game_thread) == "function",
        "Delayed game-thread execution is unavailable; keep using the manual F7/F5/F4 workflow.")
    local context = self.api.probe:context()
    if #context.instance.LocalPlayers == 2 then
        self:pair()
        if self.api.hud_active() then
            self.api.log("Two owned players and the HUD experiment are already active; F1 changed nothing.")
            return
        end
    else
        assert(#context.instance.LocalPlayers == 1, "F1 expects one or two local players.")
        local ok, message = pcall(self.api.add_player)
        if not ok then self.phase = "failed"; error(message) end
    end
    local active, first = self:pair()
    self.generation = self.generation + 1
    local ticket = self.generation
    self.record = { world = active.world, instance = active.instance, first = first }
    self.phase = "waiting_pawn"
    self.api.log("F1 created/identified player two; waiting for pawn initialization before placement and HUD setup.")
    local ok, message = pcall(function()
        self:schedule(2000, ticket, function() self:prepare(ticket, 1) end)
    end)
    if not ok then self.phase = "failed"; error(message) end
end

function Session:input_functions()
    self:require_function("/Script/Engine.GameplayStatics:GetPlayerControllerID")
    self:require_function("/Script/Engine.GameplayStatics:SetPlayerControllerID")
end

function Session:restore_input()
    if not self.input_backup then return end
    local context, first, second = self:pair()
    local backup = self.input_backup
    assert(same(backup.instance, context.instance) and same(backup.first, first) and same(backup.second, second),
        "Cannot restore input to different controllers; restart the game.")
    self:input_functions()
    context.statics:SetPlayerControllerID(first, 0)
    assert(context.statics:GetPlayerControllerID(first) == 0 and
        context.statics:GetPlayerControllerID(second) == 1,
        "Input restoration was not confirmed; restart the game.")
    self.input_backup = nil
    self.api.log("F2 input assignment restored: Player 0 uses user index 0; Player 1 uses index 1.")
end

function Session:switch_input()
    if self.input_backup then self:restore_input(); return end
    local context, first, second = self:pair()
    self:input_functions()
    assert(context.statics:GetPlayerControllerID(first) == 0 and
        context.statics:GetPlayerControllerID(second) == 1,
        "Expected user indices 0 and 1; refusing to replace an unknown input mapping.")
    self.input_backup = { instance = context.instance, first = first, second = second }
    local ok, message = pcall(function()
        context.statics:SetPlayerControllerID(second, 0)
        assert(context.statics:GetPlayerControllerID(first) == 1 and
            context.statics:GetPlayerControllerID(second) == 0,
            "Engine did not confirm swapping platform users.")
    end)
    if not ok then
        local restored, restoration_error = pcall(function() self:restore_input() end)
        if not restored then self.api.log("Input rollback failed: " .. tostring(restoration_error)) end
        error(message)
    end
    self.api.log("F2 requested keyboard/mouse user index 0 for Player 1 (bottom). Verify movement and menus; F2 restores Player 0.")
end

local function relevant(name)
    name = name:lower()
    for _, word in ipairs({ "pause", "menu", "switch", "save", "profile", "trait", "perk", "custom", "character", "unique", "playerid" }) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

function Session:metadata(label, object, class)
    if not class then
        if not valid(object) then self.api.log("SDK " .. label .. ": unavailable"); return end
        class = object:GetClass()
    end
    local properties, functions = 0, 0
    for _ = 1, 5 do
        if not valid(class) then break end
        class:ForEachProperty(function(property)
            local field = property:GetFName():ToString()
            if relevant(field) then
                properties = properties + 1
                if properties > 60 then return true end
                self.api.log("SDK " .. label .. " PROPERTY " .. property:GetFullName())
                -- Do not log string values, account identifiers, save contents or passwords.
                if object and (field:lower():find("pause", 1, true) or field:lower():find("menu", 1, true) or field:lower():find("switch", 1, true)) then
                    local ok, value = pcall(function() return object[field] end)
                    if ok and (type(value) == "boolean" or type(value) == "number") then
                        self.api.log("SDK " .. label .. " STATE " .. field .. "=" .. tostring(value))
                    elseif ok and type(value) == "userdata" then
                        local active_ok, active = pcall(function()
                            if value:IsA("/Script/UMG.WidgetSwitcher") then return value:GetActiveWidget() end
                        end)
                        if active_ok and valid(active) then self.api.log("SDK " .. label .. " ACTIVE " .. field .. " -> " .. active:GetFullName()) end
                    end
                end
            end
        end)
        class:ForEachFunction(function(func)
            if relevant(func:GetFName():ToString()) then
                functions = functions + 1
                if functions > 60 then return true end
                self.api.log("SDK " .. label .. " FUNCTION " .. func:GetFullName())
            end
        end)
        if properties > 60 or functions > 60 then
            self.api.log("SDK " .. label .. " output capped; class scan is incomplete.")
            break
        end
        class = class:GetSuperStruct()
    end
end

function Session:describe()
    local context = self.api.probe:context()
    local function describe(label, object, class)
        local ok, message = pcall(function() self:metadata(label, object, class) end)
        if not ok then self.api.log("SDK " .. label .. " unavailable: " .. tostring(message)) end
    end
    describe("GameInstance", context.instance)
    local mode_ok, mode = pcall(function() return context.statics:GetGameMode(context.world) end)
    if mode_ok then describe("GameMode", mode) end
    local pause_ok, paused = pcall(function() return context.statics:IsGamePaused(context.world) end)
    if pause_ok and type(paused) == "boolean" then self.api.log("SDK world paused=" .. tostring(paused)) end
    for _, field in ipairs({ "PlayerSaveClass", "MetaDataSaveClass" }) do
        local ok, class = pcall(function() return context.instance[field] end)
        if ok and valid(class) then describe(field, nil, class) end
    end
    for index = 0, #context.instance.LocalPlayers - 1 do
        local controller = context.statics:GetPlayerController(context.world, index)
        if valid(controller) then
            describe("Controller" .. index, controller)
            describe("PlayerState" .. index, controller.PlayerState)
            describe("Pawn" .. index, controller.Pawn)
        end
    end
    for _, widget in ipairs(self.api.find_all("W_PlayerHUD_Main_C") or {}) do
        if valid(widget) then describe("MainHUD", widget) end
    end
    local count, seen, candidates = 0, {}, {}
    for _, widget in ipairs(self.api.find_all("UserWidget") or {}) do
        if valid(widget) then
            local class = widget:GetClass()
            local name = class:GetFName():ToString():lower()
            if name:find("pause", 1, true) or name:find("escape", 1, true) or name:find("menu", 1, true) or
                name:find("custom", 1, true) or name:find("trait", 1, true) or name:find("perk", 1, true) then
                local priority = 2
                if name:find("pause", 1, true) or name:find("escape", 1, true) then priority = 0
                elseif name:find("custom", 1, true) or name:find("trait", 1, true) or name:find("perk", 1, true) then priority = 1
                elseif name:find("mainmenu", 1, true) then priority = 3 end
                candidates[#candidates + 1] = { widget = widget, class = class, priority = priority }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.priority == b.priority then return a.widget:GetAddress() < b.widget:GetAddress() end
        return a.priority < b.priority
    end)
    for _, candidate in ipairs(candidates) do
        local widget, class = candidate.widget, candidate.class
        count = count + 1
        self.api.log("SDK MENU " .. widget:GetFullName())
        local ok, visibility = pcall(function() return widget:GetVisibility() end)
        if ok then self.api.log("SDK MENU visibility=" .. tostring(visibility)) end
        local id = class:GetAddress()
        if not seen[id] then seen[id] = true; describe("MenuClass", widget) end
        if count >= 25 then self.api.log("SDK menu output capped; scan incomplete."); break end
    end
    self.api.log("SDK read-only scan finished. Pause layout, character creator and independent guest saves remain pending.")
end

return Session
