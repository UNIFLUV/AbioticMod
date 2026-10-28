local Router=require('ui_context')
local passed,serial=0,0
local function object(kind,owner,outer)
    serial=serial+1
    local o={id=serial,kind=kind,owner=owner,outer=outer}
    function o:IsValid() return not self.dead end
    function o:GetAddress() return self.id end
    function o:IsA(k) return k==self.kind end
    function o:GetOwningPlayer() return self.owner end
    function o:GetOuter() return self.outer end
    return o
end
local function param(value)
    return {get=function(self) return self.value end,set=function(self,v) self.value=v end,value=value}
end
local function fixture()
    local f={hooks={},logs={}}
    f.first,f.second=object('Controller'),object('Controller')
    f.first.Pawn,f.second.Pawn=object('Pawn'),object('Pawn')
    f.widget=object('/Script/UMG.UserWidget',f.second)
    local lookup={{'WorldContextObject','ObjectProperty'},{'PlayerIndex','IntProperty'},{'ReturnValue','ObjectProperty'}}
    local projection={{'PlayerController','ObjectProperty'},{'WorldLocation','StructProperty'},
        {'ScreenPosition','StructProperty'},{'bPlayerViewportRelative','BoolProperty'},{'ReturnValue','BoolProperty'}}
    local clamped={{'WorldPosition','StructProperty'},{'ScreenPosition','StructProperty'},{'ScreenDirection','StructProperty'},
        {'Padding','StructProperty'},{'bPlayerViewportRelative','BoolProperty'},{'bClamp','BoolProperty'},{'ReturnValue','BoolProperty'}}
    f.router=Router.new({pair=function() return {},f.first,f.second end,log=function(s) f.logs[#f.logs+1]=s end,
        find=function(path)
            local fn=object('Function')
            function fn:GetFunctionFlags() return f.flags or 0x400 end
            function fn:ForEachProperty(cb)
                for _,entry in ipairs(path:find('Clamped',1,true) and clamped or (path:find('ProjectWorld',1,true) and projection or lookup)) do
                    local p={}
                    function p:GetFName() return {ToString=function() return f.bad and 'Unexpected' or entry[1] end} end
                    function p:GetFullName() return entry[2]..' Fixture:'..entry[1] end
                    cb(p)
                end
            end
            return fn
        end,
        hook=function(path,pre) f.hooks[path]=pre; return 1,2 end})
    f.router:bind(); f.router:install()
    function f.lookup(context,index)
        local p=param(index)
        f.hooks['/Script/Engine.GameplayStatics:GetPlayerController'](nil,param(context),p)
        return p.value
    end
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('UI lookup index zero follows the actual guest widget owner',function()
    local f=fixture(); assert(f.lookup(f.widget,0)==1)
    f.widget.owner=f.first; assert(f.lookup(f.widget,0)==0)
end)
test('explicit nonzero indices and unknown widget owners are preserved',function()
    local f=fixture(); assert(f.lookup(f.widget,1)==1)
    f.widget.owner=object('RemoteController'); assert(f.lookup(f.widget,0)==0)
end)
test('pawn, controller, world and container contexts do not alter gameplay or save identity',function()
    local f=fixture()
    for _,o in ipairs({f.second.Pawn,f.second,object('World'),object('Container')}) do assert(f.lookup(o,0)==0) end
end)
test('primitive UMG children resolve only through their owning widget tree',function()
    local f=fixture();local tree=object('/Script/UMG.WidgetTree',nil,f.widget)
    assert(f.lookup(object('/Script/UMG.Widget',nil,tree),0)==1)
end)
test('native projection uses per-player coordinates only for the known guest',function()
    local f=fixture();local relative=param(false)
    local hook=f.hooks['/Script/UMG.WidgetLayoutLibrary:ProjectWorldLocationToWidgetPosition']
    hook(nil,param(f.second),nil,nil,relative);assert(relative.value)
    relative=param(false);hook(nil,param(f.first),nil,nil,relative);assert(not relative.value)
    relative=param(false)
    f.hooks['/Script/AbioticFactor.AbioticPlayerController:ProjectWorldToScreenClamped'](param(f.second),nil,nil,nil,nil,relative)
    assert(relative.value)
end)
test('teardown makes installed native callbacks inert',function()
    local f=fixture();f.router:restore();assert(f.lookup(f.widget,0)==0)
end)
test('unsupported native metadata refuses registration without changing engine flags',function()
    local f=fixture();f.router.hooks={};f.hooks={};f.bad=true;f.router:install();assert(next(f.hooks)==nil)
    f.bad=false;f.flags=0;f.router:install();assert(next(f.hooks)==nil)
end)
test('recursive engine lookup from GetOwningPlayer cannot reroute another context',function()
    local f=fixture();function f.widget:GetOwningPlayer()
        assert(f.lookup(self,0)==0);return f.second
    end
    assert(f.lookup(f.widget,0)==1)
end)
print(passed..' UI context tests passed (mock hooks; native routing and marker behavior unverified).')
