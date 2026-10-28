local Bridge=require('container_ui')
local passed,serial=0,0
local function object()
    serial=serial+1;local o={id=serial}
    function o:IsValid() return true end
    function o:GetAddress() return self.id end
    function o:IsA(k) return self.component and k=='/Script/Engine.ActorComponent' end
    function o:GetOwner() return self.owner end
    return o
end
local function fixture()
    local f={timers={},logs={},guest_active=true,closed=0,opened=0,synced=0}
    f.world,f.first,f.second=object(),object(),object()
    f.first.Pawn,f.second.Pawn=object(),object()
    f.host,f.guest,f.target,f.component=object(),object(),object(),object()
    f.host.InventoryMain,f.guest.InventoryMain=object(),object()
    f.host.shown,f.host.InventoryMain.shown,f.guest.InventoryMain.shown=true,true,true
    f.component.component,f.component.owner=true,f.target
    f.host.ActiveContainer=f.component
    f.second.Pawn.BestInteractable_InteractA=f.target
    f.states={[f.host.id]={root=f.host,displayed=false}}
    f.bridge=Bridge.new({pair=function() return {world=f.world},f.first,f.second end,
        huds=function() return {main={W_PlayerInventory_Main=f.host},guest={W_PlayerInventory_Main=f.guest}} end,
        states=function() return f.states end,guest_active=function() return f.guest_active end,
        visible=function(o) return o.shown==true end,delay=function(_,cb) f.timers[#f.timers+1]=cb end,
        game_thread=function(cb) cb() end,mode=function(root) assert(root==f.host);return 2 end,
        close_host=function(c) assert(c==f.component);f.host.shown=false;f.closed=f.closed+1 end,
        open_guest=function(c,mode) assert(c==f.component and mode==2);f.guest.shown=true;f.guest.ActiveContainer=c;f.opened=f.opened+1 end,
        sync=function() f.synced=f.synced+1 end,log=function(s) f.logs[#f.logs+1]=s end})
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('only a matching newly opened host container is handed to the guest',function()
    local f=fixture();f.bridge:key();f.timers[1]();f.timers[2]()
    assert(f.closed==1 and f.opened==1 and f.guest.shown and not f.host.shown and f.synced==1)
end)
test('a pre-existing host window is never stolen',function()
    local f=fixture();f.states[f.host.id].displayed=true;f.bridge:key();f.timers[1]()
    assert(f.closed==0 and f.opened==0 and f.host.shown)
end)
test('unknown earlier host state and unrelated containers are preserved',function()
    for _,kind in ipairs({'unknown','other-target'}) do
        local f=fixture()
        if kind=='unknown' then f.states=nil else f.component.owner=object() end
        f.bridge:key();f.timers[1]();assert(f.closed==0 and f.opened==0)
    end
end)
test('a native guest container opening is not toggled again',function()
    local f=fixture();f.host.shown=false;f.guest.shown=true;f.bridge:key();f.timers[1]()
    assert(f.closed==0 and f.opened==0 and f.synced==1)
end)
test('an independently open guest inventory prevents a host handoff',function()
    local f=fixture();f.guest.shown=true;f.bridge:key();f.timers[1]()
    assert(f.closed==0 and f.opened==0 and f.host.shown)
end)
test('cancellation, input handoff and a replacement character stop delayed transfers',function()
    for _,kind in ipairs({'cancel','host-active','new-pawn'}) do
        local f=fixture();f.bridge:key()
        if kind=='cancel' then f.bridge:cancel() elseif kind=='host-active' then f.guest_active=false else f.second.Pawn=object() end
        f.timers[1]();assert(f.closed==0 and f.opened==0)
    end
end)
print(passed..' container handoff tests passed (mock API; native lock/access behavior unverified).')
