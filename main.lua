local audioSystem = require("audioSystem")
local HSCPlayer = require("HSCPlayer")

local player
local play = false
local font

local currentPattern = 0
local currentRow = 0

local function togglePlay()
    play = not play
    if not play then
        love.audio.stop()
    end
end

function love.load()
    font = love.graphics.newFont(14)
    love.graphics.setFont(font)

    player = HSCPlayer
    player:load("MUSIC/NEOINTRO.HSC")
    --player:prettyPrintPatternsToFile("pattern.txt")
    --player:prettyPrintInstrToFile("instr.txt")
    --player:prettyPrintOrdersToFile("orders.txt")

    audioSystem.init()
end

function love.update(dt)
    currentRow = player.state.pattpos
    currentPattern = player.state.pattern

    if play then
        -- HSCPlayer:update(dt) gates itself to exactly 18.2 Hz internally.
        -- One call per frame is all that is needed; no local accumulator required.
        local stillPlaying = player:update(dt)
        if not stillPlaying then
            play = false   -- stop automatically when the song ends
        end

        for i = 1, 9 do
            local channel = player.channels[i]
            if channel.state.noteTriggered then
                local note = channel.state.note
                local instrumentData = player.instr[channel.instr + 1]
                -- note is 0-indexed HSC semitone (0=C oct0 … 95=B oct7).
                -- MIDI note 60 = C4. OPL block-4 C ≈ 275 Hz ≈ MIDI C4.
                -- Offset +12 maps HSC octave 4 (note 48) → MIDI 60 (C4). ✓
                audioSystem.playNote(i, note + 12, instrumentData)
                channel.state.noteTriggered = false
            elseif channel.state.note == -1 then -- Key off
                audioSystem.stopNote(i)
                channel.state.note = 0
            end
        end
    end

    audioSystem.update()
end

local function getMIDINoteName(noteNumber)
    if noteNumber == nil or noteNumber == 0 then return nil end
    local noteNames = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
    local octave = math.floor(noteNumber / 12) + 1
    local noteName = noteNames[(noteNumber % 12) + 1]
    return string.format("%s%d", noteName, octave)
end

function love.draw()
    love.graphics.print("HSC Player", 10, 10)
    love.graphics.print("Pattern: " .. player.state.pattern, 10, 50)
    love.graphics.print("Row: "     .. player.state.pattpos,  10, 70)
    love.graphics.print("Speed: "   .. player.state.speed,    10, 90)

    -- Display channel information
    for i = 1, 9 do
        local y = 130 + (i - 1) * 20
        love.graphics.print(string.format("Channel %d: %s %s", i,
            player.channels[i].state.cell,
            player.channels[i].state.fxDesc), 10, y)
    end

    --------------------------------------------------------------
    -- Display pattern grid
    local gridX = 250
    local gridY = 25
    local cellWidth = 60
    local cellHeight = 20
    local visibleRows = 28

    for row = 0, visibleRows - 1 do
        local actualRow = (currentRow + row) % 64
        local y = gridY + row * cellHeight

        if row == 0 then
            love.graphics.setColor(0.2, 0.2, 0.8, 0.5)
            love.graphics.rectangle("fill", gridX, y, cellWidth * 9, cellHeight)
        end

        love.graphics.setColor(1, 1, 1)
        love.graphics.print(string.format("%02d", actualRow), gridX - 30, y)

        for channel = 1, 9 do
            local x = gridX + (channel - 1) * cellWidth
            love.graphics.rectangle("line", x, y, cellWidth, cellHeight)

            if player.patterns[currentPattern] then
                local noteData = player.patterns[currentPattern][actualRow * 9 + (channel - 1)]
                local noteStr = getMIDINoteName(noteData.note)
                if noteStr == nil then
                    noteStr = ".."
                elseif noteStr == "G11" then
                    noteStr = "PAUSE"
                elseif noteStr == "G#11" and noteData.effect ~= 0 then
                    noteStr = "INST"
                end

                if noteData.effect == 0 then
                    noteStr = noteStr .. " .."
                else
                    noteStr = noteStr .. " " .. string.format("%02X", noteData.effect)
                end
                love.graphics.print(noteStr, x + 5, y + 2)

                if audioSystem.channels[channel].active then
                    love.graphics.setColor(0, 1, 0, 0.3)
                    love.graphics.rectangle("fill", x, y, cellWidth, cellHeight)
                    love.graphics.setColor(1, 1, 1)
                end
            end
        end
    end

    for channel = 1, 9 do
        local x = gridX + (channel - 1) * cellWidth
        love.graphics.print(channel, x + cellWidth / 2 - 5, gridY - 20)
    end
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    end
    if key == "space" then
        togglePlay()
    end
    if key == "r" then
        play = false
        love.audio.stop()
        player:rewind()
        audioSystem.init()
        currentRow = player.state.pattpos
        currentPattern = player.state.pattern
    end
end
