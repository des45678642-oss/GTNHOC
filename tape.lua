--------------------------------------------------------------------------------
-- tape.lua —— 磁帶機：多首歌寫入 + 點唱機 UI
--
-- 用法：
--   tape write <檔案.dfpwm> [--name=曲名] [--label=磁帶名] [--new]
--       把一首歌接在磁帶最後面（--new 表示清掉索引，從頭開始寫）
--   tape play
--       開啟點唱機介面
--
-- 每捲磁帶的歌曲索引（曲名、起點、長度）記錄在 INDEX_PATH，以磁帶標籤為鍵，
-- 所以不同的磁帶請用不同的標籤。
--------------------------------------------------------------------------------

local component     = require("component")
local event         = require("event")
local keyboard      = require("keyboard")
local serialization = require("serialization")
local shell         = require("shell")
local term          = require("term")
local unicode       = require("unicode")

local INDEX_PATH    = "/etc/tape_index.cfg"
local BYTES_PER_SEC = 4096          -- 983040 位元組 = 4 分鐘
local CHUNK         = 8192
local TAIL          = 2048          -- 距離歌曲結尾這麼多位元組就換下一首

--------------------------------------------------------------------------------
-- 共用
--------------------------------------------------------------------------------
local function getTape()
  if not component.isAvailable("tape_drive") then
    error("沒偵測到磁帶機（tape_drive）。")
  end
  return component.tape_drive
end

