local Events=require('container_delegates')
local passed,serial=0,0
local function object(class)
    serial=serial+1;local o={id=serial,class=class}
    function o:IsValid() return not self.dead end
    function o:GetAddress() return self.id end
    function o:GetClass() return self.class end
    function o:IsA(kind) return self.widget and kind=='/Script/UMG.UserWidget' or self.component and kind=='/Script/Engine.ActorComponent' end
    function o:GetOwningPlayer() return self.pc end
    function o:GetOuter() return self.outer end
    return o
end
local function fname(s) return {ToString=function() return s end} end
local function class(fields,functions)
    local c=object();c.fields=fields or {};c.functions=functions or {}
    function c:GetSuperStruct() return nil end
    function c:ForEachProperty(cb)
        for key,kind in pairs(self.fields) do
            local p={GetFName=function() return fname(key) end,GetFullName=function() return kind..' Fixture:'..key end}
            if cb(p) then break end
        end
    end
    function c:ForEachFunction(cb) for _,f in ipairs(self.functions) do if cb(f) then break end end end
    return c
end
local function delegate(list)
    local d={bindings=list or {},adds=0,removes=0,fired=0}
    function d:GetBindings()
        local result={};for _,v in ipairs(self.bindings) do result[#result+1]={Object=v.Object,FunctionName=v.FunctionName} end
        return result
    end
    function d:Add(o,n)
        if self.failAdd==o then error('Injected Add failure') end
        self.adds=self.adds+1;self.bindings[#self.bindings+1]={Object=o,FunctionName=n}
    end
    function d:Remove(o,n)
        self.removes=self.removes+1;local result={}
        for _,b in ipairs(self.bindings) do if b.Object~=o or b.FunctionName:ToString()~=n:ToString() then result[#result+1]=b end end
        self.bindings=result
        if self.failRemove then error('Injected post-Remove failure') end
    end
    function d:Broadcast() error('Repair must never Broadcast') end
    function d:Clear() error('Repair must never Clear') end
    return d
end
local function fixture(kind)
    local f={logs={},binds=0,calls=0,hostItems=0,guestItems=0}
    local handler=object()
    function handler:GetFName() return fname('HandleTakeAll') end
    function handler:GetFunctionFlags() return f.flags or 0 end
    setmetatable(handler,{__call=function() f.calls=f.calls+1;error('Handler must not run during repair') end})
    f.handler=handler
    local pc_class,pawn_class,hud_class=class(),class(),class()
    local inv_class=class({}, {handler})
    local panel_class=class({TakeAllEvent=kind or 'MulticastInlineDelegateProperty'})
    f.first,f.second=object(pc_class),object(pc_class)
    f.first.Pawn,f.second.Pawn=object(pawn_class),object(pawn_class)
    local function widget(c,pc) local w=object(c);w.widget=true;w.pc=pc;return w end
    f.host,f.guest=widget(inv_class,f.first),widget(inv_class,f.second)
    f.old_container,f.container=widget(panel_class,f.first),widget(panel_class,f.second)
    f.host.CurrentContainerWidget,f.guest.CurrentContainerWidget=f.old_container,f.container
    f.second.Pawn.InventoryReference=f.guest
    f.component=object(class());f.component.component=true
    f.guest.ActiveContainer=f.component
    f.h={main=widget(hud_class,f.first),guest=widget(hud_class,f.second)}
    f.h.main.W_PlayerInventory_Main=f.host;f.h.guest.W_PlayerInventory_Main=f.guest
    f.binding={Object=f.host,FunctionName=fname('HandleTakeAll')}
    if kind=='DelegateProperty' then f.container.TakeAllEvent=f.binding
    else f.container.TakeAllEvent=delegate({f.binding}) end
    f.old_container.TakeAllEvent=delegate({{Object=f.host,FunctionName=f.binding.FunctionName}})
    f.events=Events.new({pair=function() return {},f.first,f.second end,huds=function() return f.h end,
        bind=function() f.binds=f.binds+1 end,log=function(s) f.logs[#f.logs+1]=s end})
    f.widget=widget;f.inv_class=inv_class
    function f:repair() return self.events:repair(self.component) end
    function f:recipient()
        if kind=='DelegateProperty' then return self.container.TakeAllEvent.Object end
        return self.container.TakeAllEvent.bindings[1] and self.container.TakeAllEvent.bindings[1].Object
    end
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('guest event retargets the existing host inventory handler without calling it',function()
    local f=fixture();f:repair()
    assert(f:recipient()==f.guest and f.calls==0 and f.binds==1)
    assert(f.old_container.TakeAllEvent.bindings[1].Object==f.host)
end)
test('a simulated later Take All event reaches only the guest receiver',function()
    local f=fixture();f:repair()
    for _,b in ipairs(f.container.TakeAllEvent:GetBindings()) do
        if b.Object==f.guest then f.guestItems=f.guestItems+1 elseif b.Object==f.host then f.hostItems=f.hostItems+1 end
    end
    assert(f.guestItems==1 and f.hostItems==0 and f.calls==0)
end)
test('single-cast delegate uses the same FName and restores its original receiver',function()
    local f=fixture('DelegateProperty');f:repair()
    assert(f:recipient()==f.guest and f.container.TakeAllEvent.FunctionName==f.binding.FunctionName)
    f.events:clear();assert(f:recipient()==f.host)
end)
test('an existing guest subscription is preserved without duplicate dispatch',function()
    local f=fixture();local d=f.container.TakeAllEvent
    d.bindings[#d.bindings+1]={Object=f.guest,FunctionName=f.binding.FunctionName}
    f:repair();assert(#d.bindings==1 and d.adds==0 and f:recipient()==f.guest)
    f.events:clear();assert(#d.bindings==2)
end)
test('unrelated subscribers and source host widgets are preserved',function()
    local f=fixture();local third=object(class())
    local other={Object=third,FunctionName=fname('OtherObserver')}
    local d=f.container.TakeAllEvent;d.bindings[#d.bindings+1]=other
    f:repair();assert(#d.bindings==2)
    local found=false;for _,b in ipairs(d.bindings) do if b.Object==third then found=true end end
    assert(found and f.old_container.TakeAllEvent.adds==0 and f.old_container.TakeAllEvent.removes==0)
end)
test('grid and button events are limited to known owned descendants',function()
    local f=fixture();local grid_class=class({OnTransfer='MulticastInlineDelegateProperty'})
    local grid=f.widget(grid_class,f.second);grid.OnTransfer=delegate({f.binding});f.container.W_InventoryGrid=grid
    local button=object(class({OnClicked='MulticastSparseDelegateProperty'}));button.outer=f.container
    button.OnClicked=delegate({f.binding});f.container.Button_TakeAll=button
    f:repair();assert(grid.OnTransfer.bindings[1].Object==f.guest and button.OnClicked.bindings[1].Object==f.guest)
end)
test('foreign descendants are skipped even when referenced by the guest panel',function()
    local f=fixture();local grid=f.widget(class({OnTransfer='MulticastDelegateProperty'}),f.first)
    grid.OnTransfer=delegate({f.binding});f.container.W_InventoryGrid=grid
    f:repair();assert(grid.OnTransfer.bindings[1].Object==f.host and grid.OnTransfer.removes==0)
end)
test('unknown receiver objects are retained rather than guessed from their class',function()
    local f=fixture();local other=f.widget(f.inv_class,f.first)
    f.container.TakeAllEvent.bindings[1].Object=other;f:repair()
    assert(f:recipient()==other and f.container.TakeAllEvent.removes==0)
end)
test('missing or RPC/delegate handlers cannot be substituted',function()
    for _,kind in ipairs({'missing','rpc','delegate'}) do
        local f=fixture()
        if kind=='missing' then f.inv_class.functions={} elseif kind=='rpc' then f.flags=0x40 else f.flags=0x100000 end
        f:repair();assert(f:recipient()==f.host and f.calls==0)
    end
end)
test('a different guest class prevents receiver mapping',function()
    local f=fixture();f.guest.class=class();f:repair();assert(f:recipient()==f.host)
end)
test('component or root ownership changes prevent all mutation',function()
    for _,kind in ipairs({'component','owner','reference'}) do
        local f=fixture()
        if kind=='component' then f.guest.ActiveContainer=object(class()) elseif kind=='owner' then f.guest.pc=f.first
        else f.second.Pawn.InventoryReference=f.host end
        assert(not pcall(function() f:repair() end));assert(f:recipient()==f.host)
    end
end)
test('unsupported delegate API is preserved with a diagnostic',function()
    local f=fixture();f.container.TakeAllEvent={}
    f:repair();assert(table.concat(f.logs,' '):find('API unavailable',1,true) or table.concat(f.logs,' '):find('GetBindings/Add/Remove unavailable',1,true))
end)
test('a failed Add rolls back the preceding Remove',function()
    local f=fixture();f.container.TakeAllEvent.failAdd=f.guest
    assert(not pcall(function() f:repair() end));assert(f:recipient()==f.host and next(f.events.records)==nil)
end)
test('a Remove that throws after changing bindings can still be rolled back',function()
    local f=fixture();f.container.TakeAllEvent.failRemove=true
    assert(not pcall(function() f:repair() end));assert(f:recipient()==f.host)
end)
test('a later field failure rolls back earlier fields without Broadcast',function()
    local f=fixture();local grid=f.widget(class({OnTransfer='MulticastDelegateProperty'}),f.second)
    grid.OnTransfer=delegate({f.binding});grid.OnTransfer.failAdd=f.guest;f.container.W_InventoryGrid=grid
    assert(not pcall(function() f:repair() end))
    assert(f:recipient()==f.host and grid.OnTransfer.bindings[1].Object==f.host and f.calls==0)
end)
test('teardown restores only an unchanged modified binding list',function()
    local f=fixture();f:repair();f.events:clear()
    assert(f:recipient()==f.host and next(f.events.records)==nil)
end)
test('teardown preserves an event changed by another system',function()
    local f=fixture();f:repair();local d=f.container.TakeAllEvent
    local third=object(class());d.bindings[#d.bindings+1]={Object=third,FunctionName=fname('OtherObserver')}
    f.events:clear();assert(#d.bindings==2 and f:recipient()==f.guest)
end)
test('an external removal of all callbacks is not undone by committed teardown',function()
    local f=fixture();f:repair();f.container.TakeAllEvent.bindings={}
    f.events:clear();assert(#f.container.TakeAllEvent.bindings==0)
end)
test('repeated repair is idempotent and can repair a reset to the original binding',function()
    local f=fixture();local d=f.container.TakeAllEvent
    f:repair();f:repair();assert(d.adds==1 and d.removes==1)
    d.bindings={f.binding};f:repair();assert(f:recipient()==f.guest and #d.bindings==1)
    f.events:clear();assert(f:recipient()==f.host)
end)
test('duplicate or expired delegate receivers are left untouched',function()
    for _,kind in ipairs({'duplicate','expired'}) do
        local f=fixture();local d=f.container.TakeAllEvent
        if kind=='duplicate' then d.bindings[#d.bindings+1]=f.binding else d.bindings[1].Object=object(class());d.bindings[1].Object.dead=true end
        f:repair();assert(d.adds==0 and d.removes==0)
    end
end)
test('an already guest-owned event is not rebound or invoked',function()
    local f=fixture();f.container.TakeAllEvent.bindings[1].Object=f.guest
    f:repair();assert(f:recipient()==f.guest and f.container.TakeAllEvent.adds==0 and f.calls==0)
end)
print(passed..' owned inventory delegate checks passed (mock delegates; actual Take All behavior requires game validation).')
