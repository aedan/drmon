-- drmon installation script  v5.1

local libURL     = "https://raw.githubusercontent.com/aedan/drmon/master/lib/f.lua"
local reactorURL = "https://raw.githubusercontent.com/aedan/drmon/master/drmon.lua"
local batURL     = "https://raw.githubusercontent.com/aedan/drmon/master/bat.lua"

local lib, reactor, bat, libFile, reactorFile, batFile
local selected, monType, flowIn, flowOut, rSide, monitor, first, second
local pylonName = ""    -- energy pylon for battery-linked control (optional)
local version   = "5.1"

fs.makeDir("lib")

lib = http.get(libURL)
libFile = lib.readAll()
local file1 = fs.open("lib/f", "w")
file1.write(libFile)
file1.close()

reactor = http.get(reactorURL)
reactorFile = reactor.readAll()
local file2 = fs.open("drmon", "w")
file2.write(reactorFile)
file2.close()

bat = http.get(batURL)
batFile = bat.readAll()
local file3 = fs.open("bat", "w")
file3.write(batFile)
file3.close()

selected = 1

function save_config()
    local sw = fs.open("config.txt", "w")
    sw.writeLine(version)
    sw.writeLine(monType     or "reactor")
    sw.writeLine(rSide       or "back")
    sw.writeLine(flowIn      or "")
    sw.writeLine(flowOut     or "")
    sw.writeLine(monitor     or "")
    sw.writeLine("0")          -- oFlow
    sw.writeLine("900000")     -- iFlow
    sw.writeLine("1")          -- autoInputGate
    -- Battery-linked control (v5.1+)
    sw.writeLine("0")                  -- batteryMode  (OFF by default; toggle on monitor)
    sw.writeLine("95")                 -- batteryHighPct
    sw.writeLine("25")                 -- batteryLowPct
    sw.writeLine(pylonName   or "")    -- batteryPylonName
    sw.close()
end

function load_config()
    local sr = fs.open("config.txt", "r")
    version  = sr.readLine()
    monType  = sr.readLine()
    sr.close()
end

local function bwOc(c, bw)
    return term.isColor() and c or bw
end

-- ── Auto-detect peripherals ───────────────────────────────────────────────────
function detect()
    first = ""; second = ""
    local p = peripheral.getNames()
    if #p == 0 then
        term.clear()
        term.write("No devices detected")
        error("No peripherals found")
    end
    for i = 1, #p do
        if string.find(p[i], "monitor") then
            monitor = p[i]
        end
        if string.find(p[i], "flux") then
            if string.find(first, "flux") then
                second = p[i]
            else
                first = p[i]
            end
        end
        -- Detect reactor side (built-in adjacency)
        if p[i] == "back" or p[i] == "left" or p[i] == "right"
           or p[i] == "up" or p[i] == "down" or p[i] == "front" then
            local subp = peripheral.getMethods(p[i])
            if subp and #subp > 0 then
                for a = 1, #subp do
                    if string.find(subp[a], "Reactor") then
                        rSide = p[i]
                    end
                end
            end
        end
    end
end

