-- piano.lua — хроматична октава на MPR121, звук через зумер
--
-- Зумер — це п'єзо-пищалка на платі Лілки, та сама, що цвірінькає в меню.
-- Вона видає квадратну хвилю будь-якої частоти, тож нота тягнеться доти,
-- доки тримаєш клавішу, і октаву можна міняти на льоту.
--
-- Нічого, крім самої Лілки й плати MPR121, не потрібно: ні файлів на
-- картці, ні мережі.
--
-- Поруч зі скриптом має лежати mpr121.lua.
--
-- ELE0..ELE11 -> 12 клавіш, знизу вгору від до
--
-- Керування:
--   A              перезняти базу (натисни ПІСЛЯ того, як почепив фрукти)
--   вгору / вниз   октава
--   вліво / вправо чутливість
--   B              вихід

local mpr121 = require("mpr121")

local touch = mpr121.new(47, 48, {
    touch      = 30,     -- фрукт дає набагато більший сигнал, ніж палець
    release    = 15,
    autoconfig = true,
    unstick    = 4,
})

local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local KEYS  = { "C", "CS", "D", "DS", "E", "F", "FS", "G", "GS", "A", "AS", "B" }

-- Які з дванадцяти клавіш білі, а які чорні. У BLACK друге число —
-- між якими білими клавішами малювати чорну.
local WHITE = { 0, 2, 4, 5, 7, 9, 11 }
local BLACK = { { 1, 1 }, { 3, 2 }, { 6, 4 }, { 8, 5 }, { 10, 6 } }

local OCTAVE = 4
local REARM  = 0.5       -- як часто поновлювати тон, поки тримають клавішу

local playing     = nil  -- клавіша, що зараз звучить
local rearm_timer = 0

-- Один рядок угорі, який на кілька секунд заміняє статус.
local msg, msg_t = nil, 0
local function say(text, seconds)
    msg, msg_t = text, seconds or 2.0
end

local PAD = 16           -- відступ від краю: кути екрана заокруглені

local BLACK_C, WHITE_C, EDGE, ON_C, DIM, LILKA, RED

-- ======================= ЗВУК =======================

-- notes — глобальна таблиця Keira: notes["C4"], notes["CS4"] і так далі.
local function note_of(ch)
    return notes[KEYS[ch + 1] .. OCTAVE]
end

local function sound_off()
    buzzer.stop()
    playing = nil
end

local function sound_on(ch)
    if ch == playing then return end
    playing, rearm_timer = ch, 0
    if ch then buzzer.play(note_of(ch)) else buzzer.stop() end
end

-- ======================= ЖИТТЄВИЙ ЦИКЛ =======================

function lilka.init()
    BLACK_C = display.color565(0, 0, 0)
    WHITE_C = display.color565(235, 235, 230)
    EDGE    = display.color565(60, 60, 60)
    ON_C    = display.color565(0, 210, 0)
    DIM     = display.color565(140, 140, 140)
    LILKA   = display.color565(242, 237, 161)
    RED     = display.color565(230, 60, 40)

    playing = nil
    touch:begin()
end

