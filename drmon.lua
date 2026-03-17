-- drmon.lua  |  Draconic Reactor Monitor  v5.1
-- Compatible with Draconic Evolution 1.20.1 + CC:Tweaked
--
-- Changes from v4:
--   FIX  Flux gate API: setSignalLowFlow -> setOverrideEnabled + setFlowOverride
--   FIX  Gate display now reads actual flow via getFlow() instead of the set value
--   FIX  Safety: negative gate values clamped to 0
--   FIX  Config version migration on first run after upgrade
--   NEW  Event log written to drmon.log with timestamps
--   NEW  Peripheral auto-reconnect if cable is broken/replaced
--   NEW  Uptime counter displayed on monitor
--   NEW  Total RF generated (accumulated) displayed on monitor
--   NEW  Fuel ETA using ri.fuelConversionRate
--   NEW  Failsafe indicator in status line
--   NEW  CHARGED state handled explicitly (no longer conflated with warming_up)
--   NEW  Config saves throttled to once per 5 s (was every 0.1 s)
--   NEW  Wireless receive uses a timeout so the coroutine doesn't block forever
-- Changes from v5.0:
--   NEW  Battery-linked reactor control (hysteresis mode)
--        Wraps energy pylon directly; stops reactor when storage is full,
--        restarts when it drains to a configured low-water mark.
--        Toggle ON/OFF on monitor; thresholds set via install.lua or config.txt.

-- ── User settings (edit these) ────────────────────────────────────────────────
local targetStrength     = 50      -- desired field strength %
local maxTemperature     = 8000    -- °C: triggers emergency shutdown
local safeTemperature    = 3000    -- °C: safe to restart after cooling
local lowestFieldPercent = 15      -- %: emergency-charge threshold
local activateOnCharged  = 1       -- 1 = auto-activate when fully charged

-- ── Internal state ────────────────────────────────────────────────────────────
local version = "5.1"

local reactorSide, igateName, ogateName, monName, monType
local oFlow, iFlow        = 0, 900000
local mon, monitor, monX, monY, reactor, outflux, influx, ri
local modem
local autoInputGate       = 1
local action              = "None since reboot"
local emergencyCharge     = false
local emergencyTemp       = false
local identify            = false
local startEpoch          = os.epoch("utc")
local lastEpoch           = startEpoch
local totalGenerated      = 0
local lastSaveTime        = 0
local lastStatus          = ""

-- Battery-linked control state
-- batteryHighPct / batteryLowPct / batteryPylonName are persisted in config.txt
local batteryMode        = 0       -- 0 = off, 1 = on
local batteryHighPct     = 95      -- stop reactor when pylon reaches this %
local batteryLowPct      = 25      -- restart reactor when pylon drains to this %
local batteryPylonName   = ""      -- peripheral name of energy pylon (modem-connected)
local batteryPylon       = nil     -- wrapped pylon peripheral
local batteryPct         = 0       -- last-read pylon fill %
local batteryPaused      = false   -- true = WE stopped the reactor for battery reasons

os.loadAPI("lib/f")

-- ── Logging ───────────────────────────────────────────────────────────────────
local function logEvent(msg)
    local fh = fs.open("drmon.log", "a")
    if fh then
        fh.writeLine("[" .. os.date("%H:%M:%S") .. "] " .. msg)
        fh.close()
    end
    action = msg
end

-- ── Safe peripheral call ──────────────────────────────────────────────────────
local function safeCall(fn, ...)
    if fn == nil then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then
        logEvent("peripheral err: " .. tostring(v))
        return nil
    end
    return v
end

-- ── Flux gate helpers (1.20.1 API) ───────────────────────────────────────────
local function setInFlow(val)
    val = math.max(0, math.floor(val or 0))
    iFlow = val
    if influx then safeCall(influx.setFlowOverride, val) end
end

