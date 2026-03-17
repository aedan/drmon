-- pocket.lua  |  Draconic Reactor Pocket Remote  v5.0
-- Compatible with drmon v5.0 / CC:Tweaked on 1.20.1
--
-- Changes from v4:
--   FIX  update() had an infinite loop inside it, so the receive coroutine
--        never went back to listening for the next message.  Removed.
--   NEW  Full status table displayed: temperature, field %, fuel %, gen rate
--   NEW  Keyboard shortcuts to send commands to the reactor computer
--         C = charge (startup sequence)
--         A = activate
--         S = stop
--         R = reboot remote computer
--   NEW  Connection-lost indicator when no reply arrives within the poll window

local version = "5.0"

local reactorData = nil       -- last received ri table
local connected   = false     -- did we hear back recently?
local modemName   = "none"

-- ── Modem discovery ───────────────────────────────────────────────────────────
local function findModem()
    for _, name in ipairs(peripheral.getNames()) do
        local methods = peripheral.getMethods(name)
        if methods then
            for _, m in ipairs(methods) do
                if m == "isWireless" then
                    local p = peripheral.wrap(name)
                    if p and p.isWireless() then return name end
                end
            end
        end
    end
    return "none"
end

-- ── Display ───────────────────────────────────────────────────────────────────
local function displayStatus()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    -- Header
    term.setTextColor(colors.cyan)
    term.write("drmon remote  v" .. version)

    if not connected then
        term.setCursorPos(1, 3)
        term.setTextColor(colors.red)
        term.write("-- NO SIGNAL --")
        term.setCursorPos(1, 4)
        term.setTextColor(colors.gray)
        term.write("Polling every 10s...")
        return
    end

    local d = reactorData
    if type(d) ~= "table" then
        term.setCursorPos(1, 3)
        term.setTextColor(colors.red)
        term.write("Bad data received")
        return
    end

    -- Status
    term.setCursorPos(1, 3)
    local statusColor = colors.red
    if     d.status == "running"    then statusColor = colors.green
    elseif d.status == "offline"
        or d.status == "cold"       then statusColor = colors.gray
    elseif d.status == "warming_up"
        or d.status == "charged"    then statusColor = colors.yellow
    elseif d.status == "stopping"   then statusColor = colors.orange
    end
    term.setTextColor(statusColor)
    term.write(string.upper(tostring(d.status or "UNKNOWN")))
    if d.failSafe then
        term.setTextColor(colors.red)
        term.write(" [FS]")
    end

    -- Temperature
    if d.temperature then
        term.setCursorPos(1, 5)
        term.setTextColor(colors.white)
        term.write("Temp:  ")
        local tc = d.temperature > 6500 and colors.red
                or d.temperature > 5000 and colors.orange
                or colors.green
        term.setTextColor(tc)
        term.write(math.floor(d.temperature) .. " C")
    end

    -- Field strength
    if d.fieldStrength and d.maxFieldStrength and d.maxFieldStrength > 0 then
        local fp = math.floor(d.fieldStrength / d.maxFieldStrength * 100)
        term.setCursorPos(1, 6)
        term.setTextColor(colors.white)
        term.write("Field: ")
        local fc = fp >= 50 and colors.green or fp > 30 and colors.orange or colors.red
        term.setTextColor(fc)
        term.write(fp .. "%")
    end

    -- Fuel remaining
    if d.fuelConversion and d.maxFuelConversion and d.maxFuelConversion > 0 then
        local fuel = 100 - math.floor(d.fuelConversion / d.maxFuelConversion * 100)
        term.setCursorPos(1, 7)
        term.setTextColor(colors.white)
        term.write("Fuel:  ")
        local fc = fuel >= 70 and colors.green or fuel > 30 and colors.orange or colors.red
        term.setTextColor(fc)
        term.write(fuel .. "%")
    end

    -- Generation rate
    if d.generationRate then
        term.setCursorPos(1, 8)
        term.setTextColor(colors.white)
        term.write("Gen:   ")
        term.setTextColor(colors.lime)
        term.write(math.floor(d.generationRate) .. " rf/t")
    end

    -- Energy saturation
    if d.energySaturation and d.maxEnergySaturation and d.maxEnergySaturation > 0 then
        local sat = math.floor(d.energySaturation / d.maxEnergySaturation * 100)
        term.setCursorPos(1, 9)
        term.setTextColor(colors.white)
        term.write("Chaos: ")
        term.setTextColor(sat > 90 and colors.red or colors.white)
        term.write(sat .. "%")
    end

    -- Keymap
    term.setCursorPos(1, 11)
    term.setTextColor(colors.gray)
    term.write("[C]harge  [A]ctivate  [S]top")
    term.setCursorPos(1, 12)
    term.write("[R]eboot remote  poll: 10s")
end

-- ── Coroutines ────────────────────────────────────────────────────────────────

-- Periodically broadcasts a "status" request to all drmon computers
local function sender()
    if modemName == "none" then return end
    while true do
        if not rednet.isOpen(modemName) then rednet.open(modemName) end
        rednet.broadcast("status")
        sleep(10)
    end
end

-- Listens for status replies and updates the display
local function receiver()
    if modemName == "none" then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.red)
        term.write("No wireless modem found!")
        return
    end
    while true do
        if not rednet.isOpen(modemName) then rednet.open(modemName) end
        -- Wait up to 15 s; if nothing arrives mark as disconnected
        local _, msg = rednet.receive(15)
        if msg then
            connected   = true
            reactorData = type(msg) == "table" and msg or { status = tostring(msg) }
        else
            connected = false
        end
        displayStatus()
    end
end

-- Handles keyboard commands
local function keyHandler()
    if modemName == "none" then return end
    while true do
        local _, key = os.pullEvent("key")
        if not rednet.isOpen(modemName) then rednet.open(modemName) end
        if     key == keys.c then
            rednet.broadcast("startup")
            term.setCursorPos(1, 14)
            term.setTextColor(colors.yellow)
            term.write(">> Sent: CHARGE/STARTUP")
        elseif key == keys.a then
            rednet.broadcast("startup")
            term.setCursorPos(1, 14)
            term.setTextColor(colors.yellow)
            term.write(">> Sent: ACTIVATE       ")
        elseif key == keys.s then
            rednet.broadcast("shutdown")
            term.setCursorPos(1, 14)
            term.setTextColor(colors.orange)
            term.write(">> Sent: SHUTDOWN       ")
        elseif key == keys.r then
            rednet.broadcast("reboot")
            term.setCursorPos(1, 14)
            term.setTextColor(colors.red)
            term.write(">> Sent: REBOOT         ")
        end
    end
end

-- ── Entry point ───────────────────────────────────────────────────────────────
modemName = findModem()

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.cyan)
term.write("drmon remote  v" .. version)
term.setCursorPos(1, 3)
term.setTextColor(colors.white)
term.write("Searching for reactor...")

parallel.waitForAll(sender, receiver, keyHandler)
