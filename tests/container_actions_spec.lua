local Actions=require('container_actions')
local serial,passed=0,0
local generic_class={IsValid=function() return true end,GetAddress=function() return 0 end}
local function object()
    serial=serial+1
    local o={id=serial}
    function o:IsValid() return not self.dead end
    function o:GetAddress() return self.id end
    function o:GetOwningPlayer() return self.pc end
    function o:GetOwner() return self.owner end
    function o:GetClass() return generic_class end
    function o:IsA(kind) return self.component and kind=='/Script/Engine.ActorComponent' end
    return o
end
local function fixture()
    local f={logs={},binds=0,functionScans=0,actionCalls=0}
    f.first,f.second=object(),object()
    f.first.Pawn,f.second.Pawn=object(),object()
    f.first.Pawn.CharacterInventory,f.second.Pawn.CharacterInventory=object(),object()
    f.first.Pawn.CharacterInventory.component,f.second.Pawn.CharacterInventory.component=true,true
    f.first.Pawn.CharacterInventory.owner,f.second.Pawn.CharacterInventory.owner=f.first.Pawn,f.second.Pawn
    f.root,f.widget,f.component=object(),object(),object()
    f.component.component=true
    f.root.pc,f.widget.pc=f.second,f.second
    f.root.CurrentContainerWidget=f.widget
    f.root.ActiveContainer=f.component
    f.second.Pawn.InventoryReference=f.root
    f.widget.OwningCharacter=f.first.Pawn
    f.widget.PlayerInventory=f.first.Pawn.CharacterInventory
    f.widget.ContainerInventory=f.component
    f.widget.PlayerSaveID='PRIVATE VALUE MUST NOT BE LOGGED'
    local class=object()
    function class:GetFName() return {ToString=function() return 'W_Inventory_Container_C' end} end
    function class:GetSuperStruct() return nil end
    local function prop(key,kind)
        return {GetFName=function() return {ToString=function() return key end} end,
            GetFullName=function() return kind..' Fixture:'..key end}
    end
    function class:ForEachProperty(cb)
        if f.metadataError then error('metadata unavailable') end
        for _,entry in ipairs({{'OwningCharacter','ObjectProperty'},{'PlayerInventory','ObjectProperty'},
            {'ContainerInventory','ObjectProperty'},{'PlayerSaveID','StrProperty'}}) do
            if cb(prop(entry[1],entry[2])) then break end
        end
    end
    function class:ForEachFunction(cb)
        f.functionScans=f.functionScans+1
        local fn=object()
        function fn:GetFName() return {ToString=function() return 'TakeAll' end} end
        function fn:GetFullName() return 'Function Fixture:TakeAll' end
        function fn:ForEachProperty(call)
            call(prop('CallFunc_GetAbioticPlayerCharacter_ReturnValue','ObjectProperty'))
        end
        setmetatable(fn,{__call=function() f.actionCalls=f.actionCalls+1;error('Item function must never run in context repair') end})
        cb(fn)
    end
    function f.widget:GetClass() return class end
    f.class=class
    f.actions=Actions.new({pair=function() return {},f.first,f.second end,
        huds=function() return {guest={W_PlayerInventory_Main=f.root}} end,
        property=function(widget,key,kind)
            assert(widget==f.root.CurrentContainerWidget and kind=='ObjectProperty')
            if key=='OwningCharacter' then return not f.noCharacterField end
            return key=='PlayerInventory' or key=='MyPlayerController' and f.controllerField
        end,
        bind=function()
            f.binds=f.binds+1
            if not f.bindNoop and not f.noCharacterField then f.root.CurrentContainerWidget.OwningCharacter=f.second.Pawn end
        end,log=function(s) f.logs[#f.logs+1]=s end})
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('post-open refresh repairs a host character cache on the owned guest container',function()
    local f=fixture();assert(f.actions:repair(f.component))
    assert(f.widget.OwningCharacter==f.second.Pawn and f.binds==1)
    assert(table.concat(f.logs,' '):find('previous character was host=true',1,true))
end)
test('late native refresh can be rebound again when the container settles',function()
    local f=fixture();f.actions:repair(f.component)
    f.widget.OwningCharacter=f.first.Pawn
    f.actions:repair(f.component)
    assert(f.binds==2 and f.widget.OwningCharacter==f.second.Pawn and f.functionScans==1)
end)
test('diagnostics expose roles and Take All lookup metadata without moving items',function()
    local f=fixture();f.actions:repair(f.component)
    local s=table.concat(f.logs,' ')
    assert(s:find('PlayerInventory -> host-backpack',1,true))
    assert(s:find('ContainerInventory -> opened-container',1,true))
    assert(s:find('CallFunc_GetAbioticPlayerCharacter_ReturnValue',1,true))
    assert(f.actionCalls==0 and f.widget.PlayerInventory==f.second.Pawn.CharacterInventory)
    assert(f.widget.ContainerInventory==f.component)
end)
test('arbitrary save and item string values are never logged or modified',function()
    local f=fixture();f.actions:repair(f.component)
    assert(not table.concat(f.logs,' '):find('PRIVATE VALUE',1,true))
    assert(f.widget.PlayerSaveID=='PRIVATE VALUE MUST NOT BE LOGGED')
end)
test('an unexpected active container prevents context mutation',function()
    local f=fixture();f.root.ActiveContainer=object()
    assert(f.actions:repair(f.component)==false)
    assert(f.binds==0 and f.widget.OwningCharacter==f.first.Pawn and f.functionScans==0)
end)
test('foreign widget or inventory owner is rejected before rebinding',function()
    for _,which in ipairs({'child','root','reference'}) do
        local f=fixture()
        if which=='child' then f.widget.pc=f.first elseif which=='root' then f.root.pc=f.first
        else f.second.Pawn.InventoryReference=object() end
        assert(not pcall(function() f.actions:repair(f.component) end))
        assert(f.binds==0 and f.widget.OwningCharacter==f.first.Pawn)
    end
end)
test('an unknown third character is preserved',function()
    local f=fixture();local third=object();f.widget.OwningCharacter=third
    assert(not pcall(function() f.actions:repair(f.component) end))
    assert(f.binds==0 and f.widget.OwningCharacter==third)
end)
test('expired or non-component container values cannot trigger rebinding',function()
    for _,which in ipairs({'expired','not-component'}) do
        local f=fixture()
        if which=='expired' then f.component.dead=true else f.component.component=false end
        assert(not pcall(function() f.actions:repair(f.component) end));assert(f.binds==0)
    end
end)
test('lack of a character field never invents a destination property',function()
    local f=fixture();f.noCharacterField=true;f.widget.OwningCharacter=nil
    assert(f.actions:repair(f.component))
    assert(f.widget.OwningCharacter==nil and f.binds==1)
    assert(table.concat(f.logs,' '):find('container character field=false',1,true))
end)
test('metadata failure does not prevent the existing validated binding path',function()
    local f=fixture();f.metadataError=true;assert(f.actions:repair(f.component))
    assert(f.binds==1 and f.widget.OwningCharacter==f.second.Pawn)
    assert(table.concat(f.logs,' '):find('LOOTUI partial metadata',1,true))
end)
test('a failed native binding is reported without a successful context assertion',function()
    local f=fixture();f.bindNoop=true
    assert(not pcall(function() f.actions:repair(f.component) end))
    assert(not table.concat(f.logs,' '):find('refreshed existing guest UI links',1,true))
end)
test('repair follows a newly created owned container widget rather than the old instance',function()
    local f=fixture();local old=f.widget;local replacement=object()
    replacement.pc=f.second;replacement.OwningCharacter=f.first.Pawn
    function replacement:GetClass() return f.class end
    f.root.CurrentContainerWidget=replacement
    assert(f.actions:repair(f.component))
    assert(replacement.OwningCharacter==f.second.Pawn and old.OwningCharacter==f.first.Pawn)
end)
test('teardown clears metadata state without item or save side effects',function()
    local f=fixture();f.actions:repair(f.component);f.actions:clear()
    assert(next(f.actions.seen)==nil and f.actionCalls==0)
    assert(f.widget.PlayerInventory==f.first.Pawn.CharacterInventory)
end)
test('cached backpack destination is rebound only to a component owned by the guest pawn',function()
    local f=fixture();f.second.Pawn.CharacterInventory.owner=f.first.Pawn
    assert(not pcall(function() f.actions:repair(f.component) end))
    assert(f.widget.PlayerInventory==f.first.Pawn.CharacterInventory and f.binds==0)
end)
test('shared backpack components cannot masquerade as an independent guest destination',function()
    local f=fixture();f.second.Pawn.CharacterInventory=f.first.Pawn.CharacterInventory
    assert(not pcall(function() f.actions:repair(f.component) end))
    assert(f.binds==0 and f.actionCalls==0)
end)
test('an existing host controller cache is rebound to the actual guest owner',function()
    local f=fixture();f.controllerField=true;f.widget.MyPlayerController=f.first
    assert(f.actions:repair(f.component));assert(f.widget.MyPlayerController==f.second)
    f.actions:clear();assert(f.widget.MyPlayerController==f.first)
end)
test('unknown or empty destination references are preserved rather than filled in',function()
    for _,kind in ipairs({'third','empty'}) do
        local f=fixture();local old=kind=='third' and object() or nil
        f.widget.PlayerInventory=old;f.actions:repair(f.component)
        assert(f.widget.PlayerInventory==old)
    end
end)
test('teardown preserves cache changes made by another system',function()
    local f=fixture();f.actions:repair(f.component)
    local other=object();f.widget.PlayerInventory=other;f.actions:clear()
    assert(f.widget.PlayerInventory==other)
end)
test('a failed second cache write rolls back the first cache write',function()
    local f=fixture();f.controllerField=true
    local cache={PlayerInventory=f.widget.PlayerInventory,MyPlayerController=f.first}
    f.widget.PlayerInventory=nil
    setmetatable(f.widget,{__index=function(_,key) return cache[key] end,
        __newindex=function(_,key,value)
            if key=='MyPlayerController' and value==f.second then error('Injected cache write failure') end
            cache[key]=value
        end})
    assert(not pcall(function() f.actions:repair(f.component) end))
    assert(f.widget.PlayerInventory==f.first.Pawn.CharacterInventory and f.widget.MyPlayerController==f.first)
    assert(next(f.actions.changes)==nil and f.actionCalls==0)
end)
test('a different component class cannot replace a typed UI reference',function()
    local f=fixture();local other_class=object()
    function f.second.Pawn.CharacterInventory:GetClass() return other_class end
    assert(not pcall(function() f.actions:repair(f.component) end))
    assert(f.binds==0 and f.widget.PlayerInventory==f.first.Pawn.CharacterInventory)
end)
print(passed..' container action context checks passed (mock API; Take All destination remains unverified in-game).')
