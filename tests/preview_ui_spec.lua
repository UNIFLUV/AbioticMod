local Preview=require('preview_ui')
local passed,serial=0,0
local function object(kind)
    serial=serial+1;local o={id=serial,kind=kind}
    function o:IsValid() return true end
    function o:GetAddress() return self.id end
    function o:IsA(k) return k==self.kind or (self.kind=='/Script/Engine.MaterialInstance' and k=='/Script/Engine.MaterialInterface') end
    function o:GetFName() return {ToString=function() return 'CharacterPreview' end} end
    function o:GetFullName() return self.kind..' Fixture'..self.id end
    return o
end
local function fixture(material)
    local f={logs={},created=0,captured=0}
    f.world,f.first,f.second=object('World'),object('PC'),object('PC')
    f.first.Pawn,f.second.Pawn=object('Pawn'),object('Pawn')
    f.old=object('/Script/Engine.TextureRenderTarget2D')
    f.old.SizeX,f.old.SizeY,f.old.RenderTargetFormat=512,512,2
    f.old.ClearColor={R=0,G=0,B=0,A=0}
    local function capture(pawn)
        local c=object('Capture');c.TextureTarget=f.old
        function c:GetOwner() return pawn end
        pawn.CharacterPane_RenderTarget=c;return c
    end
    f.a,f.b=capture(f.first.Pawn),capture(f.second.Pawn)
    f.root=object('/Script/UMG.UserWidget');f.root.InventoryMain=object('Panel')
    function f.root:GetOwningPlayer() return f.second end
    f.panel=object('/Script/UMG.PanelWidget')
    f.image=object('/Script/UMG.Image')
    local resource=f.old
    if material then
        resource=object('/Script/Engine.MaterialInstance')
        resource.TextureParameterValues={{ParameterInfo={Name={ToString=function() return 'CharacterTexture' end},Association=0},ParameterValue=f.old}}
        f.old_material=resource
    end
    f.image.Brush={ResourceObject=resource}
    function f.image:SetBrushResourceObject(r)
        if f.fail_brush and r~=resource then error('Injected brush failure') end
        self.Brush.ResourceObject=r
    end
    f.images={f.image}
    function f.panel:GetChildrenCount() return #f.images end
    function f.panel:GetChildAt(i) return f.images[i+1] end
    f.root.WidgetTree=object('Tree');f.root.WidgetTree.RootWidget=f.panel
    local schemas={
        CreateRenderTarget2D={{'WorldContextObject','ObjectProperty'},{'Width','IntProperty'},{'Height','IntProperty'},
            {'Format','ByteProperty'},{'ClearColor','StructProperty'},{'bAutoGenerateMipMaps','BoolProperty'},
            {'bSupportUAVs','BoolProperty'},{'ReturnValue','ObjectProperty'}},
        CreateDynamicMaterialInstance={{'WorldContextObject','ObjectProperty'},{'Parent','ObjectProperty'},{'OptionalName','NameProperty'},
            {'CreationFlags','EnumProperty'},{'ReturnValue','ObjectProperty'}},
        SetTextureParameterValue={{'ParameterName','NameProperty'},{'Value','ObjectProperty'}},
        CaptureScene={},
    }
    local library=object('Library')
    local function native(key,action)
        local fn=object('Function')
        function fn:GetFunctionFlags() return 0x400 end
        function fn:ForEachProperty(cb)
            for _,entry in ipairs(schemas[key]) do
                local p={}
                function p:GetFName() return {ToString=function() return f.bad_signature and 'Wrong' or entry[1] end} end
                function p:GetFullName() return entry[2]..' Fixture:'..entry[1] end
                cb(p)
            end
        end
        return setmetatable(fn,{__call=function(_,...) return action(...) end})
    end
    local calls={
        CreateRenderTarget2D=native('CreateRenderTarget2D',function(_,world,w,h,format,clear,mips,uav)
            assert(world==f.world and w==512 and h==512 and format==2 and clear.A==0 and not mips and not uav)
            f.created=f.created+1;f.texture=object('/Script/Engine.TextureRenderTarget2D');return f.texture
        end),
        CreateDynamicMaterialInstance=native('CreateDynamicMaterialInstance',function(_,world,parent,name,flags)
            assert(world==f.world and parent==f.old_material and name=='None' and flags==0)
            f.material=object('/Script/Engine.MaterialInstance');return f.material
        end),
        SetTextureParameterValue=native('SetTextureParameterValue',function(mat,name,texture)
            assert(mat==f.material and name=='CharacterTexture' and texture==f.texture);mat.bound=texture
        end),
        CaptureScene=native('CaptureScene',function(c) assert(c==f.b);f.captured=f.captured+1 end),
    }
    f.preview=Preview.new({pair=function() return {world=f.world},f.first,f.second end,
        huds=function() return {guest={W_PlayerInventory_Main=f.root}} end,
        visible=function() return not f.hidden end,fname=function(s) return s end,
        find=function(path)
            if path:find('Default__',1,true) then return library end
            return calls[path:match(':([^:]+)$')]
        end,log=function(s) f.logs[#f.logs+1]=s end})
    return f
end
local function test(name,fn) fn();passed=passed+1;print('PASS '..name) end
test('shared direct preview texture becomes private only for the guest capture and brush',function()
    local f=fixture();f.preview:repair()
    assert(f.created==1 and f.captured==1 and f.a.TextureTarget==f.old and f.b.TextureTarget==f.texture)
    assert(f.image.Brush.ResourceObject==f.texture)
end)
test('a proven material parameter uses a private material while preserving the original shader resource',function()
    local f=fixture(true);f.preview:repair()
    assert(f.image.Brush.ResourceObject==f.material and f.material.bound==f.texture)
    assert(f.old_material.TextureParameterValues[1].ParameterValue==f.old and f.a.TextureTarget==f.old)
end)
test('an unknown material binding is left unchanged instead of guessing a shader parameter',function()
    local f=fixture(true);f.old_material.TextureParameterValues={};f.preview:repair()
    assert(f.created==0 and f.b.TextureTarget==f.old and f.image.Brush.ResourceObject==f.old_material)
end)
test('ambiguous duplicate preview brushes do not allocate or replace resources',function()
    local f=fixture();local image=object('/Script/UMG.Image');image.Brush={ResourceObject=f.old};f.images[2]=image
    f.preview:repair();assert(f.created==0 and f.b.TextureTarget==f.old)
end)
test('hidden guest windows and already independent captures retain their existing resources',function()
    local f=fixture();f.hidden=true;f.preview:repair();assert(f.created==0)
    f.hidden=false;f.b.TextureTarget=object('/Script/Engine.TextureRenderTarget2D');f.preview:repair();assert(f.created==0)
end)
test('failed brush assignment restores the original capture and brush',function()
    local f=fixture();f.fail_brush=true;assert(not pcall(function() f.preview:repair() end))
    assert(f.b.TextureTarget==f.old and f.image.Brush.ResourceObject==f.old and not f.preview.record)
end)
test('unexpected native rendering signatures stop before allocation',function()
    local f=fixture();f.bad_signature=true;assert(not pcall(function() f.preview:repair() end))
    assert(f.created==0 and f.b.TextureTarget==f.old)
end)
test('teardown restores our resource assignments and preserves third-party replacements',function()
    local f=fixture();f.preview:repair();local third=object('Other');f.image.Brush.ResourceObject=third
    f.preview:restore();assert(f.b.TextureTarget==f.old and f.image.Brush.ResourceObject==third and f.a.TextureTarget==f.old)
end)
print(passed..' preview resource tests passed (mock rendering API; actual shader/capture output unverified).')