local function loadIndex()
  local f = io.open(INDEX_PATH, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local t = serialization.unserialize(text)
  return type(t) == "table" and t or {}
end

local function saveIndex(index)
  local f = assert(io.open(INDEX_PATH, "w"))
  f:write(serialization.serialize(index))
  f:close()
end

-- 磁帶的 seek 是相對移動，這裡包成絕對位置
local function absSeek(tape, pos)
  tape.seek(pos - tape.getPosition())
end

local function fmtTime(bytes)
  local s = math.floor(bytes / BYTES_PER_SEC)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

--------------------------------------------------------------------------------
-- 寫入
--------------------------------------------------------------------------------
local function write(path, opts)
  local tape = getTape()
  if not tape.isReady() then error("磁帶機裡沒有磁帶。") end

  local f = assert(io.open(path, "rb"))
  local size = f:seek("end")
  f:seek("set", 0)

  local label = opts.label
  if not label or label == true then
    label = tape.getLabel()
    if not label or label == "" then label = "tape" end
  end

  local index = loadIndex()
  local tracks = (not opts.new and index[label]) or {}
  local last = tracks[#tracks]
  local start = last and (last.start + last.len) or 0

  if start + size > tape.getSize() then
    f:close()
    error(string.format("放不下：還剩 %d 位元組，檔案要 %d 位元組。",
      tape.getSize() - start, size))
  end

  local name = opts.name
  if not name or name == true then
    name = (path:match("([^/]+)$") or path):gsub("%.[^.]*$", "")
  end

  tape.stop()
  tape.setLabel(label)
  absSeek(tape, start)

  local total = 0
  while true do
    local chunk = f:read(CHUNK)
    if not chunk then break end
    tape.write(chunk)               -- 傳字串會連續寫入並自動往後移
    total = total + #chunk
  end
  f:close()

  tracks[#tracks + 1] = { name = name, start = start, len = total }
  index[label] = tracks
  saveIndex(index)

  print(string.format("已寫入「%s」（第 %d 首，%s）到磁帶「%s」，剩餘 %s。",
    name, #tracks, fmtTime(total), label, fmtTime(tape.getSize() - start - total)))
  absSeek(tape, 0)
end

--------------------------------------------------------------------------------
-- 點唱機 UI
--------------------------------------------------------------------------------
local function pad(s, w)
  while unicode.wlen(s) > w do s = unicode.sub(s, 1, -2) end
  return s .. string.rep(" ", w - unicode.wlen(s))
end

local function loadTracks(tape, label)
  local tracks = loadIndex()[label]
  if type(tracks) == "table" and #tracks > 0 then return tracks end
  -- 沒有索引的磁帶：整捲當成一首
  return { { name = (label ~= "" and label or "(未命名)"), start = 0, len = tape.getSize() } }
end

local function play()
  local tape = getTape()
  local gpu = component.gpu

  local MODES = { "循環全部", "單曲循環", "播完即停" }
  local tracks, label = {}, ""
  local cur, sel, scroll = nil, 1, 0
  local mode, state, ready = 1, "stopped", false   -- state: playing / paused / stopped

  local LIST_TOP = 6

  local function playTrack(i)
    cur, sel = i, i
    tape.stop()
    absSeek(tape, tracks[i].start)
    tape.play()
    state = "playing"
  end

  local function advance()
    if mode == 2 then
      playTrack(cur)
    elseif cur < #tracks then
      playTrack(cur + 1)
    elseif mode == 1 then
      playTrack(1)
    else
      tape.stop()
      state, cur = "stopped", nil
    end
  end

  local function reload()
    tracks = loadTracks(tape, label)
    if sel > #tracks then sel = #tracks end
  end

  -- 偵測插拔磁帶、自動換歌
  local function refresh()
    local ok, isReady = pcall(tape.isReady)
    if not (ok and isReady) then
      ready, state, cur, tracks, label = false, "stopped", nil, {}, ""
      return
    end
    local l = tape.getLabel() or ""
    if not ready or l ~= label then
      ready, label = true, l
      reload()
      sel, scroll = 1, 0
      playTrack(1)
    elseif state == "playing" and cur then
      local t = tracks[cur]
      if tape.getPosition() >= t.start + t.len - TAIL then advance() end
    end
  end

  local function put(x, y, text, fg, bg, w)
    gpu.setForeground(fg or 0xFFFFFF)
    gpu.setBackground(bg or 0x000000)
    gpu.set(x, y, pad(text, w))
  end

  local function draw()
    local W, H = gpu.getResolution()
    put(1, 1, " 磁帶點唱機" .. (ready and ("  [" .. label .. "]") or ""), 0x000000, 0x66CCFF, W)

    if not ready then
      put(1, 3, " 請放入磁帶…", 0xFFFF66, 0x000000, W)
      for y = 4, H - 1 do put(1, y, "", 0xFFFFFF, 0x000000, W) end
    else
      local t = cur and tracks[cur]
      local icon = state == "playing" and "> " or (state == "paused" and "|| " or "[] ")
      put(1, 2, " " .. icon .. (t and t.name or "(停止)"), 0x66FF66, 0x000000, W)

      local pos, len = 0, t and t.len or 1
      if t then pos = math.max(0, math.min(len, tape.getPosition() - t.start)) end
      local barW = math.max(10, W - 18)
      local filled = math.floor(pos / len * barW)
      put(1, 3, " [" .. string.rep("=", filled) .. string.rep("-", barW - filled) .. "] "
        .. fmtTime(pos) .. "/" .. fmtTime(len), 0xFFFFFF, 0x000000, W)

      put(1, 4, " 模式：" .. MODES[mode], 0xAAAAAA, 0x000000, W)
      put(1, 5, string.rep("-", W), 0x555555, 0x000000, W)

      local listH = H - LIST_TOP - 1
      if sel <= scroll then scroll = sel - 1 end
      if sel > scroll + listH then scroll = sel - listH end
      for row = 1, listH do
        local i = scroll + row
        local y = LIST_TOP + row - 1
        local tr = tracks[i]
        if tr then
          local line = string.format(" %s%2d. %s", i == cur and ">" or " ", i, tr.name)
          local tm = fmtTime(tr.len) .. " "
          local text = pad(line, W - #tm) .. tm
          if i == sel then
            put(1, y, text, 0x000000, 0xFFFFFF, W)
          else
            put(1, y, text, i == cur and 0x66FF66 or 0xFFFFFF, 0x000000, W)
          end
        else
          put(1, y, "", 0xFFFFFF, 0x000000, W)
        end
      end
    end

    put(1, H, " ↑↓選曲 Enter播放 空白暫停 N下首 P上首 ←→快轉 L模式 R重讀 Q離開",
      0x000000, 0x888888, W)
  end

  local function handleKey(code)
    local k = keyboard.keys
    if not ready then return end
    if code == k.up then
      sel = math.max(1, sel - 1)
    elseif code == k.down then
      sel = math.min(#tracks, sel + 1)
    elseif code == k.enter then
      playTrack(sel)
    elseif code == k.space then
      if state == "playing" then
        tape.stop(); state = "paused"
      elseif state == "paused" then
        tape.play(); state = "playing"
      else
        playTrack(sel)
      end
    elseif code == k.n then
      playTrack(((cur or sel) % #tracks) + 1)
    elseif code == k.p then
      playTrack(((cur or sel) - 2) % #tracks + 1)
    elseif code == k.l then
      mode = mode % #MODES + 1
    elseif code == k.r then
      reload()
    elseif (code == k.left or code == k.right) and cur then
      local t = tracks[cur]
      local target = tape.getPosition() + (code == k.right and 1 or -1) * 5 * BYTES_PER_SEC
      target = math.max(t.start, math.min(t.start + t.len - TAIL - 1, target))
      absSeek(tape, target)
    end
  end

  local function loop()
    while true do
      refresh()
      draw()
      local name, _, a, b = event.pull(0.2)
      if name == "key_down" then
        if b == keyboard.keys.q then return end
        handleKey(b)
      elseif name == "touch" and ready then
        local i = scroll + (b - LIST_TOP + 1)
        if b >= LIST_TOP and tracks[i] then playTrack(i) end
      end
    end
  end

  term.clear()
  term.setCursorBlink(false)
  local ok, err = pcall(loop)
  pcall(tape.stop)
  gpu.setForeground(0xFFFFFF)
  gpu.setBackground(0x000000)
  term.clear()
  term.setCursorBlink(true)
  if not ok and not tostring(err):find("interrupted") then error(err, 0) end
end

--------------------------------------------------------------------------------
local args, opts = shell.parse(...)
local cmd = args[1]
if cmd == "write" and args[2] then
  write(args[2], opts)
elseif cmd == "play" then
  play()
else
  print("用法：")
  print("  tape write <檔案.dfpwm> [--name=曲名] [--label=磁帶名] [--new]")
  print("  tape play")
end
