--------------------------------------------------------------------------------
-- tape.lua —— 磁帶機寫入 + 循環播放（合併版）
--
-- 用法：
--   tape write <檔案.dfpwm> [標籤]   寫入磁帶，並自動記錄長度
--   tape play                        循環播放（依標籤查長度）
--
-- 標籤預設為檔名（不含副檔名）。長度記錄在 LENS_PATH，
-- 播放時每次放入磁帶都會重新讀取，所以寫入後不用重啟播放程式。
--------------------------------------------------------------------------------

local component     = require("component")
local serialization = require("serialization")
local filesystem    = require("filesystem")

local LENS_PATH   = "/etc/tape_lens.cfg"
local DEFAULT_LEN = 983040          -- 查不到長度時的預設值（4 分鐘磁帶容量）
local CHUNK       = 8192
local TAIL        = 2048            -- 距離結尾多少位元組時跳回開頭

local function getTape()
  if not component.isAvailable("tape_drive") then
    error("沒偵測到磁帶機（tape_drive）。")
  end
  return component.tape_drive
end

local function loadLens()
  local f = io.open(LENS_PATH, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local t = serialization.unserialize(text)
  return type(t) == "table" and t or {}
end

local function saveLens(lens)
  local f = assert(io.open(LENS_PATH, "w"))
  f:write(serialization.serialize(lens))
  f:close()
end

--------------------------------------------------------------------------------
-- 寫入
--------------------------------------------------------------------------------
local function write(path, label)
  local tape = getTape()
  if not tape.isReady() then error("磁帶機裡沒有磁帶。") end

  local f = assert(io.open(path, "rb"))
  local size = f:seek("end")
  f:seek("set", 0)

  local capacity = tape.getSize()
  if size > capacity then
    f:close()
    error(string.format("檔案 %d 位元組，超過磁帶容量 %d 位元組。", size, capacity))
  end

  label = label or (path:match("([^/]+)$") or path):gsub("%.[^.]*$", "")

  tape.stop()
  tape.seek(-tape.getSize())        -- 倒回開頭
  tape.setLabel(label)

  local total = 0
  while true do
    local chunk = f:read(CHUNK)
    if not chunk then break end
    tape.write(chunk)               -- 傳字串會連續寫入並自動往後移
    total = total + #chunk
  end
  f:close()

  local lens = loadLens()
  lens[label] = total
  saveLens(lens)
  print(string.format("已寫入「%s」：%d 位元組，長度已記錄到 %s", label, total, LENS_PATH))

  tape.seek(-tape.getSize())
  tape.play()
end

--------------------------------------------------------------------------------
-- 循環播放
--------------------------------------------------------------------------------
local function play()
  local tape = getTape()
  local lastLabel, LEN, ready = nil, DEFAULT_LEN, false
  print("循環播放中，按 Ctrl+C 結束。")

  while true do
    os.sleep(0.2)
    local ok, isReady = pcall(tape.isReady)
    if not (ok and isReady) then
      ready = false                 -- 沒有磁帶，下次放進去就視為新的
    else
      local label = tape.getLabel()
      if not ready or label ~= lastLabel then
        -- 剛放進磁帶，或名字變了：重新查長度並從頭播
        ready, lastLabel = true, label
        LEN = loadLens()[label] or DEFAULT_LEN
        tape.seek(-tape.getSize())
        tape.play()
      elseif tape.getPosition() >= LEN - TAIL then
        tape.seek(-tape.getPosition())  -- 播到尾巴就在播放中跳回
      end
    end
  end
end

--------------------------------------------------------------------------------
local args = { ... }
local cmd = args[1]
if cmd == "write" and args[2] then
  write(args[2], args[3])
elseif cmd == "play" then
  play()
else
  print("用法：")
  print("  tape write <檔案.dfpwm> [標籤]")
  print("  tape play")
end
