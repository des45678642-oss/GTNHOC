--------------------------------------------------------------------------------
-- bootstrap_installer.lua —— 精简版引导器（仅直连）
--------------------------------------------------------------------------------

local component  = require("component")
local filesystem = require("filesystem")
local shell      = require("shell")

local ARGS       = { ... }

local CORE_URL   = "https://raw.githubusercontent.com/des45678642-oss/GTNHOC/refs/heads/main/installer_core.lua"
local CWD        = (shell.getWorkingDirectory():gsub("//+", "/"))
local CORE_PATH  = CWD .. "/.installer_core.lua"
local LOG_PATH   = CWD .. "/bootstrap_installer.log"

local LOG_ON = false
for _, a in ipairs(ARGS) do
    if a == "--debug" or a == "-d" then LOG_ON = true end
end

local LOG_LINES = {}
local function log(text)
    if LOG_ON then LOG_LINES[#LOG_LINES + 1] = text end
end

local function flushLog(title)
    if not LOG_ON then return end
    local f = io.open(LOG_PATH, "w")
    if not f then return end
    f:write(title .. "\n" .. table.concat(LOG_LINES, "\n") .. "\n")
    f:close()
end

local function fetch(url, dest)
    local tmp = dest .. ".tmp"
    filesystem.remove(tmp)
    filesystem.remove(dest)
    local rc = shell.execute("wget -f " .. url .. " " .. tmp)
    if not filesystem.exists(tmp) or filesystem.size(tmp) == 0 then
        filesystem.remove(tmp)
        return false, "下载失败（wget 返回 " .. tostring(rc) .. "）"
    end
    local chunk, err = loadfile(tmp)
    if not chunk then
        filesystem.remove(tmp)
        return false, "下载内容无法编译：" .. tostring(err)
    end
    local _, mvErr = filesystem.rename(tmp, dest)
    if filesystem.exists(tmp) then
        filesystem.remove(tmp)
        return false, "改名失败：" .. tostring(mvErr)
    end
    return true, chunk
end

local function main()
    if CWD:find(" ") then
        error("当前目录里有空格：" .. CWD .. "。OC 的 wget 命令行按空格切参数，请换目录。")
    end
    if not component.isAvailable("internet") then
        error("没检测到因特网卡（Internet Card）。")
    end

    print("下载安装器核心：installer_core.lua")
    local ok, result = fetch(CORE_URL, CORE_PATH)
    log(string.format("下载 core：%s -> %s", CORE_URL, ok and "OK" or tostring(result)))
    if not ok then error("无法下载最新安装器：" .. tostring(result)) end
    local chunk = result

    print("执行安装器核心：installer_core.lua")
    local ok2, res, err = xpcall(function()
        return chunk(table.unpack(ARGS))
    end, debug.traceback)

    if not ok2 or res == false then
        local text = not ok2 and tostring(res) or tostring(err or "安装器核心返回失败")
        print("[引导器] 安装未成功，保留下载的 core 以便排错：" .. CORE_PATH)
        flushLog("core 执行失败：" .. text)
        return false, text
    end

    filesystem.remove(CORE_PATH)
    print("安装器核心执行成功，已删除本次下载的 installer_core.lua")
    flushLog("core 执行成功并已删除")
    return true
end

local ok, result, err = xpcall(main, debug.traceback)
if not ok then
    print("\n[引导器出错]\n" .. tostring(result))
    return false, result
end
return result, err