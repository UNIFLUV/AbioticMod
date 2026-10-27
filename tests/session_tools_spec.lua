local Session = require("session_tools")
local passed, serial = 0, 0
local function object(fields)
    serial = serial + 1
    local item = fields or {}
    item.address = serial
    function item:IsValid() return self.alive ~= false end
    function item:GetAddress() return self.address end
    function item:GetFullName() return "Fixture " .. self.address end
    return item
end

local function fixture(options)
    options = options or {}
    local f = { creates = 0, moves = 0, hud_calls = 0, logs = {}, timers = {}, jobs = {}, now = 0, ids = {} }
    f.world = object()
    f.instance = object({ LocalPlayers = { object() } })
    f.first = object({ Pawn = object() })
    f.statics = object()
    f.ids[f.first] = 0
    function f.statics:GetPlayerController(_, index) return index == 0 and f.first or f.second end
    function f.statics:GetPlayerControllerID(controller) return f.ids[controller] end
    function f.statics:SetPlayerControllerID(controller, id)
        f.input_calls = (f.input_calls or 0) + 1
        if options.swap_throws_once then options.swap_throws_once = false; error("native mapping error") end
        local old = f.ids[controller]
        for other, assigned in pairs(f.ids) do
            if other ~= controller and assigned == id then f.ids[other] = old end
        end
        f.ids[controller] = id
    end
    f.probe = {}
    function f.probe:context() return { world = f.world, instance = f.instance, statics = f.statics } end
    f.api = {
        probe = f.probe,
        log = function(message) f.logs[#f.logs + 1] = message end,
        find = function(path) if path == options.missing_function then return nil end; return object() end,
        find_all = function(class) return f.widgets or {} end,
        add_player = function()
            f.creates = f.creates + 1
            if options.add_fails then error("creation rejected") end
            f.second = object()
            if not options.pawn_delayed then f.second.Pawn = object() end
            f.ids[f.second] = 1
            f.instance.LocalPlayers[2] = object()
            f.probe.instance, f.probe.controller = f.instance, f.second
        end,
        delay = function(ms, callback)
            f.timers[#f.timers + 1] = { time = f.now + ms, callback = callback }
        end,
        game_thread = function(callback)
            if options.scheduler_fails then error("scheduler unavailable") end
            f.jobs[#f.jobs + 1] = callback
        end,
        move_second = function()
            assert(f.on_game_thread)
            f.moves = f.moves + 1
            if options.collision then error("teleport rejected") end
        end,
        split_hud = function()
            assert(f.on_game_thread)
            f.hud_calls = f.hud_calls + 1
            if options.hud_fails then error("HUD rejected") end
            f.hud_active = true
        end,
        hud_active = function() return f.hud_active == true end,
        hud_ready = function() return not options.hud_delayed end,
    }
    f.session = Session.new(f.api)
    function f:advance(milliseconds)
        local deadline, iterations = self.now + milliseconds, 0
        while true do
            table.sort(self.timers, function(a, b) return a.time < b.time end)
            if #self.timers == 0 or self.timers[1].time > deadline then break end
            iterations = iterations + 1
            assert(iterations < 100, "Unbounded scheduling")
            local timer = table.remove(self.timers, 1)
            self.now = timer.time
            timer.callback()
            while #self.jobs > 0 do
                local job = table.remove(self.jobs, 1)
                self.on_game_thread = true
                job()
                self.on_game_thread = false
            end
        end
        self.now = deadline
    end
    return f
end

local function test(name, callback)
    callback()
    passed = passed + 1
    print("PASS " .. name)
end
local function fails(callback, pattern)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(pattern, 1, true), tostring(message))
end

test("combined startup waits before moving and setting up HUD", function()
    local f = fixture()
    f.session:start()
    assert(f.creates == 1 and f.moves == 0 and f.hud_calls == 0)
    f:advance(1999)
    assert(f.moves == 0)
    f:advance(1)
    assert(f.moves == 1 and f.hud_calls == 0)
    f:advance(500)
    assert(f.hud_calls == 1 and f.session.phase == "ready")
end)

test("repeated startup does not add or move another player", function()
    local f = fixture()
    f.session:start()
    f.session:start()
    f:advance(3000)
    f.session:start()
    assert(f.creates == 1 and f.moves == 1 and f.hud_calls == 1)
end)

test("delayed pawn initialization is bounded and can complete", function()
    local f = fixture({ pawn_delayed = true })
    f.session:start()
    f:advance(2250)
    assert(f.moves == 0)
    f.second.Pawn = object()
    f:advance(1000)
    assert(f.moves == 1 and f.hud_calls == 1 and f.session.phase == "ready")
end)

test("missing pawn times out without relocation or HUD mutation", function()
    local f = fixture({ pawn_delayed = true })
    f.session:start()
    f:advance(15000)
    assert(f.session.phase == "failed" and f.creates == 1 and f.moves == 0 and f.hud_calls == 0)
    fails(function() f.session:start() end, "previous F1 attempt failed")
end)

test("cancelling startup invalidates delayed work", function()
    local f = fixture()
    f.session:start()
    f.session:cancel()
    f:advance(3000)
    assert(f.moves == 0 and f.hud_calls == 0 and f.session.phase == "idle")
end)

test("changing worlds stops delayed setup before movement", function()
    local f = fixture()
    f.session:start()
    f.world = object()
    f:advance(3000)
    assert(f.session.phase == "failed" and f.moves == 0 and f.hud_calls == 0)
end)

test("collision failure stops setup without adding HUD", function()
    local f = fixture({ collision = true })
    f.session:start()
    f:advance(3000)
    assert(f.moves == 1 and f.hud_calls == 0 and f.session.phase == "failed")
end)

test("HUD failure is reported and does not trigger repeated creation", function()
    local f = fixture({ hud_fails = true })
    f.session:start()
    f:advance(3000)
    assert(f.hud_calls == 1 and f.session.phase == "failed" and f.creates == 1)
end)

test("native creation failure never schedules another attempt", function()
    local f = fixture({ add_fails = true })
    fails(function() f.session:start() end, "creation rejected")
    assert(f.creates == 1 and #f.timers == 0 and f.session.phase == "failed")
end)

test("missing delay support is detected before creating a player", function()
    local f = fixture()
    f.api.delay = nil
    fails(function() f.session:start() end, "Delayed game-thread execution")
    assert(f.creates == 0)
end)

test("scheduler failure leaves no hidden HUD or relocation work", function()
    local f = fixture({ scheduler_fails = true })
    f.session:start()
    f:advance(3000)
    assert(f.session.phase == "failed" and f.moves == 0 and f.hud_calls == 0)
end)

test("input handoff uses native user mapping and restores it on the second press", function()
    local f = fixture()
    f.api.add_player()
    local first_pawn, second_pawn = f.first.Pawn, f.second.Pawn
    f.session:switch_input()
    assert(f.ids[f.first] == 1 and f.ids[f.second] == 0)
    assert(f.first.Pawn == first_pawn and f.second.Pawn == second_pawn)
    f.session:switch_input()
    assert(f.ids[f.first] == 0 and f.ids[f.second] == 1 and f.session.input_backup == nil)
end)

test("unknown input mappings are not overwritten", function()
    local f = fixture()
    f.api.add_player()
    f.ids[f.first] = 4
    fails(function() f.session:switch_input() end, "unknown input mapping")
    assert(f.input_calls == nil and f.ids[f.first] == 4)
end)

test("input native failure restores the original pair without swapping pawns", function()
    local f = fixture({ swap_throws_once = true })
    f.api.add_player()
    fails(function() f.session:switch_input() end, "native mapping error")
    assert(f.ids[f.first] == 0 and f.ids[f.second] == 1 and f.session.input_backup == nil)
end)

test("input handoff refuses a foreign controller", function()
    local f = fixture()
    f.api.add_player()
    f.second = object({ Pawn = object() })
    fails(function() f.session:switch_input() end, "ownership changed")
    assert(f.input_calls == nil)
end)

test("restoration refuses a replaced input context", function()
    local f = fixture()
    f.api.add_player()
    f.session:switch_input()
    local changed = f.input_calls
    f.first = object({ Pawn = object() })
    fails(function() f.session:restore_input() end, "different controllers")
    assert(f.input_calls == changed)
end)

local function metadata_class(fields)
    local class = object()
    function class:GetFName() return { ToString = function() return "W_PauseMenu_C" end } end
    function class:ForEachProperty(callback)
        for _, field in ipairs(fields) do
            local property = object()
            function property:GetFName() return { ToString = function() return field end } end
            function property:GetFullName() return "Property " .. field end
            if callback(property) == true then break end
        end
    end
    function class:ForEachFunction() end
    function class:GetSuperStruct() return nil end
    return class
end

test("metadata output includes pause state without dumping identifiers or string values", function()
    local f = fixture()
    local class = metadata_class({ "bPauseMenuOpen", "PausePassword", "SaveIdentifier", "ProfileName" })
    local target = object({ bPauseMenuOpen = true, PausePassword = "DO-NOT-LOG-THIS", SaveIdentifier = "PRIVATE-ID", ProfileName = "PRIVATE-NAME" })
    function target:GetClass() return class end
    f.session:metadata("HUD", target)
    local logs = table.concat(f.logs, "\n")
    assert(logs:find("STATE bPauseMenuOpen=true", 1, true))
    assert(logs:find("PROPERTY Property SaveIdentifier", 1, true))
    assert(not logs:find("DO-NOT-LOG-THIS", 1, true))
    assert(not logs:find("PRIVATE-ID", 1, true) and not logs:find("PRIVATE-NAME", 1, true))
    assert(f.creates == 0 and f.moves == 0 and f.hud_calls == 0)
end)

test("metadata reaches pause flags through Blueprint and native game-mode base classes", function()
    local chain = metadata_class({ "bPauseable" })
    for _ = 1, 3 do
        local base = chain
        chain = metadata_class({})
        function chain:GetSuperStruct() return base end
    end
    local f = fixture()
    local target = object({ bPauseable = false })
    function target:GetClass() return chain end
    f.session:metadata("GameMode", target)
    assert(table.concat(f.logs, "\n"):find("STATE bPauseable=false", 1, true))
end)

print(string.format("%d session tests passed (mock API; native input routing and pause/profile behavior need in-game validation).", passed))
