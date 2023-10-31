local tArgs = { ... }
if #tArgs < 1 then
    shell.setDir(os.passwd.get.byID(os.getUser()).home)
    return
end

local sNewDir = shell.resolve(tArgs[1])
if fs.isDir(sNewDir) then
    shell.setDir(sNewDir)
else
    if fs.exists(sNewDir) then
        print("Not a directory")
    else
        print("No such file or directory")
    end
    return
end
