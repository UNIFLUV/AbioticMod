local Bridge=require('container_handoff')
local serial,passed=0,0
local function object()
    serial=serial+1
    local o={id=serial,shown=false}
    function o:IsValid() return not self.dead end
    function o:GetAddress() return self.id end
    function o:IsA(kind) return self.component and kind=='/Script/Engine.ActorComponent' end
    function o:GetOwner() return self.owner end
    function o:GetOwningPlayer() return self.pc end
    return o
end
local function fixture()
    local f={timers={},logs={},calls={},syncs=0,refreshes=0,active=true}
    f.world,f.first,f.second=object(),object(),object()
    f.first.Pawn,f.second.Pawn=object(),object()
    f.host,f.guest,f.target,f.component=object(),object(),object(),object()
    f.component.component,f.component.owner=true,f.target
    f.second.Pawn.BestInteractable_InteractA=f.target
    for i,root in ipairs({f.host,f.guest}) do
        local pc=i==1 and f.first or f.second
        root.pc,root.OwningCharacter=pc,pc.Pawn
        root.InventoryMain=object();root.InventoryMain.shown=true
        root.InventoryMode=6
        pc.Pawn.InventoryReference=root
    end
    f.host.ActiveContainer=f.component
    local fields={{'ForceClose','BoolProperty'},{'InventoryMode','EnumProperty'},
        {'CraftingBenchesAvailable','ArrayProperty'},{'ContainerInventoryComponent','ObjectProperty'},
        {'CustomUIKeyboardFocus','BoolProperty'},{'Temp_int_Array_Index_Variable','IntProperty'}}
    local handler=object()
    function handler:GetFunctionFlags() return f.flags or 0 end
    function handler:ForEachProperty(cb)
        for _,entry in ipairs(fields) do
            local p={}
            function p:GetFName() return {ToString=function() return f.badSignature and 'UnknownArgument' or entry[1] end} end
            function p:GetFullName() return entry[2]..' Fixture:'..entry[1] end
            cb(p)
        end
    end
    setmetatable(handler,{__call=function(_,pawn,close,mode,benches,component,focus)
        assert(pawn==f.first.Pawn or pawn==f.second.Pawn)
        assert(mode==6 and type(benches)=='table' and next(benches)==nil and focus==false)
        f.calls[#f.calls+1]={pawn=pawn,close=close,component=component}
        local root=pawn==f.first.Pawn and f.host or f.guest
        if close then
            assert(pawn==f.first.Pawn and component==nil)
            if not f.closeNoop then root.shown=false end
            if f.expireOnClose then f.component.dead=true end
        else
            assert(component==f.component)
            if pawn==f.second.Pawn and f.openError then error('Guest handler failed') end
            if pawn==f.second.Pawn and f.openNoop then return end
            root.shown=true;root.ActiveContainer=component
        end
    end})
    f.handler=handler
    f.h={main={W_PlayerInventory_Main=f.host},guest={W_PlayerInventory_Main=f.guest}}
    f.bridge=Bridge.new({pair=function() return {world=f.world},f.first,f.second end,
        huds=function() return f.h end,guest_active=function() return f.active end,
        visible=function(w) return w~=nil and w:IsValid() and w.shown end,
        property=function(root,key,kind) return not f.badModeField and root==f.host and key=='InventoryMode' and kind=='EnumProperty' end,
        find=function() return f.handler end,
        bind_container=function(component)
            assert(component==f.component and f.guest.ActiveContainer==component)
            f.refreshes=f.refreshes+1
        end,
        delay=function(_,cb) f.timers[#f.timers+1]=cb end,game_thread=function(cb) cb() end,
        sync=function() f.syncs=f.syncs+1;f.bridge:remember() end,
        log=function(s) f.logs[#f.logs+1]=s end})
    f.bridge:remember()
    function f:step() assert(#self.timers>0);table.remove(self.timers,1)() end
    function f:interact() self.bridge:key();self.host.shown=true;self:step() end
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('E transfers only the matching new host container through each character handler',function()
    local f=fixture();f:interact()
    assert(#f.calls==2 and f.calls[1].pawn==f.first.Pawn and f.calls[1].close)
    assert(f.calls[2].pawn==f.second.Pawn and not f.calls[2].close and f.calls[2].component==f.component)
    assert(f.refreshes==1)
    f:step();assert(f.guest.shown and not f.host.shown and f.syncs==1 and #f.timers==0 and f.refreshes==2)
    assert(table.concat(f.logs,' '):find('matching component=true; host displayed=false',1,true))
end)
test('pre-existing host inventory is preserved even when its container matches',function()
    local f=fixture();f.host.shown=true;f.bridge:remember();f:interact()
    assert(#f.calls==0 and f.host.shown and not f.guest.shown)
end)
test('unknown prior state cannot authorize closing the host',function()
    local f=fixture();f.bridge.observed=nil;f:interact();assert(#f.calls==0)
end)
test('a native guest opening is preserved and focused without toggling either character',function()
    local f=fixture();f.bridge:key();f.guest.shown=true;f.guest.ActiveContainer=f.component;f:step()
    assert(#f.calls==0 and f.syncs==1)
end)
test('an already open guest inventory prevents stealing the host window',function()
    local f=fixture();f.guest.shown=true;f:interact();assert(#f.calls==0 and f.guest.shown and f.host.shown)
end)
test('missing target, unrelated component and non-component windows are left untouched',function()
    for _,kind in ipairs({'missing-target','unrelated','not-component'}) do
        local f=fixture()
        if kind=='missing-target' then f.second.Pawn.BestInteractable_InteractA=nil
        elseif kind=='unrelated' then f.component.owner=object() else f.component.component=false end
        f:interact();assert(#f.calls==0)
    end
end)
test('a direct component target is accepted without a proximity fallback',function()
    local f=fixture();f.second.Pawn.BestInteractable_InteractA=f.component;f:interact();f:step()
    assert(f.guest.shown and #f.calls==2)
end)
test('a target absent at E may be captured once after the native interaction',function()
    local f=fixture();f.second.Pawn.BestInteractable_InteractA=nil;f.bridge:key()
    f.second.Pawn.BestInteractable_InteractA=f.target;f.host.shown=true;f:step();f:step()
    assert(#f.calls==2 and f.guest.shown and not f.host.shown)
    assert(table.concat(f.logs,' '):find('target captured after native interaction',1,true))
end)
test('a late unrelated target cannot authorize closing the host window',function()
    local f=fixture();f.second.Pawn.BestInteractable_InteractA=nil;f.bridge:key()
    f.second.Pawn.BestInteractable_InteractA=object();f.host.shown=true;f:step()
    assert(#f.calls==0 and f.host.shown and not f.guest.shown)
end)
test('a valid different initial target cannot be replaced with a matching late target',function()
    local f=fixture();f.second.Pawn.BestInteractable_InteractA=object();f.bridge:key()
    f.second.Pawn.BestInteractable_InteractA=f.target;f.host.shown=true;f:step()
    assert(#f.calls==0 and f.host.shown and not f.guest.shown)
    assert(table.concat(f.logs,' '):find('current guest target matches container=true',1,true))
end)
test('a late matching target still cannot take a pre-existing host window',function()
    local f=fixture();f.host.shown=true;f.bridge:remember()
    f.second.Pawn.BestInteractable_InteractA=nil;f.bridge:key()
    f.second.Pawn.BestInteractable_InteractA=f.target;f:step()
    assert(#f.calls==0 and f.host.shown)
end)
test('changed controller, world, pawn or widget context cancels before native mutation',function()
    for _,kind in ipairs({'world','pawn','root','owner','character','reference'}) do
        local f=fixture();f.bridge:key();f.host.shown=true
        if kind=='world' then f.world=object()
        elseif kind=='pawn' then f.second.Pawn=object()
        elseif kind=='root' then f.h.guest.W_PlayerInventory_Main=object()
        elseif kind=='owner' then f.guest.pc=f.first
        elseif kind=='character' then f.guest.OwningCharacter=f.first.Pawn
        else f.second.Pawn.InventoryReference=f.host end
        f:step();assert(#f.calls==0)
    end
end)
test('RPC, delegate, unknown signature or mode is rejected before host closure',function()
    for _,kind in ipairs({'rpc','delegate','signature','mode-field','mode-value'}) do
        local f=fixture()
        if kind=='rpc' then f.flags=0x40 elseif kind=='delegate' then f.flags=0x100000
        elseif kind=='signature' then f.badSignature=true elseif kind=='mode-field' then f.badModeField=true
        else f.host.InventoryMode=-1 end
        f:interact();assert(#f.calls==0 and f.host.shown)
    end
end)
test('failed guest handler restores the original host container through its native opener',function()
    local f=fixture();f.openError=true;f:interact()
    assert(#f.calls==3 and f.host.shown and not f.guest.shown and f.calls[3].pawn==f.first.Pawn and not f.calls[3].close)
end)
test('guest no-op is detected after settling and restores the previous window',function()
    local f=fixture();f.openNoop=true;f:interact();assert(not f.host.shown);f:step()
    assert(#f.calls==3 and f.host.shown and not f.guest.shown)
end)
test('host close no-op never opens a second window or toggles the old one again',function()
    local f=fixture();f.closeNoop=true;f:interact();assert(#f.calls==1 and f.host.shown and not f.guest.shown)
end)
test('component expiration during native close stops further native calls',function()
    local f=fixture();f.expireOnClose=true;f:interact();assert(#f.calls==1)
end)
test('Tab, Esc, input switch and teardown can invalidate pending E work',function()
    for _,kind in ipairs({'cancel','inactive','clear'}) do
        local f=fixture();f.bridge:key();f.host.shown=true
        if kind=='cancel' then f.bridge:cancel() elseif kind=='inactive' then f.active=false else f.bridge:clear() end
        f:step();assert(#f.calls==0 and f.host.shown)
    end
end)
test('settlement never reopens a host menu after context change or input cancellation',function()
    for _,kind in ipairs({'cancel','world'}) do
        local f=fixture();f.openNoop=true;f:interact()
        if kind=='cancel' then f.bridge:cancel() else f.world=object() end
        f:step();assert(#f.calls==2)
    end
end)
test('failed handoff never replaces a newly opened unrelated host window',function()
    local f=fixture();f.openNoop=true;f:interact();f.host.shown=true;f.host.ActiveContainer=object();f:step()
    assert(#f.calls==2 and f.host.shown)
end)
test('an independently opened guest window prevents delayed host restoration',function()
    local f=fixture();f.openNoop=true;f:interact();f.guest.shown=true;f.guest.ActiveContainer=object();f:step()
    assert(#f.calls==2 and not f.host.shown and f.guest.shown)
end)
test('E on the host does not schedule work',function()
    local f=fixture();f.active=false;f.bridge:key();assert(#f.timers==0 and #f.calls==0)
end)
test('an open pause menu prevents container transfers before or after E',function()
    for _,when in ipairs({'before','after'}) do
        local f=fixture();f.h.main.W_EscapeMenu_Main=object()
        if when=='before' then
            f.h.main.W_EscapeMenu_Main.shown=true;f.bridge:key();assert(#f.timers==0)
        else
            f.bridge:key();f.host.shown=true;f.h.main.W_EscapeMenu_Main.shown=true;f:step()
        end
        assert(#f.calls==0)
    end
end)
print(passed..' container-only handoff checks passed (mock native functions; actual container behavior requires game validation).')
