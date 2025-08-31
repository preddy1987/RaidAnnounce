-- RaidAnnounce.lua — Classic Era
-- Make sure your .toc has:  ## SavedVariables: MyRaidData
local ADDON = "RaidAnnounce"

----------------------------------------------------------------
-- SavedVariables (guarded; never wipe user's data on load)
----------------------------------------------------------------
MyRaidData = MyRaidData or {
  groups = {},  -- optional
  buffs = { pally = { might_wisdom = "", kings = "", light = "", salv_sanct = "" } },
  debuffs = { recklessness = "", elements = "", shadows = "", demo_shout = "", thunderclap = "" },
  priests = { fort = {}, shadow = {} },
  mages   = { ai = {} },
  kicks = {}, tranq = {}, fear_ward = {},
  heals = {},
  tanks = {}, -- preferred array: [1]=MT,[2]=OT1,...
}

----------------------------------------------------------------
-- Utils
----------------------------------------------------------------
-- forward declarations so helpers defined earlier can call these
local postLines
local burst


local function trim(s) return (s and s:gsub("%s+", " "):gsub("^%s*", ""):gsub("%s*$","")) or "" end

local function sanitizeChat(s)
  if not s or s == "" then return "" end
  -- Escape WoW’s pipe codes and strip newlines
  s = s:gsub("|", "||")
  s = s:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " ")
  return s
end

-- Map position to an RT icon: 1->8, 2->7, ..., 8->1
local function raidIconTag(pos)
  local idx = 9 - (tonumber(pos) or 1)
  if idx < 1 then idx = 1 end
  if idx > 8 then idx = 8 end
  return "{rt" .. idx .. "}"
end

local STOP = {
  raid=true, raids=true, tanks=true, tank=true, healers=true, heals=true, dps=true,
  melee=true, ranged=true, everyone=true, all=true, none=true, tbd=true, ["n/a"]=true,
  group=true, groups=true, left=true, right=true, stack=true, spread=true,
  warrior=true, rogue=true, mage=true, priest=true, warlock=true, paladin=true,
  druid=true, hunter=true, shaman=true,
}

-- Accept ASCII letters, any UTF-8 bytes (128–255), space, apostrophe, hyphen.
-- Reject digits/pure labels/garbage.
local function validName(s)
  if type(s) ~= "string" then return false end
  s = trim(s)
  if s == "" then return false end
  if STOP[s:lower()] then return false end
  if s:sub(1,1) == "#" then return false end
  if s:lower() == "cellimage" then return false end
  -- no control chars or digits
  if s:find("[%c%d]") then return false end
  -- only letters (ASCII or UTF-8 bytes), space, apostrophe, hyphen
  if not s:match("^[A-Za-z\128-\255 '%-]+$") then return false end
  return true
end

local function countKeys(t) local n=0; if type(t)~="table" then return 0 end; for _ in pairs(t) do n=n+1 end; return n end
local function cprint(...) DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RaidAnnounce|r: "..table.concat({tostringall(...)}, " ")) end

----------------------------------------------------------------
-- RW condense + sender (define BEFORE postLines)
----------------------------------------------------------------
local CHAT_MAX = 240  -- safe chunk size (<255 cap)

local function stripHeaderMarkers(s)
  -- "— Tanks —" -> "Tanks"
  local x = s:gsub("^%s*[—%-]+%s*(.-)%s*[—%-]+%s*$", "%1")
  x = x:gsub("^%s*[—%-]+%s*", ""):gsub("%s*[—%-]+%s*$", "")
  return x
end

local function condenseForRW(lines)
  if not lines or #lines == 0 then return "" end
  local header, parts = nil, {}
  for i, ln in ipairs(lines) do
    ln = (ln or ""):gsub("%s+", " ")
    if i == 1 and ln:find("—") then
      header = (ln:gsub("^%s*[—%-]+%s*(.-)%s*[—%-]+%s*$", "%1"))
    elseif not ln:match("^%s*$") then
      ln = ln:gsub(":%s*", "=")  -- "G1: Name" -> "G1=Name"
      table.insert(parts, ln)
    end
  end
  local body = table.concat(parts, " • ")   -- <-- no raw pipes anymore
  local msg = header and header ~= "" and (header .. ": " .. body) or body
  return msg
end