local function setOutFlow(val)
    val = math.max(0, math.floor(val or 0))
    oFlow = val
    if outflux then safeCall(outflux.setFlowOverride, val) end
end

local function getActualInFlow()
    if influx  and influx.getFlow  then return safeCall(influx.getFlow)  or iFlow end
    return iFlow
end

local function getActualOutFlow()
    if outflux and outflux.getFlow then return safeCall(outflux.getFlow) or oFlow end
    return oFlow
end

-- ── Config ────────────────────────────────────────────────────────────────────
local function save_config()
    local sw = fs.open("config.txt", "w")
    sw.writeLine(version)
    sw.writeLine(monType          or "reactor")
    sw.writeLine(reactorSide      or "back")
    sw.writeLine(igateName        or "")
    sw.writeLine(ogateName        or "")
    sw.writeLine(monName          or "")
    sw.writeLine(oFlow)
    sw.writeLine(iFlow)
    sw.writeLine(autoInputGate)
    -- Battery control (v5.1+)
    sw.writeLine(batteryMode)
    sw.writeLine(batteryHighPct)
    sw.writeLine(batteryLowPct)
    sw.writeLine(batteryPylonName or "")
    sw.close()
end

local function load_config()
    local sr = fs.open("config.txt", "r")
    local storedVer      = sr.readLine()
    monType              = sr.readLine()
    reactorSide          = sr.readLine()
    igateName            = sr.readLine()
    ogateName            = sr.readLine()
    monName              = sr.readLine()
    oFlow                = tonumber(sr.readLine()) or 0
    iFlow                = tonumber(sr.readLine()) or 900000
    autoInputGate        = tonumber(sr.readLine()) or 1
    -- Battery control fields (absent in configs saved before v5.1 -> fall back to defaults)
    batteryMode          = tonumber(sr.readLine()) or 0
    batteryHighPct       = tonumber(sr.readLine()) or 95
    batteryLowPct        = tonumber(sr.readLine()) or 25
    batteryPylonName     = sr.readLine()           or ""
    sr.close()
    if storedVer ~= version then
        logEvent("Config migrated " .. tostring(storedVer) .. " -> " .. version)
        save_config()
    end
end

-- ── Peripheral connect / reconnect ────────────────────────────────────────────
local function connectPeripherals()
    monitor     = peripheral.wrap(monName)
    influx      = peripheral.wrap(igateName)
    outflux     = peripheral.wrap(ogateName)
    reactor     = peripheral.wrap(reactorSide)
    batteryPylon = (batteryPylonName ~= "" and peripheral.wrap(batteryPylonName)) or nil

    if influx then
        safeCall(influx.setOverrideEnabled,  true)
        safeCall(influx.setFlowOverride,     iFlow)
    end
    if outflux then
        safeCall(outflux.setOverrideEnabled, true)
        safeCall(outflux.setFlowOverride,    oFlow)
    end
    if monitor then
        monX, monY = monitor.getSize()
        mon = { monitor = monitor, X = monX, Y = monY }
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
    end
end

local function checkPeripherals()
    local changed = false

    if not peripheral.isPresent(reactorSide) then
        reactor = nil
    elseif reactor == nil then
        reactor = peripheral.wrap(reactorSide)
        changed = true
    end

    if not peripheral.isPresent(igateName) then
        influx = nil
    elseif influx == nil then
        influx = peripheral.wrap(igateName)
        safeCall(influx.setOverrideEnabled, true)
        safeCall(influx.setFlowOverride, iFlow)
        changed = true
    end

    if not peripheral.isPresent(ogateName) then
        outflux = nil
    elseif outflux == nil then
        outflux = peripheral.wrap(ogateName)
        safeCall(outflux.setOverrideEnabled, true)
        safeCall(outflux.setFlowOverride, oFlow)
        changed = true
    end

    if not peripheral.isPresent(monName) then
        monitor = nil; mon = nil
    elseif monitor == nil then
        monitor = peripheral.wrap(monName)
        monX, monY = monitor.getSize()
        mon = { monitor = monitor, X = monX, Y = monY }
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        changed = true
    end

    -- Battery pylon (optional; only reconnect when name is configured)
    if batteryPylonName ~= "" then
        if not peripheral.isPresent(batteryPylonName) then
            batteryPylon = nil
        elseif batteryPylon == nil then
            batteryPylon = peripheral.wrap(batteryPylonName)
            changed = true
        end
    end

    if changed then logEvent("Peripheral(s) reconnected.") end