-- ── Menus ─────────────────────────────────────────────────────────────────────
local function typeMenu()
    local width, height = term.getSize()
    local cx, cy = math.floor(width / 2), math.floor(height / 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(bwOc(colors.red, colors.white))
    term.clear()
    term.setCursorPos(cx - 6, cy - 3)
    term.write("Initial Setup")
    term.setCursorPos(1, cy - 1)
    term.write("What monitor are you configuring?")

    term.setCursorPos(3, cy + 1)
    if selected == 1 then
        term.setTextColor(bwOc(colors.blue, colors.black))
        term.setBackgroundColor(bwOc(colors.lightGray, colors.white))
    else
        term.setTextColor(bwOc(colors.lightBlue, colors.white))
        term.setBackgroundColor(colors.black)
    end
    term.write("Reactor")

    term.setCursorPos(3, cy + 3)
    if selected == 2 then
        term.setTextColor(bwOc(colors.blue, colors.black))
        term.setBackgroundColor(bwOc(colors.lightGray, colors.white))
    else
        term.setTextColor(bwOc(colors.lightBlue, colors.white))
        term.setBackgroundColor(colors.black)
    end
    term.write("Battery")
end

local function flowMenu()
    local width, height = term.getSize()
    local cx, cy = math.floor(width / 2), math.floor(height / 2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(bwOc(colors.red, colors.white))
    term.clear()
    term.setCursorPos(cx - 6, cy - 3)
    term.write("Initial Setup")
    term.setCursorPos(1, cy - 1)
    term.write("Which flux gate is the INPUT gate (energy injector)?")

    term.setCursorPos(3, cy + 1)
    if selected == 1 then
        term.setTextColor(bwOc(colors.blue, colors.black))
        term.setBackgroundColor(bwOc(colors.lightGray, colors.white))
    else
        term.setTextColor(bwOc(colors.lightBlue, colors.white))
        term.setBackgroundColor(colors.black)
    end
    term.write(first)

    term.setCursorPos(3, cy + 3)
    if selected == 2 then
        term.setTextColor(bwOc(colors.blue, colors.black))
        term.setBackgroundColor(bwOc(colors.lightGray, colors.white))
    else
        term.setTextColor(bwOc(colors.lightBlue, colors.white))
        term.setBackgroundColor(colors.black)
    end
    term.write(second)
end

-- Battery pylon setup step (text-input; press Enter to skip)
local function pylonMenu()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(bwOc(colors.yellow, colors.white))
    term.write("Battery-Linked Reactor Control  (optional)")
    term.setTextColor(colors.white)
    term.setCursorPos(1, 3)
    term.write("If you have an energy core/pylon on the modem network,")
    term.setCursorPos(1, 4)
    term.write("the reactor can auto-stop when it fills and restart when")
    term.setCursorPos(1, 5)
    term.write("it drains -- conserving fuel automatically.")
    term.setCursorPos(1, 7)
    term.write("Detected peripherals:")
    local names = peripheral.getNames()
    local row = 8
    for _, name in ipairs(names) do
        -- Highlight likely pylon candidates
        local isLikely = string.find(name, "draconic") or string.find(name, "pylon")
                      or string.find(name, "storage")  or string.find(name, "rf")
        term.setTextColor(isLikely and bwOc(colors.lime, colors.white) or colors.gray)
        term.setCursorPos(3, row)
        term.write(name)
        row = row + 1
        if row > 16 then break end   -- don't overflow screen
    end
    term.setTextColor(colors.white)
    term.setCursorPos(1, row + 1)
    term.write("Enter pylon peripheral name (blank = skip):")
    term.setCursorPos(1, row + 2)
    local input = read()
    pylonName = (input and input ~= "") and input or ""
    if pylonName ~= "" then
        term.setCursorPos(1, row + 3)
        term.setTextColor(bwOc(colors.lime, colors.white))
        term.write("Pylon set to: " .. pylonName)
        term.setCursorPos(1, row + 4)
        term.setTextColor(colors.gray)
        term.write("Toggle battery control ON via the reactor monitor.")
        sleep(2)
    else
        term.setCursorPos(1, row + 3)
        term.setTextColor(colors.gray)
        term.write("Skipped. Re-run install.lua to configure later.")
        sleep(1.5)
    end
end

local function runMenu()
    typeMenu()
    while true do
        local event = { os.pullEvent() }
        if event[1] == "key" then
            local key = event[2]
            if key == keys.up or key == keys.w then
                selected = selected - 1
                if selected == 0 then selected = 2 end
                typeMenu()
            elseif key == keys.down or key == keys.s then
                selected = selected % 2 + 1
                typeMenu()
            elseif key == keys.enter or key == keys.space then
                break
            end
        end
    end

    if selected == 2 then
        monType = "bat"
    else
        monType = "reactor"
    end

    if monType == "reactor" then
        -- Flux gate selection
        selected = 1
        flowMenu()
        while true do
            local event = { os.pullEvent() }
            if event[1] == "key" then
                local key = event[2]
                if key == keys.up or key == keys.w then
                    selected = selected - 1
                    if selected == 0 then selected = 2 end
                    flowMenu()
                elseif key == keys.down or key == keys.s then
                    selected = selected % 2 + 1
                    flowMenu()
                elseif key == keys.enter or key == keys.space then
                    break
                end
            end
        end
        if selected == 2 then
            flowIn  = second
            flowOut = first
        else
            flowIn  = first
            flowOut = second
        end

        -- Battery pylon setup (optional)
        pylonMenu()
    end
end

-- ── Entry ─────────────────────────────────────────────────────────────────────
if fs.exists("config.txt") == false then
    detect()
    runMenu()
    save_config()
else
    load_config()
    if version ~= "5.1" then
        version = "5.1"
        detect()
        runMenu()
        save_config()
    end
end

require(monType)