local function sendRWCondensedMessage(msg)
  msg = sanitizeChat(msg)                    -- <-- escape pipes/newlines
  if msg == "" then return end
  local canRW = UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
  local target = canRW and "RAID_WARNING" or "RAID"
  local CHAT_MAX = 240
  if #msg <= CHAT_MAX then
    SendChatMessage(msg, target)
  else
    for i = 1, #msg, CHAT_MAX do
      SendChatMessage(msg:sub(i, i + CHAT_MAX - 1), target)
    end
  end
end

-- RW section sequencer: sends each section as its own condensed line with a delay
-- pacing
RW_SECTION_DELAY        = RW_SECTION_DELAY or 3.0     -- delay between sections
HEALASSIGN_LINE_DELAY   = HEALASSIGN_LINE_DELAY or 2.0 -- delay between HealAssign RW lines (two-rows-per-line)


local function sendRWSectionsSequential(sections, delay)
  delay = tonumber(delay) or RW_SECTION_DELAY
  local i = 1
  local function step()
    if i > #sections then return end
    local msg = condenseForRW(sections[i])
    if msg and msg ~= "" then
      sendRWCondensedMessage(msg)   -- already sanitizes & chunks
    end
    i = i + 1
    if i <= #sections then
      if C_Timer and C_Timer.After then
        C_Timer.After(delay, step)
      else
        local f, t = CreateFrame("Frame"), 0
        f:SetScript("OnUpdate", function(self, elapsed)
          t = t + elapsed
          if t >= delay then
            self:SetScript("OnUpdate", nil); self:Hide()
            step()
          end
        end)
        f:Show()
      end
    end
  end
  step()
end

-- Send each section as: RW (condensed) + non-RW (multi-line), then delay, then next

