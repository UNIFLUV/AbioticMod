-- Split only a proven shared capture target and a brush that actually uses it.
-- Preserve a material's shader by cloning it and changing verified parameters.
local Preview={}
Preview.__index=Preview
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function schema(f)
    assert(valid(f) and (f:GetFunctionFlags() & 0x400)~=0,'Native rendering API unavailable')
    local fields={}
    f:ForEachProperty(function(p) fields[#fields+1]={p:GetFName():ToString(),p:GetFullName():match('^(%w+) ')} end)
    return fields
end
local function check(fields,expected)
    assert(#fields==#expected,'Rendering signature length changed')
    for i,p in ipairs(expected) do assert(fields[i][1]==p[1] and fields[i][2]==p[2],'Rendering signature changed: '..fields[i][1]) end
end
local function resource(image) return image.Brush.ResourceObject end
local function parameters(material,texture)
    local names,seen={},{}
    for _=1,6 do
        if not valid(material) or not material:IsA('/Script/Engine.MaterialInstance') then break end
        local values=material.TextureParameterValues
        assert(#values<=64,'Material parameter output capped')
        for i=1,#values do
            local value=values[i]
            local name=value.ParameterInfo.Name:ToString()
            -- The nearest override wins, including an override to another texture.
            if value.ParameterInfo.Association==0 and not seen[name] then
                seen[name]=true
                if same(value.ParameterValue,texture) then names[#names+1]=name end
            end
        end
        material=material.Parent
    end
    return names
end
function Preview.new(api) return setmetatable({api=api,reported={}},Preview) end
function Preview:candidates(root,texture)
    local queue,seen,found={root},{},{}
    for i=1,512 do
        local w=queue[i]
        if not w then break end
        if valid(w) and not seen[w:GetAddress()] then
            seen[w:GetAddress()]=true
            if w:IsA('/Script/UMG.UserWidget') then
                assert(same(w:GetOwningPlayer(),root:GetOwningPlayer()),'Preview child has a different owner')
                local tree=w.WidgetTree
                if valid(tree) and valid(tree.RootWidget) then queue[#queue+1]=tree.RootWidget end
            elseif w:IsA('/Script/UMG.PanelWidget') then
                local n=w:GetChildrenCount(); assert(n<=256,'Inventory panel too large')
                for j=0,n-1 do queue[#queue+1]=w:GetChildAt(j) end
            elseif w:IsA('/Script/UMG.Image') then
                local ok,r=pcall(resource,w)
                if ok and valid(r) then
                    if same(r,texture) then found[#found+1]={image=w,old=r}
                    elseif r:IsA('/Script/Engine.MaterialInterface') then
                        local read,names=pcall(parameters,r,texture)
                        if read and #names>0 then found[#found+1]={image=w,old=r,names=names} end
                    end
                    if not self.reported[w:GetAddress()] then
                        self.reported[w:GetAddress()]=true
                        self.api.log('PREVIEW brush '..w:GetFName():ToString()..' -> '..r:GetFullName())
                    end
                end
            end
        end
        if i==512 and queue[i+1] then self.api.log('PREVIEW inventory tree scan capped') end
    end
    return found
end
function Preview:create_target(world,old)
    local width,height,format=old.SizeX,old.SizeY,old.RenderTargetFormat
    assert(type(width)=='number' and type(height)=='number' and width>0 and height>0 and
        width<=4096 and height<=4096 and width*height<=8388608,'Unsupported preview target dimensions')
    assert(type(format)=='number' and format>=0 and format<=20,'Unsupported preview target format')
    local path='/Script/Engine.KismetRenderingLibrary:CreateRenderTarget2D'
    local f,library=self.api.find(path),self.api.find('/Script/Engine.Default__KismetRenderingLibrary')
    assert(valid(library),'Rendering library unavailable')
    local fields=schema(f)
    local enum_kind=fields[4] and fields[4][2]
    assert(enum_kind=='EnumProperty' or enum_kind=='ByteProperty','Unsupported target format argument')
    check(fields,{{'WorldContextObject','ObjectProperty'},{'Width','IntProperty'},{'Height','IntProperty'},
        {'Format',enum_kind},{'ClearColor','StructProperty'},{'bAutoGenerateMipMaps','BoolProperty'},
        {'bSupportUAVs','BoolProperty'},{'ReturnValue','ObjectProperty'}})
    local c=old.ClearColor
    local texture=f(library,world,width,height,format,{R=c.R,G=c.G,B=c.B,A=c.A},false,false)
    assert(valid(texture) and not same(texture,old),'Separate preview texture not created')
    return texture
end
function Preview:material(world,parent,texture,names)
    local f=self.api.find('/Script/Engine.KismetMaterialLibrary:CreateDynamicMaterialInstance')
    local library=self.api.find('/Script/Engine.Default__KismetMaterialLibrary')
    assert(valid(library),'Material library unavailable')
    local fields=schema(f)
    local expected={{'WorldContextObject','ObjectProperty'},{'Parent','ObjectProperty'},{'OptionalName','NameProperty'}}
    if #fields==5 then expected[#expected+1]={'CreationFlags','EnumProperty'} end
    expected[#expected+1]={'ReturnValue','ObjectProperty'}
    check(fields,expected)
    local material
    if #fields==5 then material=f(library,world,parent,self.api.fname('None'),0)
    else material=f(library,world,parent,self.api.fname('None')) end
    assert(valid(material) and not same(material,parent),'Private preview material not created')
    local setter=self.api.find('/Script/Engine.MaterialInstanceDynamic:SetTextureParameterValue')
    check(schema(setter),{{'ParameterName','NameProperty'},{'Value','ObjectProperty'}})
    for _,name in ipairs(names) do setter(material,self.api.fname(name),texture) end
    return material
end
function Preview:repair()
    local context,first,second=self.api.pair()
    local h=self.api.huds(); if not h then return end
    local root=h.guest.W_PlayerInventory_Main
    if not self.api.visible(root) or not self.api.visible(root.InventoryMain) then return end
    local a,b=first.Pawn.CharacterPane_RenderTarget,second.Pawn.CharacterPane_RenderTarget
    assert(valid(a) and valid(b) and not same(a,b) and same(a:GetOwner(),first.Pawn) and same(b:GetOwner(),second.Pawn),'Preview capture owners changed')
    if self.record then
        local r=self.record
        assert(same(r.capture,b) and same(r.root,root),'Preview context changed')
        if same(b.TextureTarget,r.old) then b.TextureTarget=r.texture end
        if same(resource(r.image),r.old_resource) then r.image:SetBrushResourceObject(r.resource) end
        return
    end
    local old=b.TextureTarget
    if not valid(old) or not same(a.TextureTarget,old) then return end
    local found=self:candidates(root,old)
    if #found~=1 then
        if not self.no_match then self.no_match=true; self.api.log('PREVIEW shared capture target confirmed; verified preview brushes='..#found..'; no resource changed') end
        return
    end
    local binding=found[1]
    local texture=self:create_target(context.world,old)
    local image_resource=binding.names and self:material(context.world,binding.old,texture,binding.names) or texture
    local r={capture=b,root=root,image=binding.image,old=old,texture=texture,old_resource=binding.old,resource=image_resource}
    self.record=r
    local ok,message=pcall(function()
        b.TextureTarget=texture
        binding.image:SetBrushResourceObject(image_resource)
        assert(same(b.TextureTarget,texture) and same(resource(binding.image),image_resource),'Private preview assignment not confirmed')
        local capture=self.api.find('/Script/Engine.SceneCaptureComponent2D:CaptureScene')
        check(schema(capture),{}); capture(b)
        self.api.log('PREVIEW guest capture/brush now use a private texture; host resources retained')
    end)
    if not ok then self:restore(); error(message) end
end
function Preview:restore()
    local r=self.record
    if r then
        if valid(r.capture) and same(r.capture.TextureTarget,r.texture) then r.capture.TextureTarget=r.old end
        if valid(r.image) and same(resource(r.image),r.resource) then r.image:SetBrushResourceObject(r.old_resource) end
    end
    self.record=nil; self.no_match=nil; self.reported={}
end
return Preview
