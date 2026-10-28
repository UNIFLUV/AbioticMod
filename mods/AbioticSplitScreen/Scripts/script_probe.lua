-- F6-only, read-only Kismet report for three known inventory widget classes.
-- The custom byte-array view uses the engine's own logged UStruct::Script offset.
-- No bytecode/array writes, item operations, hooks, or arbitrary pointer wrapping.
local Probe={}
Probe.__index=Probe
local ALIAS='AbioticSplitScreen_ReadOnlyScriptBytes_v1'
local MAX_FUNCTION=131072
local MAX_TOTAL=262144
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function integer(n) return type(n)=='number' and n%1==0 end
function Probe.new(api) return setmetatable({api=api},Probe) end
function Probe:prepare()
    if self.offset then return end
    local header=self.api.header()
    assert(type(header)=='string' and header:find('Git SHA #1ba38db4',1,true) and
        header:find('Using engine version: 5.4',1,true),'Runtime header is not the validated UE4SS/UE 5.4 build')
    local offset
    for hex in header:gmatch('UStruct::Script%s*=%s*0x(%x+)') do
        local n=tonumber(hex,16)
        assert(not offset or offset==n,'Conflicting engine Script offsets')
        offset=n
    end
    assert(offset==0x60,'Logged Script offset differs from validated layout')
    local types=self.api.types
    assert(types and types.ArrayProperty and types.ArrayProperty.Name=='ArrayProperty' and types.ArrayProperty.Size==16 and
        types.ByteProperty and types.ByteProperty.Name=='ByteProperty' and types.ByteProperty.Size==1,
        'Unexpected native array/byte types')
    local class=self.api.find('/Script/CoreUObject.Function')
    local native=self.api.find('/Script/Engine.GameplayStatics:GetPlayerController')
    assert(valid(class) and valid(native) and same(native:GetClass(),class) and
        (native:GetFunctionFlags() & 0x400)~=0,'Native function sanity check unavailable')
    if not self.registered then
        self.api.register({Name=ALIAS,Type=types.ArrayProperty,BelongsToClass='/Script/CoreUObject.Function',
            OffsetInternal=offset,ArrayProperty={Type=types.ByteProperty}})
        self.registered=true
    end
    self.offset=offset
    local ok,message=pcall(function()
        local _,n=self:array(native)
        assert(n==0,'Native function Script is not empty; read-only view rejected')
    end)
    if not ok then self.offset=nil;error(message) end
end
function Probe:array(f)
    assert(valid(f),'Script function expired')
    local a=f[ALIAS]
    assert(a~=nil and type(a.GetArrayAddress)=='function' and
        a:GetArrayAddress()==f:GetAddress()+self.offset,'Script view does not point to the logged field')
    local n,max=a:GetArrayNum(),a:GetArrayMax()
    assert(integer(n) and integer(max) and n>=0 and max>=n and max<=1048576,'Invalid Script array bounds')
    if n>0 then
        local data=a:GetArrayDataAddress()
        assert(integer(data) and data>0x10000 and data<=0x7fffffffffff,'Invalid Script data address')
    end
    return a,n
end
function Probe:bytes(f)
    local a,n=self:array(f)
    assert(n<=MAX_FUNCTION,'Script exceeds per-function report bound')
    local result={}
    -- UE4SS 1ba38db4 documents a large-array ForEach stack-corruption issue.
    -- Its index getter can grow arrays out of bounds. Check bounds BEFORE every
    -- read and never read an empty array, so neither path is used here.
    for i=1,n do
        assert(a:GetArrayNum()==n,'Script array changed during read')
        local byte=a[i]
        assert(integer(byte) and byte>=0 and byte<=255,'Invalid Script byte')
        result[i]=byte
    end
    assert(a:GetArrayNum()==n,'Script array changed after read')
    assert(n==0 or result[n]==0x53,'Blueprint Script lacks EndOfScript; report rejected')
    return result