function lilka.update(delta)
    local st = controller.get_state()
    local dt = delta or 0

    if msg_t > 0 then
        msg_t = msg_t - dt
        if msg_t <= 0 then msg = nil end
    end

    if st.b.just_pressed then
        sound_off()
        util.exit()
        return
    end

    -- Перезняти базу. Чіп запам'ятовує, скільки заряду бере кожна клавіша
    -- у спокої, і далі порівнює з цим числом. Якщо фрукти почепили вже
    -- після старту — база знята без них, і канал «залипає».
    if st.a.just_pressed then
        sound_off()
        touch:recalibrate()
        say("базу знято")
        return
    end

    if st.up.just_pressed and OCTAVE < 7 then
        OCTAVE = OCTAVE + 1
        if playing then buzzer.play(note_of(playing)) end
    end
    if st.down.just_pressed and OCTAVE > 1 then
        OCTAVE = OCTAVE - 1
        if playing then buzzer.play(note_of(playing)) end
    end

    -- Чутливість. Число показуємо лише на мить після зміни, щоб не
    -- захаращувати екран: у щоденній грі воно не потрібне.
    if st.right.just_pressed and touch.th_touch < 120 then
        touch:set_thresholds(touch.th_touch + 5, touch.th_release + 2)
        say("чутливість " .. touch.th_touch, 1.5)
    end
    if st.left.just_pressed and touch.th_touch > 10 then
        touch:set_thresholds(touch.th_touch - 5, touch.th_release - 2)
        say("чутливість " .. touch.th_touch, 1.5)
    end

    if not touch:update(dt) then
        sound_off()
        return
    end

    -- Яку клавішу щойно натиснули?
    local fresh = nil
    for ch = 0, 11 do
        if touch:just_pressed(ch) then fresh = ch end
    end

    if fresh then
        sound_on(fresh)

    elseif playing and not touch:down(playing) then
        -- Клавішу відпустили. Якщо тримають іншу — переходимо на неї,
        -- якщо жодної — тиша.
        local held = nil
        for ch = 0, 11 do if touch:down(ch) then held = ch end end
        sound_on(held)

    elseif playing then
        -- Документація не уточнює, чи грає buzzer.play без тривалості
        -- нескінченно. Поновлюємо тон — працює в обох випадках.
        rearm_timer = rearm_timer + dt
        if rearm_timer >= REARM then
            buzzer.play(note_of(playing))
            rearm_timer = 0
        end
    end
end

-- ======================= ЕКРАН =======================

local function draw_wiring(W, H)
    display.set_text_color(RED)
    display.set_cursor(PAD, 34)
    display.print("MPR121 не відповідає")

    display.set_text_color(DIM)
    display.set_cursor(PAD, 58)
    display.print(touch.err or "?")

    local y = 88
    for _, s in ipairs({
        "SDA -> GPIO" .. touch.sda,
        "SCL -> GPIO" .. touch.scl,
        "VCC -> 3V3",
        "GND -> GND",
    }) do
        display.set_cursor(PAD, y)
        display.print(s)
        y = y + 18
    end

    display.set_text_color(LILKA)
    display.set_cursor(PAD, H - 20)
    display.print("A — спробувати знову")
end

function lilka.draw()
    local W, H = display.width, display.height
    display.fill_screen(BLACK_C)

    if not touch.ok then
        draw_wiring(W, H)
        return
    end

    display.set_text_color(LILKA)
    display.set_cursor(PAD, 22)
    display.print(msg or ("ЗУМЕР · октава " .. OCTAVE))

    -- Клавіатура: сім білих, над ними п'ять чорних.
    local x0, y0 = 10, 40
    local ww = math.floor((W - 20) / 7)
    local wh = H - y0 - 46

    for i, ch in ipairs(WHITE) do
        local x = x0 + (i - 1) * ww
        display.fill_rect(x, y0, ww - 2, wh, touch:down(ch) and ON_C or WHITE_C)
        display.draw_rect(x, y0, ww - 2, wh, EDGE)
        display.set_text_color(EDGE)
        display.set_cursor(x + math.floor(ww / 2) - 4, y0 + wh - 10)
        display.print(NAMES[ch + 1])
    end

    local bw, bh = math.floor(ww * 0.62), math.floor(wh * 0.60)
    for _, b in ipairs(BLACK) do
        local x = x0 + b[2] * ww - math.floor(bw / 2) - 1
        display.fill_rect(x, y0, bw, bh, touch:down(b[1]) and ON_C or BLACK_C)
        display.draw_rect(x, y0, bw, bh, EDGE)
    end

    -- Нота, що звучить.
    display.set_text_color(playing and ON_C or DIM)
    display.set_cursor(PAD, H - 30)
    display.print(playing and NAMES[playing + 1] or "—")

    -- Скільки клавіш тримається одночасно. Якщо в спокої не 0 —
    -- натисни A, прибравши руки.
    local n = touch:count()
    display.set_text_color((touch.ovcf or n > 1) and RED or DIM)
    display.set_cursor(PAD + 44, H - 30)
    if touch.ovcf then
        display.print("СТРУМ!")
    else
        display.print("тримаєш: " .. n)
    end

    display.set_text_color(DIM)
    display.set_cursor(PAD, H - 14)
    display.print("A база   ^v октава   B вихід")
end
