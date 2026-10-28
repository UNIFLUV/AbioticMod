local Pause=require('shared_pause')
local passed,serial=0,0
local function object()
    serial=serial+1;local o={id=serial}
    function o:IsValid() return true end
    function o:GetAddress() return self.id end
    function o:IsA() return false end
    return o
end
local function fixture()
    local f={queue={},timers={},logs={},paused=false,pauses=0,unpauses=0,focuses=0,unfocused=0}
    f.world,f.first,f.second,f.subsystem=object(),object(),object(),object()
    local function hud(pc)
        local h,e=object(),object()
        h.in_view=true;h.z=4;h.mode='player';h.W_EscapeMenu_Main=e;e.visibility=1
        function h:GetOwningPlayer() return pc end
        function e:GetOwningPlayer() return pc end
        function e:GetVisibility() return self.visibility end
        function e:SetVisibility(v)
            self.visibility=v
            if f.post then f.post({get=function() return self end}) end
        end
        function h:RemoveFromParent() self.in_view=false end
        function h:AddToViewport(z)
            if f.fail_fullscreen then error('Injected fullscreen failure') end
            self.in_view=true;self.mode='viewport';self.z=z
        end
        function h:AddToPlayerScreen(z) self.in_view=true;self.mode='player';self.z=z;return true end
        function h:IsInViewport() return self.in_view end
        return h
    end
    f.h={main=hud(f.first),guest=hud(f.second)}
    function f.subsystem:GetWidgetSlot(h) return {ZOrder=h.z,tag=h.id} end
    function f.subsystem:SetWidgetSlot(h,slot) assert(slot.tag==h.id);h.z=slot.ZOrder end
    local statics={}
    function statics:IsGamePaused() return f.paused end
    function statics:SetGamePaused(_,paused)
        if paused then f.pauses=f.pauses+1 else f.unpauses=f.unpauses+1 end
        if f.refuse_pause and paused then return false end
        f.paused=paused;return true
    end
    f.visibility=object()
    function f.visibility:GetFunctionFlags() return 0x400 end
    function f.visibility:ForEachProperty(cb)
        local p={}
        function p:GetFName() return {ToString=function() return 'InVisibility' end} end
        function p:GetFullName() return 'EnumProperty Fixture:InVisibility' end
        cb(p)
    end
    f.pause=Pause.new({pair=function() return {world=f.world,statics=statics},f.first,f.second end,
        huds=function() return f.h end,find_first=function() return f.subsystem end,
        find=function(path) if path:find('SetVisibility',1,true) then return f.visibility end end,
        hook=function(_,pre,post) assert(type(pre)=='function');f.post=post;return 1,2 end,
        game_thread=function(cb) f.queue[#f.queue+1]=cb end,
        delay=function(_,cb) f.timers[#f.timers+1]=cb end,
        visible=function(e) return e.visibility==0 end,log=function(s) f.logs[#f.logs+1]=s end,
        focus=function(pc,e) f.focuses=f.focuses+1;f.focus_pc=pc;assert(e:GetOwningPlayer()==pc) end,
        unfocus=function() f.unfocused=f.unfocused+1 end})
    function f.flush()
        while #f.queue>0 do local cb=table.remove(f.queue,1);cb() end
    end
    f.pause:bind()
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('either owned Esc menu uses the full viewport and pauses the shared world',function()
    for _,who in ipairs({'main','guest'}) do
        local f=fixture();local h=f.h[who];h.W_EscapeMenu_Main:SetVisibility(0);f.flush()
        assert(f.pause.active and h.mode=='viewport' and h.z==10000 and f.paused)
        assert(f.focus_pc==(who=='main' and f.first or f.second))
    end
end)
test('native Resume visibility restores the original player slot and releases only our pause',function()
    local f=fixture();local h=f.h.main;local e=h.W_EscapeMenu_Main
    e:SetVisibility(0);f.flush();e:SetVisibility(1);f.flush()
    assert(not f.pause.active and h.mode=='player' and h.z==4 and not f.paused and f.unpauses==1)
    assert(f.unfocused==1)
end)
test('pre-existing world pause is preserved by layout teardown',function()
    local f=fixture();f.paused=true
    f.h.guest.W_EscapeMenu_Main:SetVisibility(0);f.flush()
    f.pause:restore();assert(f.paused and f.pauses==0 and f.unpauses==0)
end)
test('engine pause refusal is reported without claiming that time stopped',function()
    local f=fixture();f.refuse_pause=true
    f.h.main.W_EscapeMenu_Main:SetVisibility(0);f.flush()
    assert(f.pause.active and not f.paused and not f.pause.active.paused_by_us)
    assert(table.concat(f.logs,'\n'):find('world paused=false',1,true))
end)
test('failed fullscreen insertion restores the original player HUD',function()
    local f=fixture();f.fail_fullscreen=true
    f.h.main.W_EscapeMenu_Main:SetVisibility(0);f.flush()
    assert(not f.pause.active and f.h.main.mode=='player' and not f.paused)
end)
test('foreign widget visibility and cancelled queued callbacks cannot pause the world',function()
    local f=fixture();f.post({get=function() return object() end});f.flush();assert(f.pauses==0)
    f.h.main.W_EscapeMenu_Main:SetVisibility(0);f.pause:restore();f.flush()
    assert(f.pauses==0 and not f.pause.active)
end)
test('keyboard and mouse one-shot checks cover ancestor-only native menu changes',function()
    local f=fixture();local e=f.h.main.W_EscapeMenu_Main
    f.pause:key();e.visibility=0;f.timers[1]();f.flush();assert(f.pause.active and f.paused)
    e.visibility=1;f.pause:check_later();f.timers[2]();f.flush()
    assert(not f.pause.active and not f.paused)
end)
test('reentrant visibility updates during reparenting never schedule recurring work',function()
    local f=fixture();f.h.main.W_EscapeMenu_Main:SetVisibility(0);f.flush()
    assert(#f.queue==0 and #f.timers==0 and f.pauses==1)
end)
test('the multiplayer warning is hidden only after real pause confirmation and restored on exit',function()
    for _,refused in ipairs({false,true}) do
        local f=fixture();f.refuse_pause=refused
        local e=f.h.main.W_EscapeMenu_Main
        function e:IsA(k) return k=='/Script/UMG.UserWidget' end
        local text=object();text.visibility=0
        function text:IsA(k) return k=='/Script/UMG.TextBlock' end
        function text:GetText() return {ToString=function() return 'MULTIPLAYER - NO PAUSING' end} end
        function text:GetVisibility() return self.visibility end
        function text:SetVisibility(v) self.visibility=v end
        e.WidgetTree=object();e.WidgetTree.RootWidget=text
        e:SetVisibility(0);f.flush()
        assert(text.visibility==(refused and 0 or 1))
        e:SetVisibility(1);f.flush();assert(text.visibility==0)
    end
end)
print(passed..' shared pause tests passed (mock native UI; actual LAN pause/menu behavior unverified).')
