-- Exercise main.lua's actual keybind/wrapper composition. Native work is stubbed;
-- this catches an accidentally re-enabled automatic scan, not a game crash.
local passed = 0
local function fixture()
    local f = {keys={}, events={}, logs={}, modules={}}
    local function event(s) f.events[#f.events+1]=s end
    local probe = {
        diagnose=function() end, remove_player=function() end,
        add_player=function() end,
    }
    local session = {
        finish=function() end, cancel=function() end,
        restore_input=function(self) self.input_backup=nil end,
        switch_input=function(self)
            if self.input_backup then self:restore_input() else self.input_backup={} end
            event(self.input_backup and 'guest' or 'host')
        end,
    }
    local function hud_link()
        return {bind=function() event('link') end, restore=function() end, diagnose=function() end}
    end
    local ui = {
        generation=0, bind=function() event('ui-bind') end,
        sync=function() event('focus') end, restore=function() end,
        key=function(_,kind) event(kind) end,
    }
    local modules = {
        split_probe={new=function() return probe end},
        session_tools={new=function(api) session.api=api; return session end},
        hud_link={new=hud_link},
        routing_probe={new=function() return {capture=function() event('route') end} end},
        inventory_ui={new=function() return ui end},
    }
    local function forbidden() error('Unexpected native/global scan in bootstrap or handoff') end
    local env = setmetatable({
        Key={F1='F1',F2='F2',F3='F3',F4='F4',F5='F5',F6='F6',F7='F7',F8='F8',F9='F9'},
        RegisterKeyBind=function(key,fn) assert(not f.keys[key]); f.keys[key]=fn end,
        RegisterHook=forbidden, FindAllOf=forbidden, FindFirstOf=forbidden,
        StaticFindObject=forbidden, ExecuteWithDelay=forbidden,
        ExecuteInGameThread=function(fn) fn() end,
        print=function(s) f.logs[#f.logs+1]=s end,
        require=function(key)
            assert(modules[key], 'Disabled/unknown module requested: '..key)
            f.modules[key]=true
            return modules[key]
        end,
    }, {__index=_G})
    assert(loadfile('mods/AbioticSplitScreen/Scripts/main.lua','t',env))()
    f.session=session
    return f
end
local function test(name,fn) fn(); passed=passed+1; print('PASS '..name) end
test('F2 completes both handoffs without loading or scanning waypoint experiment',function()
    local f=fixture()
    for _,key in ipairs({'waypoint_ui','player_bindings','ui_context','shared_pause','container_ui','preview_ui'}) do
        assert(not f.modules[key], 'Recovery loaded a disabled experimental module: '..key)
    end
    assert(f.keys[0x45]==nil and f.keys[0x01]==nil, 'Recovery registered a v0.8 interaction observer')
    f.keys.F2()
    assert(f.session.input_backup and table.concat(f.events,',')=='ui-bind,link,guest,route,focus')
    assert(f.logs[#f.logs]:find('F2 handoff complete',1,true))
    f.events={}; f.keys.F2()
    assert(not f.session.input_backup and table.concat(f.events,',')=='host,route,focus')
    assert(f.logs[#f.logs]:find('F2 handoff complete',1,true))
end)
test('Tab and Esc remain registered once and reach the inventory handler',function()
    local f=fixture(); f.keys[0x09](); f.keys[0x1B]()
    assert(table.concat(f.events,',')=='tab,escape')
end)
print(passed..' main runtime tests passed (mocked native work; game stability requires validation).')
