-- Resolve UE4SS.log from the actual main.lua chunk filename, never process CWD.
-- UE4SS 1ba38db4 load_and_execute_script names the chunk '@' + script_path.
local RuntimeLog={}
function RuntimeLog.path(source)
    assert(type(source)=='string' and source:sub(1,1)=='@','Main script filename unavailable')
    local path=source:sub(2):gsub('\\','/')
    assert(not path:find('[%z\r\n]'),'Invalid main script filename')
    local root,mods,name,scripts,file=path:match('^(.*)/([^/]+)/([^/]+)/([^/]+)/([^/]+)$')
    assert(root and mods:lower()=='mods' and name~='.' and name~='..' and
        scripts:lower()=='scripts' and file:lower()=='main.lua','Unexpected main script directory layout')
    assert(root:match('^%a:/') or root:match('^/[^/]') or root:match('^//[^/]+/[^/]+'),
        'Main script path must be absolute; current directory is not trusted')
    for part in root:gmatch('[^/]+') do assert(part~='.' and part~='..','Noncanonical main script path') end
    return root..'/UE4SS.log'
end
function RuntimeLog.read(source,opener)
    local path=RuntimeLog.path(source)
    local file,message=(opener or io.open)(path,'rb')
    assert(file,'Current UE4SS.log unavailable beside Mods: '..tostring(message))
    local ok,text=pcall(function() return file:read(262144) end)
    file:close()
    assert(ok,'Current UE4SS.log header read failed: '..tostring(text))
    assert(type(text)=='string' and #text>0,'Current UE4SS.log header is empty')
    return text
end
return RuntimeLog