local function sendRWandMultiSequential(sections, delay, nonRWChan)
  delay = tonumber(delay) or RW_SECTION_DELAY
  nonRWChan = nonRWChan or (IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY")
  local i = 1

  local function step()
    if i > #sections then return end
    local sec = sections[i]

    -- RW single-line
    local rwMsg = condenseForRW(sec)
    if rwMsg and rwMsg ~= "" then
      sendRWCondensedMessage(rwMsg)
    end

    -- Non-RW multi-line (runs in parallel; it self-throttles)
    postLines(nonRWChan, sec)

    i = i + 1
    if i <= #sections then
      if C_Timer and C_Timer.After then
        C_Timer.After(delay, step)
      else
        local f, t = CreateFrame("Frame"), 0
        f:SetScript("OnUpdate", function(self, elapsed)
          t = t + elapsed
          if t >= delay then
            self:SetScript("OnUpdate", nil); self:Hide()
            step()
          end
        end)
        f:Show()
      end
    end
  end

  step()
end

-- Send multiple lines to RW/RAID with a per-line delay; call onDone() when finished
local function sendRWLinesMultiline(lines, perLineDelay, onDone)
  if not lines or #lines == 0 then if type(onDone)=="function" then onDone() end return end
  local canRW = UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
  local target = canRW and "RAID_WARNING" or "RAID"
  local delay = tonumber(perLineDelay) or 0.33

  local i, f, t = 1, CreateFrame("Frame"), 0
  f:SetScript("OnUpdate", function(self, elapsed)
    t = t + elapsed
    if t >= delay then
      t = 0
      local msg = lines[i] and sanitizeChat(lines[i]) or nil
      if not msg then
        self:SetScript("OnUpdate", nil); self:Hide()
        if type(onDone)=="function" then onDone() end
        return
      end
      SendChatMessage(msg, target)
      i = i + 1
    end
  end)
  f:Show()
end

local function sendRWSectionsSequential(sections, delay)
  delay = tonumber(delay) or RW_SECTION_DELAY
  local i = 1

  local function schedule_next()
    if i > #sections then return end
    local function next_step()
      if C_Timer and C_Timer.After then
        C_Timer.After(delay, step)
      else
        local f, t = CreateFrame("Frame"), 0
        f:SetScript("OnUpdate", function(self, e)
          t = t + e; if t >= delay then self:SetScript("OnUpdate", nil); self:Hide(); step() end
        end)
        f:Show()
      end
    end
    next_step()
  end

  function step()
    if i > #sections then return end
    local sec = sections[i]
    i = i + 1

    if sec and sec[1] and sec[1]:find("Healer Assignments") then
      -- Wait for all HealAssign RW lines to finish, then delay to next section
      sendRWLinesMultiline(pairHealAssignContent(sec), HEALASSIGN_LINE_DELAY, schedule_next)
    else
      sendRWCondensedMessage(condenseForRW(sec))
      schedule_next()
    end
  end

  step()
end

local function sendRWandMultiSequential(sections, delay, nonRWChan)
  delay = tonumber(delay) or RW_SECTION_DELAY
  nonRWChan = nonRWChan or (IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY")
  local i = 1

  local function schedule_next()
    if i > #sections then return end
    local function next_step()
      if C_Timer and C_Timer.After then
        C_Timer.After(delay, step)
      else
        local f, t = CreateFrame("Frame"), 0
        f:SetScript("OnUpdate", function(self, e)
          t = t + e; if t >= delay then self:SetScript("OnUpdate", nil); self:Hide(); step() end
        end)
        f:Show()
      end
    end
    next_step()
  end

  function step()
    if i > #sections then return end
    local sec = sections[i]
    i = i + 1

    -- RW side
    if sec and sec[1] and sec[1]:find("Healer Assignments") then
      sendRWLinesMultiline(pairHealAssignContent(sec), HEALASSIGN_LINE_DELAY, schedule_next)
    else
      sendRWCondensedMessage(condenseForRW(sec))
      schedule_next()
    end

    -- Non-RW side in parallel (we don't wait on this)
    postLines(nonRWChan, sec)
  end

  step()
end





----------------------------------------------------------------
-- postLines (RW = single-line; others = multi-line throttle)
----------------------------------------------------------------
postLines = function(chan, lines)
  chan = chan or (IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY")

  if chan == "RW" or chan == "RAID_WARNING" then
    local msg = condenseForRW(lines)
    sendRWCondensedMessage(msg)
    return
  end

  local i, f = 1, CreateFrame("Frame")
  f:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t >= 0.33 then
      self.t = 0
      local msg = sanitizeChat(lines[i])  -- keep the pipe/newline sanitizer
      if not msg then self:SetScript("OnUpdate", nil); self:Hide(); return end
      SendChatMessage(msg, chan)
      i = i + 1
    end
  end)
  f:Show()
end

-- Back-compat alias if anything else calls 'burst'
burst = postLines

----------------------------------------------------------------
-- Normalizers
----------------------------------------------------------------
-- tanks can be {MT="..", OT={...}} or { [1]="MT", [2]="OT1", ... }
local function tanksToArray(t)
  local out = {}
  if type(t) ~= "table" then return out end

  if t.MT or t.OT then
    if validName(t.MT) then table.insert(out, t.MT) end
    if type(t.OT) == "table" then
      local tmp = {}
      for k,v in pairs(t.OT) do
        local idx = (type(k)=="number" and k) or tonumber(tostring(k):match("(%d+)"))
        if idx and validName(v) then tmp[idx]=v end
      end
      local i=1; while tmp[i] do table.insert(out,tmp[i]); i=i+1 end
      local keys={}; for k,_ in pairs(tmp) do if k>=i then table.insert(keys,k) end end
      table.sort(keys); for _,k in ipairs(keys) do table.insert(out,tmp[k]) end
    end
    return out
  end

  local tmp = {}
  for k,v in pairs(t) do
    local idx = (type(k)=="number" and k) or tonumber(tostring(k):match("^(%d+)$"))
    if idx and validName(v) then tmp[idx]=v end
  end
  local i=1; while tmp[i] do table.insert(out,tmp[i]); i=i+1 end
  if #out==0 then local keys={}; for k,_ in pairs(tmp) do table.insert(keys,k) end; table.sort(keys); for _,k in ipairs(keys) do table.insert(out,tmp[k]) end end
  return out
end

local function numMap(tbl)
  local out = {}
  if type(tbl)~="table" then return out end
  for k,v in pairs(tbl) do
    local idx = (type(k)=="number" and k) or tonumber(tostring(k):match("(%d+)"))
    if idx and validName(v) then out[idx]=v end
  end
  return out
end

local function arr5(tbl)
  local out = {}; if type(tbl)~="table" then return out end
  for i=1,5 do
    local v = tbl[i] or tbl[tostring(i)]
    if validName(v) then out[i]=v end
  end
  return out
end

----------------------------------------------------------------
-- Line builders
----------------------------------------------------------------
local function buildTanksLines()
  local arr = tanksToArray(MyRaidData and MyRaidData.tanks)
  local lines = { "— Tanks —" }
  if #arr == 0 then table.insert(lines, "(no tank data)"); return lines end

  -- MT
  if validName(arr[1]) then
    table.insert(lines, ("MT: %s %s"):format(raidIconTag(1), arr[1]))
  end
  -- OTs
  for i = 2, #arr do
    local name = arr[i]
    if validName(name) then
      table.insert(lines, ("OT%d: %s %s"):format(i-1, raidIconTag(i), name))
    end
  end
  return lines
end

-- Label + icon for tank position: 1=MT, 2=OT1, ...
local function tankPosLabel(i) return (i == 1) and "MT" or ("OT" .. (i-1)) end

local function buildHealAssignLines()
  local rows = MyRaidData and MyRaidData.heal_assign or {}
  local lines = { "— Healer Assignments —" }
  local any
  if type(rows) == "table" then
    for i = 1, #rows do
      local r = rows[i]
      if type(r) == "table" then
        local tank  = r[1] and trim(r[1]) or ""
        local h1    = r[2] and trim(r[2]) or ""
        local h2    = r[3] and trim(r[3]) or ""
        if validName(tank) then
          local label = ("%s: %s %s"):format(tankPosLabel(i), raidIconTag(i), tank)
          local heals = trim(table.concat({h1, h2}, ", "):gsub("^, %s*", ""):gsub(", %s*$",""))
          if heals ~= "" then
            table.insert(lines, label .. " — " .. heals)
          else
            table.insert(lines, label)
          end
          any = true
        end
      end
    end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end

-- Pair up two assignment rows per output line (skip header)
local function pairHealAssignContent(lines)
  local out = {}
  if not lines or #lines == 0 then return out end
  -- keep header on its own line
  table.insert(out, lines[1])
  local i = 2
  while i <= #lines do
    local a = lines[i] or ""
    local b = lines[i+1] or ""
    if b ~= "" then
      table.insert(out, a .. "   ||   " .. b)
      i = i + 2
    else
      table.insert(out, a)
      i = i + 1
    end
  end
  return out
end


local function buildGroupMapLines(header, map)
  local m = numMap(map)
  local lines = { "— "..header.." —" }
  local any
  for g=1,8 do
    if validName(m[g]) then table.insert(lines, ("G%d: %s"):format(g, m[g])); any=true end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end

local function buildHealsLines()
  local m = numMap(MyRaidData and MyRaidData.heals)
  local lines = { "— Healers —" }
  local any
  for g=1,8 do
    local v = m[g]
    if type(v)=="table" then v = table.concat(v, ", ") end
    v = trim(v)
    if validName(v) then table.insert(lines, ("G%d: %s"):format(g, v)); any=true end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end

local function buildKicksLines()
  local k = arr5(MyRaidData and MyRaidData.kicks)
  local lines = { "— Kicks —" }
  local labels = { "1st", "2nd", "3rd", "4th", "5th" }
  local any
  for i = 1, 5 do
    local name = k[i]
    if validName(name) then
      table.insert(lines, ("%s: %s %s"):format(labels[i], raidIconTag(i), name))
      any = true
    end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end


local function buildTranqLines()
  local t = MyRaidData and MyRaidData.tranq or {}
  local lines = { "— Tranq —" }
  local any
  if type(t)=="table" then
    for i=1,#t do if validName(t[i]) then table.insert(lines, ("%d: %s"):format(i,t[i])); any=true end end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end

local function buildFearWardLines()
  local fw = MyRaidData and MyRaidData.fear_ward or {}
  local lines = { "— Fear Ward —" }
  local any
  if type(fw)=="table" then
    for i=1,#fw do if validName(fw[i]) then table.insert(lines, ("%d: %s"):format(i,fw[i])); any=true end end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end

local function buildGroupsLines()
  local g = MyRaidData and MyRaidData.groups or {}
  local lines = { "— Groups —" }
  local any
  for i=1,8 do
    if type(g[i])=="table" and #g[i]>0 then
      table.insert(lines, ("G%d: %s"):format(i, table.concat(g[i], ", "))); any=true
    end
  end
  if not any then table.insert(lines, "(no data)") end
  return lines
end

----------------------------------------------------------------
-- Importer UI: /raidimport  (paste `MyRaidData = {...}` or `return {...}`)
----------------------------------------------------------------
local Import = {}

local function parsePasted(text)
  if not text or text:match("^%s*$") then return nil, "empty paste" end
  local s = text:match("^%s*(.-)%s*$")
  s = s:gsub("^MyRaidData%s*=%s*", "")
  if not s:match("^return") then s = "return "..s end
  local f, err = loadstring(s, "RA_Import"); if not f then return nil, err end
  if setfenv then setfenv(f, {}) end -- sandbox
  local ok, tbl = pcall(f); if not ok then return nil, tbl end
  if type(tbl)~="table" then return nil, "did not return a table" end
  return tbl
end

local function applyImport(text, doReload)
  local tbl, err = parsePasted(text)
  if not tbl then cprint("|cffff5555Import failed|r:", err) return end
  MyRaidData = tbl
  cprint(("imported: tanks=%d, kicks=%d, tranq=%d, fw=%d, heals=%d, ai=%d, fort=%d, sp=%d"):
    format(#(tbl.tanks or {}), countKeys(tbl.kicks), #(tbl.tranq or {}), #(tbl.fear_ward or {}),
           countKeys(tbl.heals), countKeys(tbl.mages and tbl.mages.ai or {}),
           countKeys(tbl.priests and tbl.priests.fort or {}),
           countKeys(tbl.priests and tbl.priests.shadow or {})))
  if doReload then ReloadUI() end
end

local function ensureImportUI()
  if Import.frame then return end
  local f = CreateFrame("Frame", "RaidAnnounceImportFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(720, 420); f:SetPoint("CENTER"); f:Hide()
  f.TitleText:SetText("RaidAnnounce — Import Data")
  local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -32); sf:SetPoint("BOTTOMRIGHT", -30, 46)
  local eb = CreateFrame("EditBox", "RaidAnnounceImportEdit", sf)
  eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal); eb:SetWidth(670); eb:SetAutoFocus(true)
  eb:SetText("Paste data here (either `MyRaidData = { ... }` or `return { ... }`).")
  sf:SetScrollChild(eb)
  local btnApply = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnApply:SetSize(160, 24); btnApply:SetPoint("BOTTOMLEFT", 12, 12)
  btnApply:SetText("Apply (no reload)"); btnApply:SetScript("OnClick", function() applyImport(eb:GetText(), false) end)
  local btnSave = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnSave:SetSize(140, 24); btnSave:SetPoint("LEFT", btnApply, "RIGHT", 10, 0)
  btnSave:SetText("Save & Reload"); btnSave:SetScript("OnClick", function() applyImport(eb:GetText(), true) end)
  local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnClose:SetSize(100, 24); btnClose:SetPoint("BOTTOMRIGHT", -12, 12)
  btnClose:SetText("Close"); btnClose:SetScript("OnClick", function() f:Hide() end)
  Import.frame, Import.edit = f, eb
end

local function openImport(prefill)
  ensureImportUI(); Import.frame:Show(); Import.edit:SetText(prefill or ""); Import.edit:SetFocus(); Import.edit:HighlightText()
end

SLASH_RAIMPORT1, SLASH_RAIMPORT2 = "/raidimport", "/raimport"
SlashCmdList.RAIMPORT = function(msg) openImport() end

----------------------------------------------------------------
-- Announce command: /raidannounce <what> [chan]
-- <what>: tanks | ai | fort | sp | heals | kicks | tranq | fear | groups | all
-- [chan]: say | party | raid | rw
----------------------------------------------------------------
local function resolveChan(tok)
  if not tok or tok == "" then return IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY" end
  tok = tok:lower()
  if tok == "say"   then return "SAY" end
  if tok == "party" or tok == "p" then return "PARTY" end
  if tok == "raid"  or tok == "r" then return "RAID" end
  if tok == "rw"    or tok == "raid_warning" then return "RW" end
  if tok == "all"   then return "BOTH" end   -- NEW: special “do both” mode
  return IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY"
end

local function announce(what, chan)
  local L = nil
  if     what=="tanks"  then L = buildTanksLines()
  elseif what=="ai"     then L = buildGroupMapLines("Arcane Intellect", MyRaidData and MyRaidData.mages   and MyRaidData.mages.ai)
  elseif what=="fort"   then L = buildGroupMapLines("Fortitude",        MyRaidData and MyRaidData.priests and MyRaidData.priests.fort)
  elseif what=="sp"     then L = buildGroupMapLines("Shadow Protection",MyRaidData and MyRaidData.priests and MyRaidData.priests.shadow)
  elseif what=="heals"  then L = buildHealsLines()
  elseif what=="kicks"  then L = buildKicksLines()
  elseif what=="tranq"  then L = buildTranqLines()
  elseif what=="fear" or what=="fw" then L = buildFearWardLines()
  elseif what=="groups" then L = buildGroupsLines()
  elseif what == "healassign" or what == "ha" then local L = buildHealAssignLines()
    if chan == "RW" or chan == "RAID_WARNING" then
      -- Special RW behavior: still multi-line, but 2 rows per line for readability
      local paired = pairHealAssignContent(L)
      sendRWLinesMultiline(paired, HEALASSIGN_LINE_DELAY)
    else
      postLines(chan, L)
    end
    return
  elseif what == "all" then
    -- Build sections once
      local sections = {
        buildTanksLines(),
        buildGroupMapLines("Arcane Intellect", MyRaidData and MyRaidData.mages   and MyRaidData.mages.ai),
        buildGroupMapLines("Fortitude",        MyRaidData and MyRaidData.priests and MyRaidData.priests.fort),
        buildGroupMapLines("Shadow Protection",MyRaidData and MyRaidData.priests and MyRaidData.priests.shadow),
        buildHealsLines(),
        buildHealAssignLines(),   -- <--- NEW
        buildKicksLines(),
        buildTranqLines(),
        buildFearWardLines(),
      }

    if chan == "BOTH" then
      -- NEW: RW condensed + non-RW multi-line, section-by-section with delay
      local nonRW = IsInRaid() and "RAID" or IsInGroup() and "PARTY" or "SAY"
      sendRWandMultiSequential(sections, RW_SECTION_DELAY, nonRW)

    elseif chan == "RW" or chan == "RAID_WARNING" then
      -- Existing behavior for /raidannounce all rw: RW-only, one section per tick
      sendRWSectionsSequential(sections, RW_SECTION_DELAY)

    else
      -- Original multi-line flattening for say/party/raid
      local all = {}
      local function add(t) for _, s in ipairs(t) do table.insert(all, s) end table.insert(all, " ") end
      for _, sec in ipairs(sections) do add(sec) end
      postLines(chan, all)
    end
  return
  else
    cprint("Usage: /raidannounce <tanks|ai|fort|sp|heals|kicks|tranq|fear|groups|all> [say|party|raid|rw]")
    cprint("Importer: /raidimport — paste data (no reload needed).")
    return
  end
  postLines(chan, L)
end

SLASH_RAIDANNOUNCE1 = "/raidannounce"
SlashCmdList.RAIDANNOUNCE = function(msg)
  msg = trim(msg or "")
  if msg=="" or msg=="help" then
    cprint("Commands: tanks, ai, fort, sp, heals, kicks, tranq, fear, groups, all  —  e.g. /raidannounce tanks rw")
    cprint("Importer: /raidimport — paste data (no reload needed).")
    return
  end
  local what, chanTok = msg:match("^(%S+)%s*(.*)$")
  announce(what:lower(), resolveChan(chanTok))
end

----------------------------------------------------------------
-- Load banner
----------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_,_,name)
  if name==(ADDON or "RaidAnnounce") then
    cprint(("loaded; tanks=%d, kicks=%d, heals=%d, ai=%d, fort=%d, sp=%d"):
      format(#(MyRaidData.tanks or {}), countKeys(MyRaidData.kicks), countKeys(MyRaidData.heals),
             countKeys(MyRaidData.mages and MyRaidData.mages.ai or {}),
             countKeys(MyRaidData.priests and MyRaidData.priests.fort or {}),
             countKeys(MyRaidData.priests and MyRaidData.priests.shadow or {})))
  end
end)
