-- lib/f.lua  |  drmon shared utility library

-- ── Number formatting ─────────────────────────────────────────────────────────

-- Format an integer with comma separators  (e.g.  1234567 -> "1,234,567")
function format_int(number)
    if number == nil then number = 0 end
    local i, j, minus, int, fraction = tostring(number):find('([-]?)(%d+)([.]?%d*)')
    int = int:reverse():gsub("(%d%d%d)", "%1,")
    return minus .. int:reverse():gsub("^,", "") .. fraction
end

-- Compact SI suffix format for large RF values  (e.g. 1.23T, 456.7G, 12.3M, 4.5K)
function format_compact(n)
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

-- ── Monitor drawing ───────────────────────────────────────────────────────────

-- Write text at (x, y) with specific text/background colours
function draw_text(mon, x, y, text, text_color, bg_color)
    mon.monitor.setBackgroundColor(bg_color)
    mon.monitor.setTextColor(text_color)
    mon.monitor.setCursorPos(x, y)
    mon.monitor.write(text)
end

-- Write text right-aligned, offset from the right edge
function draw_text_right(mon, offset, y, text, text_color, bg_color)
    mon.monitor.setBackgroundColor(bg_color)
    mon.monitor.setTextColor(text_color)
    mon.monitor.setCursorPos(mon.X - string.len(tostring(text)) - offset, y)
    mon.monitor.write(text)
end

-- Write two strings on the same row: text1 left-aligned, text2 right-aligned
function draw_text_lr(mon, x, y, offset, text1, text2, text1_color, text2_color, bg_color)
    draw_text(mon, x, y, text1, text1_color, bg_color)
    draw_text_right(mon, offset, y, text2, text2_color, bg_color)
end

-- Draw a solid horizontal line of spaces in a given colour
function draw_line(mon, x, y, length, color)
    if length < 0 then length = 0 end
    mon.monitor.setBackgroundColor(color)
    mon.monitor.setCursorPos(x, y)
    mon.monitor.write(string.rep(" ", length))
end

-- Two-layer progress bar: background then filled portion
function progress_bar(mon, x, y, length, minVal, maxVal, bar_color, bg_color)
    draw_line(mon, x, y, length, bg_color)
    local barSize = math.floor((minVal / maxVal) * length)
    draw_line(mon, x, y, barSize, bar_color)
end
