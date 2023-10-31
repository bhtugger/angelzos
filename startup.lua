--@class 
-- by: AngeLz
--[[computercraft 1.8.0]]--
local function deepcopy(orig, copies)
    copies = copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
            end
            setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

term.clear()
term.setCursorPos(1,1)

os.pullEvent = os.pullEventRaw

-- default values
local oldFs = deepcopy(_G.fs)
local oldOs = deepcopy(_G["os"])

local user = 0
local groups = { 0, -1 } -- -1 is sudoer group
local sudo = true
local sudoing = false
local fstrhost = fs.open('/etc/hostname', 'r') or { readAll = function() return 'localhost' end, close = function() end }
local hostname = fstrhost.readAll()
local systemVersion = "AngeLzOS 1.1.0"
local expect = require('cc.expect').expect
local pretty = require('cc.pretty').pretty
fstrhost.close()

shell = {}

_G.os.passwd = { get = {} }

_G.os.passwd.get.byID = function(id)
    local file = fs.open("etc/passwd.conf","r")
    if not file then
        error("No passwd file found",2)
    end
    local data = textutils.unserialize(file.readAll())
    file.close()
    data[id].id = id
    return data[id]
end

_G.os.passwd.get.byName = function (name)
    -- reads the passwd file and returns the id
    local file = fs.open("etc/passwd.conf","r")
    if not file then
        error("No passwd file found",2)
    end
    local data = textutils.unserialize(file.readAll())
    file.close()
    for i,v in pairs(data)do
        if v.name == name then
            return os.passwd.get.byID(i)
        end
    end
end

-- converts number like 755 to a table like { r = true , w = true , x = true }
-- converts first number to bitmask and then to table
local function conv(mr)
    local owner = { r = false , w = false , x = false }
    local group = { r = false , w = false , x = false }
    local other = { r = false , w = false , x = false }
    local b = tostring(string.sub(mr,1,1))
    if bit.band(b,4) == 4 then owner.r = true end
    if bit.band(b,2) == 2 then owner.w = true end
    if bit.band(b,1) == 1 then owner.x = true end    
    b = tostring(string.sub(mr,2,2))
    if bit.band(b,4) == 4 then group.r = true end
    if bit.band(b,2) == 2 then group.w = true end
    if bit.band(b,1) == 1 then group.x = true end
    b = tostring(string.sub(mr,3,3))
    if bit.band(b,4) == 4 then other.r = true end
    if bit.band(b,2) == 2 then other.w = true end
    if bit.band(b,1) == 1 then other.x = true end
    return { owner = owner , group = group , other = other }
end

-- permission checker that uses 
local function fsReadPermission(path)
    local fsR = oldFs.open("/fs.conf","r")
    local fsConf = fsR.readAll()
    fsConf = textutils.unserialize(fsConf)
    fsR.close()
    local config = fsConf[path]
    local perms = { you = { r = false, w = false, x = false}, owner = { r = false, w = false, x = false}, group = { r = false, w = false, x = false}, other = { r = false, w = false, x = false} }
    if config then
        perms.owner = conv(config.mode).owner
        perms.group = conv(config.mode).group
        perms.other = conv(config.mode).other
    end
    if not sudo then
        -- checks each permission from root to file
        -- checks /folder then filename
        -- checks if file is in a directory
        if oldFs.getDir(path) ~= "" then
            local path = oldFs.getDir(path)
            local data = fsReadPermission(path)
            -- changes perms to false if return data is false
            for i,v in pairs(data) do
                if not v then
                    perms.you[i] = false
                end
            end
        end
    else -- if sudo is true then it will return true for all permissions
        perms.you = { r = true, w = true, x = true}
    end
    if config == nil then
        perms.owner = {
            r = true,
            w = not oldFs.isReadOnly(path),
            x = true,
        }
        perms.group = {
            r = true,
            w = false,
            x = true,
        }
        perms.other = {
            r = true,
            w = false,
            x = true,
        }
        return { 
            perms = perms.you,
            ownerPerms = perms.owner,
            groupPerms = perms.group,
            otherPerms = perms.other,
            owner = 0,
            group = 0,
        }
    end
    return {
        perms = perms.you,
        ownerPerms = perms.owner,
        groupPerms = perms.group,
        otherPerms = perms.other,
        owner = config.owner,
        group = config.group,
    }
end