end

-- ── Formatting helpers ────────────────────────────────────────────────────────
local function pad(str, len, char)
    char = char or ' '
    str  = tostring(str)
    return string.rep(char, math.max(0, len - #str)) .. str
end

local function formatUptime(ms)
    local s = math.floor(ms / 1000)
    local m = math.floor(s / 60);  s = s % 60
    local h = math.floor(m / 60);  m = m % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function formatETA(secs)
    if not secs or secs <= 0 then return "    ---" end
    local m = math.floor(secs / 60);    secs = secs % 60
    local h = math.floor(m    / 60);    m    = m    % 60
    if h > 999 then return ">999hrs" end
    if h >   0 then return string.format("%3dh%02dm", h, m) end
    return string.format("  %3dm%02ds", m, math.floor(secs))
end

-- ── Draw +/- step buttons ─────────────────────────────────────────────────────
local function drawButtons(y)
    f.draw_text(mon,  2, y, " < ",  colors.white, colors.gray)
    f.draw_text(mon,  6, y, " <<",  colors.white, colors.gray)
    f.draw_text(mon, 10, y, "<<<",  colors.white, colors.gray)
    f.draw_text(mon, 17, y, ">>>",  colors.white, colors.gray)
    f.draw_text(mon, 21, y, ">> ",  colors.white, colors.gray)
    f.draw_text(mon, 25, y, " > ",  colors.white, colors.gray)
end

-- ── Button-handler coroutine ──────────────────────────────────────────────────
function buttons()
    while true do
        setOutFlow(oFlow)
        if autoInputGate == 0 then setInFlow(iFlow) end

        local _, _, xPos, yPos = os.pullEvent("monitor_touch")

        -- Row 8: Output gate ±1 k / ±10 k / ±100 k
        if yPos == 8 then
            if     xPos >= 2  and xPos <= 4  then oFlow = oFlow - 1000
            elseif xPos >= 6  and xPos <= 9  then oFlow = oFlow - 10000
            elseif xPos >= 10 and xPos <= 12 then oFlow = oFlow - 100000
            elseif xPos >= 17 and xPos <= 19 then oFlow = oFlow + 100000
            elseif xPos >= 21 and xPos <= 23 then oFlow = oFlow + 10000
            elseif xPos >= 25 and xPos <= 27 then oFlow = oFlow + 1000
            end
            oFlow = math.max(0, oFlow)
            setOutFlow(oFlow)
            save_config()
        end

        -- Row 10: Input gate ±1 k / ±10 k / ±100 k  (manual mode only)
        if yPos == 10 and autoInputGate == 0 then
            if     xPos >= 2  and xPos <= 4  then iFlow = iFlow - 1000
            elseif xPos >= 6  and xPos <= 9  then iFlow = iFlow - 10000
            elseif xPos >= 10 and xPos <= 12 then iFlow = iFlow - 100000
            elseif xPos >= 17 and xPos <= 19 then iFlow = iFlow + 100000
            elseif xPos >= 21 and xPos <= 23 then iFlow = iFlow + 10000
            elseif xPos >= 25 and xPos <= 27 then iFlow = iFlow + 1000
            end
            iFlow = math.max(0, iFlow)
            setInFlow(iFlow)
            save_config()
        end

        -- Row 10 cols 14-15: toggle AUTO / MANUAL input gate
        if yPos == 10 and (xPos == 14 or xPos == 15) then
            autoInputGate = autoInputGate == 1 and 0 or 1
            logEvent("Input gate mode -> " .. (autoInputGate == 1 and "AUTO" or "MANUAL"))
            save_config()
        end

        -- Row 22 cols 10-11: toggle battery-linked control ON / OFF
        if yPos == 22 and (xPos == 10 or xPos == 11) then
            if batteryPylonName == "" then
                logEvent("Battery mode needs a pylon - set batteryPylonName in install.lua")
            else
                batteryMode   = batteryMode == 1 and 0 or 1
                batteryPaused = false   -- clear any pending pause on mode change
                logEvent("Battery mode -> " .. (batteryMode == 1 and "ON" or "OFF"))
                save_config()
            end
        end
    end
end

-- ── Main update coroutine ─────────────────────────────────────────────────────
function update()
    while true do
        checkPeripherals()

        term.clear()
        term.setCursorPos(1, 1)

        if reactor == nil then
            print("ERROR: Reactor not found on side: " .. tostring(reactorSide))
            print("Check wiring and rerun install.lua if needed.")
            sleep(2)
        else
            ri = safeCall(reactor.getReactorInfo)

            if ri == nil then
                print("ERROR: getReactorInfo() returned nil.")
                print("Reactor may be incomplete or missing fuel.")
                sleep(2)
            else
                -- Terminal debug dump
                for k, v in pairs(ri) do
                    print(k .. ": " .. (k == "failSafe" and tostring(v) or tostring(v)))
                end
                local actualIn  = getActualInFlow()
                local actualOut = getActualOutFlow()
                print("Output Gate set/actual: " .. oFlow .. " / " .. (actualOut or "?"))
                print("Input  Gate set/actual: " .. iFlow .. " / " .. (actualIn  or "?"))
                print("Battery pct: " .. string.format("%.1f", batteryPct) .. "%  mode: " .. batteryMode)
                print("Last action: " .. tostring(action))

                -- Status change logging
                if ri.status ~= lastStatus then
                    logEvent("Status: " .. tostring(lastStatus) .. " -> " .. tostring(ri.status))
                    lastStatus = ri.status
                end

                -- Accumulate generated RF
                local now = os.epoch("utc")
                if ri.status == "running" and ri.generationRate then
                    local dtTicks = (now - lastEpoch) / 50
                    totalGenerated = totalGenerated + ri.generationRate * dtTicks
                end
                lastEpoch = now

                -- ── Battery pylon reading ──────────────────────────────────
                -- Read energy level regardless of battery mode so the display
                -- is always live when a pylon is connected.
                if batteryPylon ~= nil then
                    local ok1, batMax = pcall(batteryPylon.getMaxEnergyStored)
                    local ok2, batCur = pcall(batteryPylon.getEnergyStored)
                    if ok1 and ok2 and batMax and batCur and batMax > 0 then
                        batteryPct = batCur / batMax * 100
                    end
                end

                -- ── Battery-linked control (hysteresis) ───────────────────
                -- Only acts when: mode is ON, pylon is connected, and no
                -- active safety emergency is in progress.
                if batteryMode == 1 and batteryPylon ~= nil then

                    -- HIGH water mark: battery full → pause reactor
                    if batteryPct >= batteryHighPct
                       and ri.status == "running"
                       and not emergencyCharge
                       and not emergencyTemp then
                        safeCall(reactor.stopReactor)
                        setInFlow(0)
                        batteryPaused = true
                        logEvent(string.format(
                            "Battery %.1f%% >= %d%% - reactor paused",
                            batteryPct, batteryHighPct))
                    end

                    -- LOW water mark: battery drained → restart
                    -- Only fires if WE were the one who paused it; a manual
                    -- or emergency stop will not auto-restart here.
                    if batteryPct <= batteryLowPct
                       and batteryPaused
                       and not emergencyTemp
                       and not emergencyCharge
                       and (ri.status == "offline"
                         or ri.status == "cold"
                         or ri.status == "stopping") then
                        safeCall(reactor.chargeReactor)
                        batteryPaused = false
                        logEvent(string.format(
                            "Battery %.1f%% <= %d%% - restarting reactor",
                            batteryPct, batteryLowPct))
                    end
                end

                -- ── Monitor UI ─────────────────────────────────────────────
                if mon then
                    -- Status line
                    local statusColor = colors.red
                    if     ri.status == "running"    then statusColor = colors.green
                    elseif ri.status == "offline"    then statusColor = colors.gray
                    elseif ri.status == "cold"       then statusColor = colors.gray
                    elseif ri.status == "warming_up" then statusColor = colors.orange
                    elseif ri.status == "charged"    then statusColor = colors.yellow
                    elseif ri.status == "stopping"   then statusColor = colors.orange
                    end
                    local statusLabel = string.upper(ri.status)
                    if ri.failSafe then statusLabel = statusLabel .. " [FS]" end
                    f.draw_text_lr(mon, 2, 2, 1,
                        "Reactor v" .. version,
                        pad(statusLabel, 14, " "),
                        colors.white, statusColor, colors.black)

                    -- Generation rate
                    f.draw_text_lr(mon, 2, 4, 1,
                        "Generation",
                        pad(f.format_int(ri.generationRate), 10, " ") .. " rf/t",
                        colors.white, colors.lime, colors.black)

                    -- Temperature
                    local tempColor = colors.green
                    if     ri.temperature > 6500 then tempColor = colors.red
                    elseif ri.temperature > 5000 then tempColor = colors.orange
                    end
                    f.draw_text_lr(mon, 2, 6, 1,
                        "Temperature",
                        pad(f.format_int(ri.temperature), 13, " ") .. " C",
                        colors.white, tempColor, colors.black)

                    -- Output gate
                    f.draw_text_lr(mon, 2, 7, 1,
                        "Output Gate",
                        pad(f.format_int(actualOut), 10, " ") .. " rf/t",
                        colors.white, colors.blue, colors.black)
                    drawButtons(8)

                    -- Input gate + AUTO/MANUAL badge
                    f.draw_text_lr(mon, 2, 9, 1,
                        "Input Gate",
                        pad(f.format_int(actualIn), 11, " ") .. " rf/t",
                        colors.white, colors.blue, colors.black)
                    if autoInputGate == 1 then
                        f.draw_text(mon, 14, 10, "AU", colors.green, colors.gray)
                    else
                        f.draw_text(mon, 14, 10, "MA", colors.white, colors.gray)
                        drawButtons(10)
                    end

                    -- Energy saturation
                    local satPercent = math.ceil(
                        ri.energySaturation / ri.maxEnergySaturation * 10000) * 0.01
                    f.draw_text_lr(mon, 2, 11, 1,
                        "Energy Sat.",
                        pad(tostring(satPercent), 8, " ") .. "%",
                        colors.white, colors.white, colors.black)
                    f.progress_bar(mon, 2, 12, mon.X - 2,
                        satPercent, 100, colors.blue, colors.gray)

                    -- Field strength
                    local fieldPercent = math.ceil(
                        ri.fieldStrength / ri.maxFieldStrength * 10000) * 0.01
                    local fieldColor = fieldPercent >= 50 and colors.green
                                    or fieldPercent >  30 and colors.orange
                                    or colors.red
                    local fieldLabel = autoInputGate == 1
                        and ("Field T:" .. targetStrength .. "%")
                        or  "Field Strength"
                    f.draw_text_lr(mon, 2, 14, 1,
                        fieldLabel,
                        pad(tostring(fieldPercent), 6, " ") .. "%",
                        colors.white, fieldColor, colors.black)
                    f.progress_bar(mon, 2, 15, mon.X - 2,
                        fieldPercent, 100, fieldColor, colors.gray)

                    -- Fuel + ETA
                    local fuelPercent = 100 - math.ceil(
                        ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01
                    local fuelColor = fuelPercent >= 70 and colors.green
                                   or fuelPercent >  30 and colors.orange
                                   or colors.red
                    local etaStr = "    ---"
                    if ri.fuelConversionRate and ri.fuelConversionRate > 0 then
                        local fuelLeft = ri.maxFuelConversion - ri.fuelConversion
                        local secsLeft = fuelLeft / ri.fuelConversionRate / 20
                        etaStr = formatETA(secsLeft)
                    end
                    f.draw_text_lr(mon, 2, 17, 1,
                        "Fuel  " .. pad(tostring(fuelPercent), 6, " ") .. "%",
                        etaStr,
                        colors.white, fuelColor, colors.black)
                    f.progress_bar(mon, 2, 18, mon.X - 2,
                        fuelPercent, 100, fuelColor, colors.gray)

                    -- Uptime | cumulative RF generated
                    local uptimeMs = os.epoch("utc") - startEpoch
                    f.draw_text_lr(mon, 2, 19, 1,
                        "Up " .. formatUptime(uptimeMs),
                        pad(f.format_compact(totalGenerated), 8, " ") .. " RF",
                        colors.gray, colors.gray, colors.black)

                    -- Last action
                    f.draw_text_lr(mon, 2, 20, 1,
                        "Action",
                        pad(action, 20, " "),
                        colors.gray, colors.gray, colors.black)

                    -- ── Battery section (rows 22-24) ───────────────────────
                    -- Row 22: mode toggle badge + live fill %
                    -- Row 23: threshold labels (Stop@X%  /  Start@Y%)
                    -- Row 24: fill progress bar
                    if batteryPylonName == "" then
                        -- Pylon not configured: show greyed-out placeholder
                        f.draw_text_lr(mon, 2, 22, 1,
                            "Battery",
                            "not configured",
                            colors.gray, colors.gray, colors.black)
                    else
                        local batBadgeColor = batteryMode == 1 and colors.green or colors.gray
                        local batBadgeText  = batteryMode == 1 and "ON" or "OF"
                        local batPctColor   = colors.green
                        if batteryPaused then
                            -- Reactor is paused waiting for drain; tint yellow
                            batPctColor = colors.yellow
                        elseif batteryPct >= batteryHighPct then
                            batPctColor = colors.orange
                        elseif batteryPct <= batteryLowPct then
                            batPctColor = colors.red
                        end

                        f.draw_text(mon, 2, 22, "Battery", colors.white, colors.black)
                        f.draw_text(mon, 10, 22, batBadgeText, colors.white, batBadgeColor)

                        if batteryPylon ~= nil then
                            f.draw_text_right(mon, 1, 22,
                                string.format("%.1f", batteryPct) .. "%",
                                batPctColor, colors.black)
                        else
                            f.draw_text_right(mon, 1, 22, "NO SIGNAL", colors.red, colors.black)
                        end

                        -- Threshold info line
                        local threshLabel = "Stop@" .. batteryHighPct .. "%"
                        local threshRight = "Start@" .. batteryLowPct .. "%"
                        if batteryPaused then threshLabel = threshLabel .. " [PAUSED]" end
                        f.draw_text_lr(mon, 2, 23, 1,
                            threshLabel, threshRight,
                            colors.gray, colors.gray, colors.black)

                        -- Progress bar (orange when paused to signal "waiting")
                        local batBarColor = batPctColor
                        f.progress_bar(mon, 2, 24, mon.X - 2,
                            batteryPct, 100, batBarColor, colors.gray)
                    end
                end

                -- ── Reactor control state machine ──────────────────────────

                if ri.status == "warming_up" then
                    setInFlow(900000)
                    emergencyCharge = false

                elseif ri.status == "charged" then
                    setInFlow(900000)
                    emergencyCharge = false
                    if activateOnCharged == 1 then
                        safeCall(reactor.activateReactor)
                        logEvent("Auto-activated (field charged)")
                    end

                elseif emergencyCharge then
                    safeCall(reactor.chargeReactor)

                elseif emergencyTemp
                   and ri.status == "stopping"
                   and ri.temperature < safeTemperature then
                    safeCall(reactor.activateReactor)
                    logEvent("Reactivated after cool-down")
                    emergencyTemp = false

                elseif ri.status == "running" then
                    if autoInputGate == 1 then
                        local fluxval = ri.fieldDrainRate / (1 - targetStrength / 100)
                        setInFlow(fluxval)
                    else
                        setInFlow(iFlow)
                    end
                    if os.epoch("utc") - lastSaveTime > 5000 then
                        save_config()
                        lastSaveTime = os.epoch("utc")
                    end

                elseif ri.status == "stopping" then
                    if autoInputGate == 1 then setInFlow(0) end
                end

                -- ── Safety checks ──────────────────────────────────────────

                local fuelPct = 100 - math.ceil(
                    ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01

                if fuelPct <= 10 then
                    safeCall(reactor.stopReactor)
                    logEvent("Fuel <= 10% - refuel needed!")
                end

                local fieldPct = math.ceil(
                    ri.fieldStrength / ri.maxFieldStrength * 10000) * 0.01

                if fieldPct <= lowestFieldPercent and ri.status == "running" then
                    safeCall(reactor.stopReactor)
                    safeCall(reactor.chargeReactor)
                    emergencyCharge = true
                    -- Safety trips also clear the battery pause so the safety
                    -- system (not battery logic) handles the restart.
                    batteryPaused = false
                    logEvent("Field < " .. lowestFieldPercent .. "% - emergency charge")
                end

                if ri.temperature > maxTemperature then
                    safeCall(reactor.stopReactor)
                    emergencyTemp = true
                    batteryPaused = false
                    logEvent("Temp > " .. maxTemperature .. " - cooling down")
                end
            end
        end

        sleep(0.1)
    end
end

-- ── Wireless handler coroutine ────────────────────────────────────────────────
function wireless()
    modem = "none"
    for _, name in ipairs(peripheral.getNames()) do
        local methods = peripheral.getMethods(name)
        if methods then
            for _, m in ipairs(methods) do
                if m == "isWireless" then
                    local p = peripheral.wrap(name)
                    if p and p.isWireless() then modem = name end
                end
            end
        end
    end

    if modem ~= "none" then
        while true do
            if not rednet.isOpen(modem) then rednet.open(modem) end
            local id, msg = rednet.receive(10)
            if msg then
                if     msg == "reboot"   then
                    os.reboot()
                elseif msg == "shutdown" then
                    if reactor then safeCall(reactor.stopReactor) end
                    batteryPaused = false
                    logEvent("Remote shutdown received")
                elseif msg == "startup"  then
                    if reactor then
                        safeCall(reactor.chargeReactor)
                        safeCall(reactor.activateReactor)
                    end
                    batteryPaused = false
                    logEvent("Remote startup received")
                elseif msg == "checkin"  then
                    rednet.send(id, "hello v" .. version)
                elseif msg == "status"   then
                    rednet.send(id, ri or { status = "unknown" })
                elseif msg == "identify" then
                    if identify then
                        if monitor then
                            monitor.setBackgroundColor(colors.black)
                            monitor.clear()
                        end
                        identify = false
                    else
                        if monitor then
                            monitor.setBackgroundColor(colors.lightBlue)
                            monitor.clear()
                        end
                        identify = true
                    end
                end
            end
        end
    end
end

-- ── Entry point ───────────────────────────────────────────────────────────────
if not pcall(load_config) then
    save_config()
    logEvent("No config found; created defaults.")
end

logEvent("drmon v" .. version .. " starting.")
connectPeripherals()
parallel.waitForAll(update, buttons, wireless)
