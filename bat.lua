-- bat.lua  |  Draconic Energy Core Monitor  v5.0
-- Compatible with Draconic Evolution 1.20.1 + CC:Tweaked
--
-- Changes from v4:
--   FIX  getTransferPerTick() removed – unreliable in 1.20.1.
--        Net transfer rate is now derived from the energy delta between polls.
--   NEW  Percentage-full display
--   NEW  Colour-coded progress bar (green > 75%, orange > 25%, red below)
--   NEW  Net rate shown with + / - sign so charge vs drain is clear
--   NEW  Error handling if pylon peripheral is missing

local pylonSide    = "back"
local monitorSide  = "left"

-- Rolling-average window size (number of 1-second samples to smooth the rate)
local RATE_WINDOW  = 5

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function format_int(n)
    if n == nil then n = 0 end
    local i, j, minus, int, fraction = tostring(n):find('([-]?)(%d+)([.]?%d*)')
    int = int:reverse():gsub("(%d%d%d)", "%1,")
    return minus .. int:reverse():gsub("^,", "") .. fraction
end

local function format_compact(n)
    if n == nil then n = 0 end
    local neg = n < 0 and "-" or ""
    n = math.abs(n)
    if     n >= 1e12 then return neg .. string.format("%.2fT", n / 1e12)
    elseif n >= 1e9  then return neg .. string.format("%.2fG", n / 1e9)
    elseif n >= 1e6  then return neg .. string.format("%.2fM", n / 1e6)
    elseif n >= 1e3  then return neg .. string.format("%.1fK", n / 1e3)
    else                  return neg .. tostring(math.floor(n))
    end
end

local function draw_progress_bar(mon, x, y, length, pct, barColor, bgColor)
    local filled = math.max(0, math.min(length, math.floor(pct / 100 * length)))
    mon.setBackgroundColor(bgColor)
    mon.setCursorPos(x, y)
    mon.write(string.rep(" ", length))
    if filled > 0 then
        mon.setBackgroundColor(barColor)
        mon.setCursorPos(x, y)
        mon.write(string.rep(" ", filled))
    end
end

-- ── Rate averaging ────────────────────────────────────────────────────────────
local rateSamples  = {}          -- ring buffer of recent RF/t samples
local lastEnergy   = nil
local lastEpochMs  = nil

local function pushSample(rfPerTick)
    table.insert(rateSamples, rfPerTick)
    if #rateSamples > RATE_WINDOW then table.remove(rateSamples, 1) end
end

local function avgRate()
    if #rateSamples == 0 then return 0 end
    local sum = 0
    for _, v in ipairs(rateSamples) do sum = sum + v end
    return sum / #rateSamples
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
local function update()
    while true do
        local bat = peripheral.wrap(pylonSide)
        local mon = peripheral.wrap(monitorSide)

        if not bat then
            if mon then
                mon.setBackgroundColor(colors.black)
                mon.clear()
                mon.setTextColor(colors.red)
                mon.setCursorPos(2, 3)
                mon.write("No pylon on '" .. pylonSide .. "'")
            end
            sleep(2)
        else
            -- Read energy values (wrapped in pcall; Tier 8 cores exceed 2^53 so
            -- very large numbers may show as floating-point approximations)
            local ok1, maxStored = pcall(bat.getMaxEnergyStored)
            local ok2, current   = pcall(bat.getEnergyStored)
            if not ok1 then maxStored = 0 end
            if not ok2 then current   = 0 end

            -- Compute net transfer rate from energy delta
            local nowMs     = os.epoch("utc")
            local rateRaw   = 0
            if lastEnergy ~= nil and lastEpochMs ~= nil then
                local dtMs = nowMs - lastEpochMs
                if dtMs > 0 then
                    -- RF/tick where 1 gametick = 50 ms
                    rateRaw = (current - lastEnergy) / dtMs * 50
                end
            end
            lastEnergy   = current
            lastEpochMs  = nowMs
            pushSample(rateRaw)

            local rate = avgRate()
            local pct  = maxStored > 0 and (current / maxStored * 100) or 0

            if mon then
                local mW, mH = mon.getSize()

                mon.setBackgroundColor(colors.black)
                mon.clear()

                -- Title
                mon.setTextColor(colors.cyan)
                mon.setCursorPos(2, 2)
                mon.write("Energy Core")

                -- Max capacity
                mon.setTextColor(colors.green)
                mon.setCursorPos(2, 4)
                mon.write("Max Capacity:")
                mon.setTextColor(colors.white)
                mon.setCursorPos(2, 5)
                mon.write(format_compact(maxStored) .. " RF")

                -- Current stored + percentage
                mon.setTextColor(colors.green)
                mon.setCursorPos(2, 7)
                mon.write("Stored:")
                local pctColor = pct >= 75 and colors.green
                             or  pct >= 25 and colors.orange
                             or  colors.red
                mon.setTextColor(pctColor)
                mon.setCursorPos(2, 8)
                mon.write(format_compact(current) .. " RF")
                mon.setTextColor(colors.white)
                mon.setCursorPos(2, 9)
                mon.write(string.format("%.2f%%", pct))

                -- Progress bar
                draw_progress_bar(mon, 2, 10, mW - 2, pct, pctColor, colors.gray)

                -- Net transfer rate (positive = charging, negative = draining)
                local rateColor  = rate >= 0 and colors.lime or colors.red
                local ratePrefix = rate >= 0 and "+"         or ""
                local rateStr    = ratePrefix .. format_int(math.floor(rate)) .. " rf/t"
                mon.setTextColor(colors.green)
                mon.setCursorPos(2, 12)
                mon.write("Net Rate:")
                mon.setTextColor(rateColor)
                mon.setCursorPos(2, 13)
                mon.write(rateStr)

                -- Time to full / empty estimate
                mon.setTextColor(colors.gray)
                mon.setCursorPos(2, 15)
                if math.abs(rate) > 100 then
                    local rfDiff, label
                    if rate > 0 then
                        rfDiff = maxStored - current
                        label  = "Full in: "
                    else
                        rfDiff = current
                        label  = "Empty in:"
                    end
                    -- rate is RF/tick; 20 ticks/s
                    local secs = math.abs(rfDiff / rate / 20)
                    local m    = math.floor(secs / 60); secs = secs % 60
                    local h    = math.floor(m    / 60); m    = m    % 60
                    if h > 0 then
                        mon.write(label .. string.format(" %dh %02dm", h, m))
                    else
                        mon.write(label .. string.format(" %dm %02ds", m, math.floor(secs)))
                    end
                else
                    mon.write("Rate too low to estimate")
                end
            end
        end

        sleep(1)
    end
end

update()