-- changes perms
local checkPermission = function(path)
    local perms = fsReadPermission(path)
    perms.perms = deepcopy(perms.otherPerms)
    -- checks if group matches 
    for i,v in pairs(groups) do
        if v == perms.group then
            perms.perms = deepcopy(perms.groupPerms)
        end
    end
    -- checks if owner matches
    if perms.owner == user then
        perms.perms = deepcopy(perms.ownerPerms)
    end
    return perms
end

-- processes for this 
-- a rewrite to fs, basically we are going to take the mounts
-- mounts would be done like 
-- { 
--   path = "/slash", mount = "/",
--   path = "/disk", mount = "/disk"
--   path = "folder/", mount = "/disk/folder
-- }

-- if at / it would be /slash
-- if at /disk it would be /disk
-- if at /disk/folder it would be /folder


local mounts = {}
local function convertFS(mountData)
    for i,v in pairs(mountData) do
        mounts[#mounts+1] = {
            path = oldFs.combine(v.path,""),
            mount = oldFs.combine(v.mount,""),
        }
    end

    local function checkRoot(path)
        expect(1, path, "string")
        path = oldFs.combine(path,"")
        local mountPath = false 
        if (path == "..") then
            return false
        end
        if string.match(path, "^%.%./") then
            return false
        end
        for _, mount in ipairs(mounts) do
            if string.match(path, "^" .. mount.mount) then
                mountPath = mount.path
                -- removes mount path from path
                path = string.gsub(path, "^" .. mount.mount, "")
                path = oldFs.combine(path,"")
            end
        end
        return mountPath, path
    end

    local function changePathToReal(path)
        expect(1, path, "string")
        oldFs.combine(path,"") -- cleans up the path
        local path = path or ""
        local directory, path = checkRoot(path)
        if not directory then
            return ""
        end
        path = oldFs.combine(directory,path)
        return path
    end

    local function findMountsInDirectory(directoryPath, mounts)
        local mountsInPath = {}
        
        for _, mount in ipairs(mounts) do
            local pathComponents = {}
            for component in string.gmatch(mount.path, "[^/]+") do
                table.insert(pathComponents, component)
            end
            
            local dirComponents = {}
            for component in string.gmatch(directoryPath, "[^/]+") do
                table.insert(dirComponents, component)
            end
            
            local matches = true
            for i, component in ipairs(dirComponents) do
                if pathComponents[i] ~= component then
                    matches = false
                    break
                end
            end
            
            if (matches and #pathComponents > #dirComponents) or (directoryPath == "") then
                table.insert(mountsInPath, mount.mount)
            end
        end
        
        return mountsInPath
    end

    _G.fs.list = function(path)
        expect(1, path, "string")
        local modifiedPath = changePathToReal(path)
        local perms = checkPermission(modifiedPath)
        if not perms.perms.r then
            error(path..": Permission denied", 2)
        end
        local list = oldFs.list(modifiedPath)

        local mountsInPath = findMountsInDirectory(path, mounts)

        for _, mount in ipairs(mountsInPath) do
            if mount ~= path then
                table.insert(list, mount)
            end
        end
        return list
    end

    _G.fs.exists = function(path)
        expect(1, path, "string")
        if not checkRoot(path) then
            return false
        end
        path = changePathToReal(path)
        local fsEx = oldFs.exists(path)
        if fsEx then
            local perms = checkPermission(path)
            if not perms.perms.r then
                error(path..": Permission denied", 2)
            end
        end
        return fsEx
    end

    _G.fs.isDir = function(path)
        -- checks if the directory is in a directory then checks if thats a directory
        if not checkRoot(path) then
            return false
        end
        path = changePathToReal(path)
        return oldFs.isDir(path)
    end

    _G.fs.isDriveRoot = function(path)
        if not checkRoot(path) then
            return false
        end
        path = changePathToReal(path)
        return oldFs.isDriveRoot(path)
    end

    _G.fs.isReadOnly = function(path)
        if not checkRoot(path) then
            return false
        end
        path = changePathToReal(path)
        local perms = checkPermission(path)
        local isReadOnly = oldFs.isReadOnly(path)
        if not perms.perms.w then 
            return true
        else
            return isReadOnly
        end
    end

    _G.fs.getSize = function(path)
        if not checkRoot(path) then
            error(path..": No such file", 2)
        end
        path = changePathToReal(path)
        local perms = checkPermission(path)
        if not perms.perms.r then
            error(path..": Permission denied", 2)
        end
        local size = oldFs.getSize(path)
        return size
    end

    _G.fs.getFreeSpace = function(path)
        if not checkRoot(path) then
            error(path..": No such path", 2)
        end
        path = changePathToReal(path)
        local freeSpace = oldFs.getFreeSpace(path)
        return freeSpace
    end

    _G.fs.makeDir = function(path)
        if not checkRoot(path) then
            error(path..": Could not create directory", 2)
        end
        path = changePathToReal(path)
        local perms = checkPermission(path)
        if not perms.perms.w then
            error(path..": Permission denied", 2)
        end
        local makeDir = oldFs.makeDir(path)
        return makeDir
    end

    _G.fs.move = function(fromPath, toPath)
        if not checkRoot(fromPath) then
            error("No such file", 2)
        end
        if not checkRoot(toPath) then
            error(path..": Invalid path", 2)
        end
        fromPath = changePathToReal(fromPath)
        toPath = changePathToReal(toPath)
        local perms = checkPermission(fromPath)
        local perms2 = checkPermission(toPath)
        if not perms.perms.w then
            error(fromPath..": Permission denied", 2)
        end
        if not perms2.perms.w then
            error(toPath..": Permission denied", 2)
        end
        local move = oldFs.move(fromPath, toPath)
        return move
    end

    _G.fs.copy = function(fromPath, toPath)
        fromPath = changePathToReal(fromPath)
        if not checkRoot(fromPath) then
            error("No such file", 2)
        end
        if not checkRoot(toPath) then
            error(path..": Invalid path", 2)
        end
        toPath = changePathToReal(toPath)
        local perms = checkPermission(fromPath)
        local perms2 = checkPermission(toPath)
        if not perms.perms.r then
            error(fromPath..": Permission denied", 2)
        end
        if not perms2.perms.w then
            error(toPath..": Permission denied", 2)
        end
        local copy = oldFs.copy(fromPath, toPath)
        return copy
    end

    _G.fs.delete = function(path)
        path = fs.combine(path,"")
        if path == "" then
            error("Cannot delete root", 2)
        end
        path = changePathToReal(path)
        -- checks if the path is a mount directory
        local isMount = false
        for _, mount in ipairs(mounts) do
            if mount.path == path then
                isMount = true
            end
        end
        if isMount then
            error("Cannot delete mount /"..path, 2)
        end
        local perms = checkPermission(path)
        if not perms.perms.w then
            error(path..": Permission denied", 2)
        end
        return oldFs.delete(path)
    end

    _G.fs.open = function(path, mode)
        expect(1, path, "string")
        expect(2, mode, "string")
        if not checkRoot(path) then
            return nil, path..": No such file"
        end
        path = changePathToReal(path)
        local mode = mode
        local perms = checkPermission(path)
        if mode == "r" then
            if not perms.perms.r then
                return nil, path..": Permission denied"
            end
        elseif mode == "w" then
            if not perms.perms.w then
                return nil, path..": Permission denied"
            end
        elseif mode == "a" then
            if not perms.perms.w then
                return nil, path..": Permission denied"
            end
        end
        local file = oldFs.open(path, mode)
        return file
    end

    _G.fs.complete = function(path, pathToComplete, arg)
        local pathToComplete = pathToComplete or ""
        path = changePathToReal(path)
        local complete = oldFs.complete(path, pathToComplete, arg)
        return complete
    end

    _G.fs.find = function(path)
        if not checkRoot(path) then
            error("Not a directory", 2)
        end
        path = changePathToReal(path)
        local perms = checkPermission(path)
        if not perms.perms.r then
            error(path..": Permission denied", 2)
        end
        local find = oldFs.find(path)
        local findModified = {}
        -- removes mounts from find
        -- eg /slash/filename to /filename
        for i,v in pairs(find) do
            for _, mount in ipairs(mounts) do
                if string.match(v, "^" .. mount.path) then
                    v = string.gsub(v, "^" .. mount.path, "")
                    v = oldFs.combine(mount.mount,v)
                end
            end
            findModified[#findModified+1] = v
        end
        return findModified
    end

    _G.fs.getPermissions = function(...)
        local path = ({...})[1]
        expect(1,path, "string")
        if not checkRoot(path) then
            error("Not a directory", 2)
        end
        path = changePathToReal(path)
        local perms = checkPermission(path)
        return perms
    end

    _G.fs.setPermissions = function(...)
        local path = ({...})[1]
        local perms = ({...})[2]
        
    end
end

convertFS({
    {
        path= "/slash",
        mount= "/",
    },
    {
        path= "/romcopy",
        mount= "/rom"
    }
    
})

local function lua() 
    term.clear()
    term.setCursorPos(1,1)
    local pretty = require and require "cc.pretty" or dofile "/rom/modules/main/cc/expect.lua"

    local bRunning = true
    local tCommandHistory = {}
    local tEnv = {
        ["exit"] = setmetatable({}, {
            __tostring = function() return "Call exit() to exit." end,
            __call = function() bRunning = false end,
        }),
        ["_echo"] = function(...)
            return ...
        end,
    }
    setmetatable(tEnv, { __index = _ENV })

    if term.isColour() then
        term.setTextColour(colours.yellow)
    end
    print(_G._CCPC_DEBUGGER_ACTIVE and "Entering debugger." or "Interactive Lua prompt.")
    print("Call exit() to exit.")
    term.setTextColour(colours.white)

    while bRunning do
        --if term.isColour() then
        --    term.setTextColour( colours.yellow )
        --end
        write(_G._CCPC_DEBUGGER_ACTIVE and "lua_debug> " or "lua> ")
        --term.setTextColour( colours.white )

        local s = read(nil, tCommandHistory, function(sLine)
            if settings.get("lua.autocomplete") then
                local nStartPos = string.find(sLine, "[a-zA-Z0-9_%.:]+$")
                if nStartPos then
                    sLine = string.sub(sLine, nStartPos)
                end
                if #sLine > 0 then
                    return textutils.complete(sLine, tEnv)
                end
            end
            return nil
        end)
        if s:match("%S") and tCommandHistory[#tCommandHistory] ~= s then
            table.insert(tCommandHistory, s)
        end
        if settings.get("lua.warn_against_use_of_local") and s:match("^%s*local%s+") then
            if term.isColour() then
                term.setTextColour(colours.yellow)
            end
        print("To access local variables in later inputs, remove the local keyword.")
        term.setTextColour(colours.white)
        end

        local nForcePrint = 0
        local func, e = load(s, "=lua", "t", tEnv)
        local func2 = load("return _echo(" .. s .. ");", "=lua", "t", tEnv)
        if not func then
            if func2 then
                func = func2
                e = nil
                nForcePrint = 1
            end
        else
            if func2 then
                func = func2
            end
        end

        if func then
            local tResults = table.pack(pcall(func))
            if tResults[1] then
                local n = 1
                while n < tResults.n or n <= nForcePrint do
                    local value = tResults[n + 1]
                    local ok, serialised = pcall(pretty.pretty, value, {
                        function_args = settings.get("lua.function_args"),
                        function_source = settings.get("lua.function_source"),
                    })
                    if ok then
                        pretty.print(serialised)
                    else
                        print(tostring(value))
                    end
                    n = n + 1
                end
            else
                printError(tResults[2])
            end
        else
            printError(e)
        end

    end
end

_G.os.version = function() 
    return systemVersion
end

_G.os.motd = function()
    local tMotd = {}

    for sPath in string.gmatch(settings.get("motd.path"), "[^:]+") do
        if oldFs.exists(sPath) then
            local data = oldFs.open(sPath, "r")
            local sLine = ""
            while true do
                local sChar = data.read(1)
                if sChar == "\n" or sChar == nil then
                    if sLine ~= "" then
                        tMotd[#tMotd + 1] = sLine
                    end
                    if sChar == nil then
                        break
                    end
                    sLine = ""
                else
                    sLine = sLine .. sChar
                end
            end
            data.close()
        end
    end

    if #tMotd == 0 then
        return "Motd not found"
    else
        return tMotd[math.random(1, #tMotd)]
    end
end

_G.os.getHostname = function()
    local host = hostname
    return host
end

_G.os.getUser = function()
    local userId = user
    return userId
end

_G.setUser = function(id)
    user = id
end

_G.unsudo = function()
    sudoing = false
    sudo = false
end

_G.os.sudo = function(pass)
    local user = os.getUser()
    if pass == os.passwd.get.byID(user).pass then
        -- allows sudo until next yield
        sudo = true
        return true
    elseif user == 0 then
        sudo = true
        return true
    else
        return false
    end
end

_G.os.isSudo = function()
    local sudo = sudo
    return sudo
end

local sandboxed = false

_G.sandboxed = function()
    local d = sandboxed
    return d
end

-- coroutine scheduler with filters
local id = 0    
local coroutines = {}
-- coroutine id
local deadCoroutines = {}
local function scheduler()
    -- adds a coroutine to the scheduler    
    local function addCoroutine(func, options)
        expect(1, func, "function")
        expect(2, options, "table", "nil")
        local options = options
        local prerun, loops, optionUser, name, noTerminate, sandbox = options.prerun, options.loops, options.user, options.name, options.noTerminate or true, options.sandbox or true
        if not sudo then
            optionUser = user
        end
        optionUser = optionUser or user
        if optionUser == 0 then
            sandbox = false
        end
        local generatedENV = {} 
        if sandbox then 
            generatedENV = deepcopy(getfenv(func))
            generatedENV._G = deepcopy(_G)
            generatedENV.shell = deepcopy(shell)
        else
            generatedENV = getfenv(func)
        end
        local envFunction = setfenv(func, generatedENV)
        if not envFunction then
            error("Failed to load function on thread: "..(name or "Unnamed Thread"), 2)
        end
        local co = coroutine.create(envFunction)
        local c = {
            co = co,
            loops = loops,
            user = optionUser,
            id = id,
            func = envFunction,
            running = prerun or false,
            mainFilter = nil,
            noTerminate = noTerminate,
            name = name or "Unnamed Thread",
            usage = 0,
            env = generatedENV,
            sandbox = sandbox,
        }
        coroutines[#coroutines+1] = c
        id = id + 1
        return c
    end
    local function getCoroutine(id)
        for i,v in pairs(coroutines) do
            if v.id == id then
                v.index = i
                return v
            end
        end
    end
    local function runCoroutine(id)
        local val = getCoroutine(id)
        if val then
            if val.user == user or sudo then
                coroutines[id].running = true
            else
                error("You do not have permission to start this coroutine",1)
            end
        end
    end
    -- Stops the coroutine
    local function stopCoroutine(id)
        local val = getCoroutine(id)
        if val then
            if val.user == user or sudo then
                coroutines[id].running = false
            else
                error("You do not have permission to stop this coroutine",1)
            end
        end
    end
    -- runs the coroutines
    local function run()
        local ev = { n = 0 }
        while true do
            -- this goes up if a coroutine is deleted mid way through a loop
            local offset = 0
            for i=1,#coroutines do
                local startTime = os.epoch("utc")
                local o = i-offset
                local co = coroutines[o].co
                local loops = coroutines[o].loops or false
                local Coruser = coroutines[o].user
                user = Coruser or user
                local running = coroutines[o].running
                if coroutine.status(co) == "dead" and loops == false then
                    deadCoroutines[#deadCoroutines+1] = coroutines[o]
                    table.remove(coroutines,o)
                    offset = offset + 1
                elseif coroutine.status(co) == "dead" and loops == true then
                    co = coroutine.create(coroutines[o].func)
                elseif running then
                    if ev[1] == "terminate" and coroutines[o].noTerminate ~= true then
                        error("Terminated",0)
                    else
                        local e = ev[1] or ""
                        if e..coroutines[o].id == coroutines[o].mainFilter or not coroutines[o].mainFilter then
                            if coroutine.status(co) == "dead" then
                                coroutines[o].co = coroutine.create(coroutines[o].func)                            
                            else 
                                -- sets sudo to true if the coroutine if system is sudoing
                                if user == 0 then
                                    sudo = true
                                elseif sudoing then
                                    sudo = true
                                else
                                    sudo = false
                                end
                                if coroutines[o].sandbox then
                                    sandboxed = true
                                else
                                    sandboxed = false
                                end
                                local ok, err = coroutine.resume(co, table.unpack(ev,1))
                                if ok then
                                    if err then
                                        err = err..coroutines[o].id
                                    end
                                    coroutines[o].mainFilter = err
                                else
                                    printError(err)
                                end                                    
                                -- stops sudoing
                                sudoing = false
                            end
                        end
                    end
                end
                if coroutine.status(co) ~= "dead" then
                    local endTime = os.epoch("utc")
                    coroutines[o].usage = endTime - startTime
                end
            end
            ev = table.pack(os.pullEventRaw())
        end
    end
    return addCoroutine, run, runCoroutine, getCoroutine, stopCoroutine
end 

_G.os.addCoroutine,_,_G.os.runCoroutine,_G.os.getCoroutine,_G.os.stopCoroutine = scheduler() --require("/boot/apis/coro")
local _,run = scheduler()


local function recovery(data)
    local options ={"Continue","Reboot system now","Reboot to bootloader","Mount /rom","Load Lua","Boot into CraftOS","Power off"}
    local o = 0
    while true do
        term.clear()
        term.setCursorPos(1,1)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.yellow)
        print('AngeLzOS Recovery')
        print(data.message)
        print("Error: "..data.error)
        print("Use arrow keys up/down and enter.")
        for k,v in pairs(options) do
            if k == o then 
                term.setTextColor(colors.white)
                term.setBackgroundColor(colors.blue)
                term.clearLine()
                print(v)
                term.setBackgroundColor(colors.black)
            else
                term.setTextColor(colors.blue)
                term.setBackgroundColor(colors.black)
                term.clearLine()
                print(v)
                term.setBackgroundColor(colors.black)
            end
        end
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        local _, key = os.pullEvent("key")
            if key == keys.up and o > 1 then
        o = o - 1
            elseif key == keys.down and o < #options then
        o = o + 1
            elseif key == keys.enter then
            break
        end
    end
    if o == 1 then
        local sShell
        if term.isColour() and settings.get("bios.use_multishell") then
            sShell = "rom/programs/advanced/multishell.lua"
        elseif settings.get("bios.use_cash") then
            sShell = "rom/programs/cash.lua"
        else
            sShell = "rom/programs/shell.lua"
        end
        if not fs.exists(sShell) then 
            recovery({
                error = "Shell not found",
                message = "Your PC did not start up correctly.",
            })
            os.shutdown()
            return
        end
        os.run({}, sShell)
        os.run({}, "rom/programs/shutdown.lua")
    elseif o == 2 then
        os.reboot()
    elseif o == 3 then
        os.reboot()
    elseif o == 4 then
        -- adds /rom to mounts
        mounts[#mounts+1] = {
            path = "/rom",
            mount = "/rom",
        }
    elseif o == 5  then
        term.clear()
        lua()
    elseif o == 6 then
        -- boots into craftos
        _G.fs = oldFs
        shell = {}
        _G.os = oldOs
        local sShell
        if term.isColour() and settings.get("bios.use_multishell") then
            sShell = "rom/programs/advanced/multishell.lua"
        elseif settings.get("bios.use_cash") then
            sShell = "rom/programs/cash.lua"
        else
            sShell = "rom/programs/shell.lua"
        end
        local setget = settings.get
        settings.get = function(a)
            if a == "shell.allow_startup" then
                return false
            elseif a == "shell.allow_disk_startup" then
                return false
            else 
                return setget(a)
            end
        end
        os.run({}, sShell)
        os.run({}, "rom/programs/shutdown.lua")
    elseif o == 7 then
        os.shutdown()
    end
end
local crashed = false
shellActive = false
local shellC = function()
    if (crashed) then
        recovery({
            error = "CC Crashed",
            message = "Your PC did not start up correctly.",
        })
    else
        local sShell
        if term.isColour() and settings.get("bios.use_multishell") then
            sShell = "rom/programs/advanced/multishell.lua"
        elseif settings.get("bios.use_cash") then
            sShell = "rom/programs/cash.lua"
        else
            sShell = "rom/programs/shell.lua"
        end
        if not fs.exists(sShell) then 
            recovery({
                error = "Shell not found",
                message = "Your PC did not start up correctly.",
            })
            os.shutdown()
            return
        end
        os.run({}, sShell)
        os.run({}, "rom/programs/shutdown.lua")
    end
end

os.addCoroutine(function()
    local shellCoroutine
    -- header on login screen
    term.clear()
    term.setCursorPos(1,1)
    print(os.version())
    pcall(function()
        while true do
            if shellActive then
                sleep(1)
                if not os.getCoroutine(shellCoroutine) then
                    shellActive = false
                end
            else
                term.write("login as: ")
                local user = (read() or "root")
                local users = os.passwd.get.byName(user)
                if not users then
                    term.write("password: ")
                    read("*")
                    sleep(2)
                else
                    term.write("password: ")
                    local pass = read("*")
                    if pass == users.pass then
                        local userId = os.passwd.get.byName(user).id
                        shellActive = true
                        shellCoroutine = os.addCoroutine(shellC,{ prerun = true, loops = false, noTerminate = true, user = userId, name = "shell" }).id
                    else
                        print("login incorrect")
                        sleep(2)
                    end
                end
            end
        end
    end)
end, { prerun = true, loops = true, noTerminate = true, name = "init" })


run()