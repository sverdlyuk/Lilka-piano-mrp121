-- mpr121.lua — бібліотека для MPR121, 12-канального ємнісного сенсора дотику
--
-- Покласти поруч зі своєю програмою на картці. Далі:
--
--   local mpr121 = require("mpr121")
--   local touch = mpr121.new(47, 48)          -- SDA, SCL
--
--   function lilka.init()
--       local ok, err = touch:begin()
--       if not ok then print(err) end
--   end
--
--   function lilka.update(delta)
--       touch:update(delta)                   -- обов'язково щокадру
--       if touch:down(0) then ... end         -- канал ELE0 натиснутий?
--   end
--
-- Налаштування передаються третім аргументом:
--
--   mpr121.new(47, 48, { touch = 30, release = 15, autoconfig = true })
--
--   touch      поріг натискання   (більше = менш чутливо)
--   release    поріг відпускання  (завжди менший за touch — це гістерезис)
--   autoconfig чи давати чіпу самому підібрати струм заряду під кожен електрод
--   unstick    через скільки секунд безперервного "дотику" вважати канал
--              залиплим і перезняти базу; 0 = вимкнути.
--              Побічний ефект: якщо навмисне тримати клавішу довше за цей
--              час, база перезніметься і нота обірветься.
--   addr       адреса на шині; nil = шукати самому серед 0x5A..0x5D
--   prox       режим наближення: 0 (вимкнено), 2, 4 або 12 — скільки
--              електродів чіп з'єднає в один великий. Дає віртуальний
--              13-й канал, який бачить руку ще ДО дотику:
--
--                local t = mpr121.new(47, 48, { prox = 12 })
--                t:begin()
--                t:freeze()              -- коли руки над електродом немає
--                local d = t:prox_delta()   -- 0 = нікого, більше = ближче

local M = {}

local REG = {
    TOUCH_L   = 0x00,
    FILT_0L   = 0x04,
    BASE_0    = 0x1E,
    MHDR      = 0x2B, NHDR = 0x2C, NCLR = 0x2D, FDLR = 0x2E,
    MHDF      = 0x2F, NHDF = 0x30, NCLF = 0x31, FDLF = 0x32,
    NHDT      = 0x33, NCLT = 0x34, FDLT = 0x35,
    -- те саме, але для віртуального 13-го каналу (наближення)
    PROX_FILT = 0x1C, PROX_BASE = 0x2A,
    MHDPR     = 0x36, NHDPR = 0x37, NCLPR = 0x38, FDLPR = 0x39,
    MHDPF     = 0x3A, NHDPF = 0x3B, NCLPF = 0x3C, FDLPF = 0x3D,
    NHDPT     = 0x3E, NCLPT = 0x3F, FDLPT = 0x40,
    PROX_TTH  = 0x59, PROX_RTH = 0x5A,
    TOUCHTH_0 = 0x41,
    DEBOUNCE  = 0x5B,
    CONFIG1   = 0x5C,
    CONFIG2   = 0x5D,
    ECR       = 0x5E,
    ACFG0     = 0x7B, ACFG1 = 0x7C,
    USL       = 0x7D, LSL = 0x7E, TL = 0x7F,
    SOFTRESET = 0x80,
}

-- Межі автоналаштування для живлення 3.3 В.
-- Формула з AN3889: USL = (VDD-0.7)/VDD * 256, LSL = USL*0.65, TL = USL*0.9
local USL_33, LSL_33, TL_33 = 196, 127, 176

local Device = {}
Device.__index = Device

function M.new(sda, scl, opts)
    opts = opts or {}
    return setmetatable({
        sda        = sda or 47,
        scl        = scl or 48,
        addr       = opts.addr,
        th_touch   = opts.touch      or 30,
        th_release = opts.release    or 15,
        autoconfig = opts.autoconfig ~= false,
        unstick    = opts.unstick    or 4,
        freq       = opts.freq       or 100000,
        prox       = opts.prox       or 0,     -- 0 / 2 / 4 / 12 електродів разом
        prox_th    = opts.prox_touch or 2,
        prox_rth   = opts.prox_release or 1,
        frozen     = false,
        mask       = 0,
        prev       = 0,
        raw_mask   = 0,
        ovcf       = false,
        ok         = false,
        err        = nil,
        held       = {},   -- скільки секунд канал безперервно "натиснутий"
    }, Device)