end
function Probe:dump()
    if self.finished then self.api.log('SCRIPTTRACE report already collected this launch; send UE4SS.log');return end
    local _,first,second=self.api.pair()
    local h=assert(self.api.huds(),'Two HUDs required')
    local root=h.guest.W_PlayerInventory_Main
    assert(valid(first.Pawn) and valid(second.Pawn) and not same(first.Pawn,second.Pawn) and valid(root) and
        same(root:GetOwningPlayer(),second) and same(second.Pawn.InventoryReference,root),'Guest inventory context changed')
    local component=root.ActiveContainer
    local container=root.CurrentContainerWidget
    assert(valid(component) and component:IsA('/Script/Engine.ActorComponent') and
        valid(container) and same(container:GetOwningPlayer(),second),
        'Open the guest container before F6; no item transfer is needed')
    self:prepare()
    local functions,seen,classes={}, {}, {}
    local properties=0
    local function catalog(class,export)
        for _=1,3 do
            if not valid(class) or classes[class:GetAddress()] then break end
            classes[class:GetAddress()]=true
            local count=0
            class:ForEachFunction(function(f)
                count=count+1;if count>384 then return true end
                local id=f:GetAddress()
                if not seen[id] then
                    seen[id]=true
                    local fn=f:GetFName()
                    local text=fn:ToString():lower()
                    local flags=f:GetFunctionFlags()
                    if export or text:find('player',1,true) or text:find('widget',1,true) or text:find('invent',1,true) then
                        self.api.log(string.format('SCRIPTTRACE FN address=0x%x nameid=%d flags=0x%x path=%s',
                            id,fn:GetComparisonIndex(),flags,f:GetFullName()))
                    end
                    if export and (flags & 0x400)==0 and
                        (text:find('ubergraph',1,true) or text:find('take',1,true) or
                         text:find('transfer',1,true) or text:find('key',1,true) or text:find('widgetaction',1,true)) then
                        assert(#functions<128,'Too many candidate functions')
                        functions[#functions+1]=f
                    end
                    if export then
                        f:ForEachProperty(function(p)
                            properties=properties+1;if properties>2048 then return true end
                            local ok,address=pcall(function() return p:GetAddress() end)
                            if ok and integer(address) then
                                self.api.log(string.format('SCRIPTTRACE PROP address=0x%x path=%s',address,p:GetFullName()))
                            end
                        end)
                    end
                end
            end)
            class=class:GetSuperStruct()
        end
    end
    self.api.log('SCRIPTTRACE REPORT-BEGIN version=1 offset=0x60')
    -- Process the container graph first; the root/grid follow within the budget.
    catalog(container:GetClass(),true)
    catalog(root:GetClass(),true)
    local grid=container.W_InventoryGrid
    if valid(grid) and same(grid:GetOwningPlayer(),second) then catalog(grid:GetClass(),true) end
    for _,path in ipairs({'/Script/AbioticFactor.AbioticFunctionLibrary','/Script/Engine.GameplayStatics',
        '/Script/UMG.WidgetBlueprintLibrary','/Script/UMG.WidgetLayoutLibrary'}) do
        local c=self.api.find(path)
        if valid(c) then catalog(c,false) end
    end
    local total,seq=0,0
    for _,f in ipairs(functions) do
        local ok,message=pcall(function()
            local _,n=self:array(f)
            assert(total+n<=MAX_TOTAL,'Total report byte limit reached')
            local bytes=self:bytes(f)
            if #bytes==0 then return end
            seq=seq+1;total=total+#bytes
            self.api.log(string.format('SCRIPTTRACE BEGIN seq=%d bytes=%d address=0x%x path=%s',seq,#bytes,f:GetAddress(),f:GetFullName()))
            local a,b=1,0
            for offset=0,#bytes-1,128 do
                local hex={}
                for i=offset+1,math.min(offset+128,#bytes) do
                    local byte=bytes[i];hex[#hex+1]=string.format('%02x',byte)
                    a=(a+byte)%65521;b=(b+a)%65521
                end
                self.api.log(string.format('SCRIPTTRACE HEX seq=%d offset=%d data=%s',seq,offset,table.concat(hex)))
            end
            self.api.log(string.format('SCRIPTTRACE END seq=%d bytes=%d adler32=%08x',seq,#bytes,(b<<16)|a))
        end)
        if not ok then self.api.log('SCRIPTTRACE SKIP '..f:GetFullName()..': '..tostring(message)) end
    end
    assert(seq>0,'No valid Blueprint bytecode was collected; inspect SCRIPTTRACE SKIP')
    self.finished=true
    self.api.log(string.format('SCRIPTTRACE REPORT-END scripts=%d bytes=%d; no script/item/save writes performed',seq,total))
end
return Probe
