local Markers=require('waypoint_ui')
local serial,passed=0,0
local function object(kind,schema)
    serial=serial+1
    local o={id=serial}; local c={}
    function o:IsValid() return true end
    function o:GetAddress() return self.id end
    function o:GetFullName() return kind..' '..self.id end
    function o:GetClass() return c end
    function o:GetParent() return self.parent end
    function o:GetOuter() return self.outer end
    function o:GetOwningPlayer() return self.owner end
    function o:SetOwningPlayer(pc) self.owner=pc end
    function c:IsValid() return true end
    function c:GetFName() return {ToString=function() return kind end} end
    function c:GetSuperStruct() return nil end
    function c:ForEachProperty(cb)
        for key,t in pairs(schema or {}) do
            local p={}
            function p:GetFName() return {ToString=function() return key end} end
            function p:GetFullName() return t..' Fixture:'..key end
            cb(p)
        end
    end
    return o
end
local function fixture()
    local f={logs={}}
    f.first,f.second=object('Controller'),object('Controller')
    f.first.Pawn,f.second.Pawn=object('Pawn'),object('Pawn')
    f.main,f.guest=object('HUD'),object('HUD')
    local schema={OwningController='ObjectProperty',OwningCharacter='ObjectProperty',PlayerController='ObjectProperty',LinkedActor='ObjectProperty',bPlayerViewportRelative='BoolProperty'}
    f.marker,f.host=object('QuestWaypoint_C',schema),object('QuestWaypoint_C',schema)
    for _,w in ipairs({f.marker,f.host}) do
        w.owner,w.OwningController,w.OwningCharacter,w.LinkedActor,w.PlayerController=f.first,f.first,f.first.Pawn,f.first.Pawn,f.first
        w.bPlayerViewportRelative=false
    end
    f.marker.parent,f.host.parent=f.guest,f.main
    f.ui=Markers.new({pair=function() return {},f.first,f.second end,huds=function() return {main=f.main,guest=f.guest} end,
        find_all=function() return {f.host,f.marker} end,log=function(s) f.logs[#f.logs+1]=s end})
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('guest waypoint context changes without retargeting its world actor',function()
    local f=fixture();f.ui:repair()
    assert(f.marker.owner==f.second and f.marker.OwningController==f.second and f.marker.OwningCharacter==f.second.Pawn)
    assert(f.marker.LinkedActor==f.first.Pawn and f.marker.PlayerController==f.first)
    assert(f.marker.bPlayerViewportRelative)
end)
test('host marker is never changed by guest repair',function()
    local f=fixture();f.ui:repair()
    assert(f.host.owner==f.first and f.host.OwningController==f.first and not f.host.bPlayerViewportRelative)
end)
test('marker with an unknown third controller is preserved',function()
    local f=fixture();local third=object('Controller');f.marker.owner=third;f.ui:repair()
    assert(f.marker.owner==third and f.marker.OwningController==f.first and not f.marker.bPlayerViewportRelative)
end)
test('restoration preserves cache changes made by another system',function()
    local f=fixture();f.ui:repair();local third=object('Controller');f.marker.OwningController=third
    f.ui:restore()
    assert(f.marker.owner==f.first and f.marker.OwningCharacter==f.first.Pawn and not f.marker.bPlayerViewportRelative)
    assert(f.marker.OwningController==third)
end)
test('parent and WidgetTree outer chain establishes guest ownership',function()
    local f=fixture();local panel=object('Panel');local tree=object('WidgetTree')
    f.marker.parent=panel;panel.outer=tree;tree.outer=f.guest;f.ui:repair()
    assert(f.marker.owner==f.second)
end)
print(passed..' waypoint UI tests passed (mock API; actual marker projection requires game validation).')