end

function Device:_w(reg, val)
    return i2c.write(self.addr, { reg, val })
end

function Device:_r(reg, n)
    return i2c.write_read(self.addr, reg, n)
end

-- ECR = CL(біти 7:6) + ELEPROX_EN(5:4) + ELE_EN(3:0)
function Device:_ecr(cl)
    local eleprox = 0
    if     self.prox == 2  then eleprox = 0x10
    elseif self.prox == 4  then eleprox = 0x20
    elseif self.prox == 12 then eleprox = 0x30 end
    return cl + eleprox + 0x0F
end

local function find(freq)
    local list = i2c.scan()
    for _, a in ipairs(list) do
        if a >= 0x5A and a <= 0x5D then return a end
    end
    return nil
end

function Device:begin()
    self.ok, self.err = false, nil

    i2c.begin(self.sda, self.scl, self.freq)

    self.addr = self.addr or find()
    if not self.addr then
        self.err = "MPR121 не знайдено на шині"
        return false, self.err
    end

    self:_w(REG.SOFTRESET, 0x63)
    util.sleep(0.002)

    -- Конфіг приймається ТІЛЬКИ в стоп-режимі. Це головна пастка MPR121:
    -- у робочому режимі чіп мовчки ігнорує записи, і здається що він мертвий.
    self:_w(REG.ECR, 0x00)

    -- Після скидання CONFIG2 = 0x24. Якщо ні — на шині не MPR121.
    local c2 = self:_r(REG.CONFIG2, 1)
    if not c2 or not c2[1] then
        self.err = "чіп не відповідає"
        return false, self.err
    end
    if c2[1] ~= 0x24 then
        self.err = "це не MPR121, CONFIG2=" .. c2[1]
        return false, self.err
    end

    self:set_thresholds(self.th_touch, self.th_release)

    -- Стеження за базою: як швидко чіп забуває повільні зміни.
    -- R = наростання, F = спадання, T = поки канал у стані дотику.
    self:_w(REG.MHDR, 0x01) self:_w(REG.NHDR, 0x01) self:_w(REG.NCLR, 0x0E) self:_w(REG.FDLR, 0x00)
    self:_w(REG.MHDF, 0x01) self:_w(REG.NHDF, 0x05) self:_w(REG.NCLF, 0x01) self:_w(REG.FDLF, 0x00)
    self:_w(REG.NHDT, 0x00) self:_w(REG.NCLT, 0x00) self:_w(REG.FDLT, 0x00)

    self:_w(REG.DEBOUNCE, 0x00)
    self:_w(REG.CONFIG1,  0x10)   -- струм заряду 16 мкА
    self:_w(REG.CONFIG2,  0x20)   -- час заряду 0.5 мкс, період 1 мс

    -- Автоналаштування: чіп сам підбирає струм і час заряду ОКРЕМО для кожного
    -- каналу. Саме це рятує, коли електроди різного розміру — бананів, фольги
    -- і голого дроту на одній платі.
    if self.autoconfig then
        self:_w(REG.USL, USL_33)
        self:_w(REG.LSL, LSL_33)
        self:_w(REG.TL,  TL_33)
        self:_w(REG.ACFG0, 0x0B)  -- BVA=10, ARE=1, ACE=1
        self:_w(REG.ACFG1, 0x00)
    end

    -- Режим наближення: чіп з'єднує електроди в один великий і додає
    -- віртуальний 13-й канал, який бачить руку ще ДО дотику.
    if self.prox > 0 then
        -- База має миттєво повертатись, коли руку прибрали, і майже не
        -- повзти за рукою, коли вона наближається (AN3893).
        self:_w(REG.MHDPR, 0xFF) self:_w(REG.NHDPR, 0xFF)
        self:_w(REG.NCLPR, 0x00) self:_w(REG.FDLPR, 0x00)
        self:_w(REG.MHDPF, 0x01) self:_w(REG.NHDPF, 0x01)
        self:_w(REG.NCLPF, 0xFF) self:_w(REG.FDLPF, 0xFF)
        self:_w(REG.NHDPT, 0x00) self:_w(REG.NCLPT, 0x00) self:_w(REG.FDLPT, 0x00)

        self:_w(REG.PROX_TTH, self.prox_th)
        self:_w(REG.PROX_RTH, self.prox_rth)
    end

    -- Старт. CL=10 означає: базу взяти з ПЕРШОГО ж вимірювання.
    -- Тобто все, що має висіти на електродах, має висіти вже зараз.
    self.frozen = false
    self:_w(REG.ECR, self:_ecr(0x80))
    util.sleep(0.02)

    for ch = 0, 11 do self.held[ch] = 0 end
    self.mask, self.prev = 0, 0
    self.ok = true
    return true
end

function Device:set_thresholds(touch, release)
    self.th_touch, self.th_release = touch, release
    for i = 0, 11 do
        self:_w(REG.TOUCHTH_0 + i * 2,     touch)
        self:_w(REG.TOUCHTH_0 + i * 2 + 1, release)
    end
end

-- Перезняти базу з тим, що висить на електродах ЗАРАЗ.
-- Викликати після того, як почепив банани.
function Device:recalibrate()
    return self:begin()
end

-- Прочитати чіп. Викликати раз на кадр.
function Device:update(delta)
    if not self.ok then return false end

    local b = self:_r(REG.TOUCH_L, 2)
    if not b or not b[1] or not b[2] then
        self.ok = false
        self.err = "не читається шина"
        return false
    end

    local raw = b[1] + b[2] * 256
    self.raw_mask = raw
    self.ovcf = math.floor(raw / 32768) % 2 == 1
    self.prev = self.mask
    self.mask = raw % 4096

    -- Залипання. Якщо канал "натиснутий" довше за unstick секунд — це майже
    -- напевно не палець, а те, що базу зняли без банана. Перезнімаємо.
    if self.unstick > 0 then
        local stuck = false
        for ch = 0, 11 do
            if self:down(ch) then
                self.held[ch] = self.held[ch] + (delta or 0)
                if self.held[ch] > self.unstick then stuck = true end
            else
                self.held[ch] = 0
            end
        end
        if stuck then self:recalibrate() end
    end

    return true
end

function Device:down(ch)
    return math.floor(self.mask / (2 ^ ch)) % 2 == 1
end

function Device:just_pressed(ch)
    return self:down(ch) and math.floor(self.prev / (2 ^ ch)) % 2 == 0
end

function Device:just_released(ch)
    return (not self:down(ch)) and math.floor(self.prev / (2 ^ ch)) % 2 == 1
end

function Device:count()
    local n = 0
    for ch = 0, 11 do if self:down(ch) then n = n + 1 end end
    return n
end

-- ---------- режим наближення ----------

-- Заморозити базу (CL=01). Після цього чіп більше не «звикає» до руки,
-- і різниця база-сигнал стає стабільною мірою відстані.
-- Кликати, коли руки над електродом НЕМАЄ.
function Device:freeze()
    self:_w(REG.ECR, self:_ecr(0x40))
    self.frozen = true
end

function Device:unfreeze()
    self:_w(REG.ECR, self:_ecr(0x80))
    self.frozen = false
end

function Device:prox_filtered()
    local b = self:_r(REG.PROX_FILT, 2)
    if not b or not b[1] or not b[2] then return 0 end
    return b[1] + b[2] * 256
end

function Device:prox_baseline()
    local b = self:_r(REG.PROX_BASE, 1)
    if not b or not b[1] then return 0 end
    return b[1] * 4   -- у регістрі старші 8 біт з 10
end

-- Наскільки близько рука. 0 = нікого, більше = ближче.
function Device:prox_delta()
    local d = self:prox_baseline() - self:prox_filtered()
    if d < 0 then d = 0 end
    return d
end

-- Біт 12 у регістрі статусу — спрацював поріг наближення.
function Device:prox_near()
    return math.floor(self.raw_mask / 4096) % 2 == 1
end

-- Сирі числа. Потрібні тільки щоб підібрати пороги.
function Device:filtered(ch)
    local b = self:_r(REG.FILT_0L + ch * 2, 2)
    if not b or not b[1] or not b[2] then return 0 end
    return b[1] + b[2] * 256
end

function Device:baseline(ch)
    local b = self:_r(REG.BASE_0 + ch, 1)
    if not b or not b[1] then return 0 end
    return b[1] * 4   -- у регістрі лежать старші 8 біт з 10
end

return M
