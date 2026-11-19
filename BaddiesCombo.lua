--!nocheck
-- BaddiesCombo.lua : mobile-first combo launcher for Baddies (Roblox, Luau).
-- Not run in-game by the author. See CONFIG for what is derived from the video vs. chosen.

local env = (getgenv and getgenv()) or _G
if env.__BaddiesCombo and env.__BaddiesCombo.Unload then
	pcall(env.__BaddiesCombo.Unload)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------------
-- CONFIG
-- Provenance legend:
--   [VIDEO]  read from your screen recording (1000x462 downscaled frames)
--   [CHOSEN] my design decision, uncalibrated, edit freely
--   nil      unknown / unset
---------------------------------------------------------------------------
local CONFIG = {
	-- [VIDEO] button centres as fractions of the screen (x/1000, y/462 of the frame) and size in px.
	Layout = {
		Combo1 = { x = 0.503, y = 0.426 },
		Combo2 = { x = 0.278, y = 0.530 },
		Combo3 = { x = 0.280, y = 0.416 },
		On = { x = 0.505, y = 0.084 },
		-- [CHOSEN] the video shows no script settings button (the gear there is Roblox's own top bar).
		Settings = { x = 0.40, y = 0.30 },
	},
	ButtonSize = Vector2.new(124, 52), -- [VIDEO] approx 118x48, enlarged slightly for touch (>= 44 px)
	SettingsSize = Vector2.new(52, 52), -- [CHOSEN]

	-- Which signal the game's own COMBO buttons listen to is UNKNOWN. Try "Activated" first;
	-- if the game does not react, change this list to {"MouseButton1Click"} or {"MouseButton1Down","MouseButton1Up"}.
	GameButtonSignals = { "Activated" },

	-- [VIDEO] the game's own button labels are "COMBO 1".."COMBO 4" (text on screen).
	-- [VIDEO] "Brass Knuckles" is a weapon name shown by the game's equip notification.
	-- [CHOSEN] which combo does what, and every delay, is NOT visible in the video.
	-- Step types: {t="equip",name=..} {t="unequip"} {t="game",label="COMBO 1"} {t="wait",s=seconds}
	Sequences = {
		[1] = {
			{ t = "equip", name = "Brass Knuckles" },
			{ t = "wait", s = 0.15 },
			{ t = "game", label = "COMBO 1" },
		},
		[2] = {
			{ t = "equip", name = "Brass Knuckles" },
			{ t = "wait", s = 0.15 },
			{ t = "game", label = "COMBO 1" },
			{ t = "wait", s = 0.35 },
			{ t = "game", label = "COMBO 2" },
		},
		[3] = {
			{ t = "equip", name = "Brass Knuckles" },
			{ t = "wait", s = 0.15 },
			{ t = "game", label = "COMBO 1" },
			{ t = "wait", s = 0.35 },
			{ t = "game", label = "COMBO 2" },
			{ t = "wait", s = 0.35 },
			{ t = "game", label = "COMBO 3" },
		},
	},
}

---------------------------------------------------------------------------
-- State and cleanup
---------------------------------------------------------------------------
local S = {
	On = true,
	Loop = false,
	DelayMul = 1, -- multiplies every wait step
	Scale = 1, -- button scale
	Transparency = 0.25, -- combo button background transparency
	Unlocked = false, -- drag buttons to reposition
}
local connections = {}
local function track(c) connections[#connections + 1] = c return c end

local function getCharacter()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 then
		return nil
	end
	return char, hum
end

---------------------------------------------------------------------------
-- Pure helpers
---------------------------------------------------------------------------
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function normalizeText(s)
	return (string.upper(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function toolMatches(tool, wanted)
	return string.find(string.lower(tool.Name), string.lower(wanted), 1, true) ~= nil
end

---------------------------------------------------------------------------
-- GUI root
---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "BaddiesCombo"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
local parented = false
if gethui then parented = pcall(function() gui.Parent = gethui() end) end
if not parented then parented = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
if not parented then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local pills = {} -- [name] = TextButton
local function makePill(name, text, pos, size)
	local b = Instance.new("TextButton")
	b.Name = name
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(pos.x, pos.y)
	b.Size = UDim2.fromOffset(size.X, size.Y)
	b.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
	b.BackgroundTransparency = S.Transparency
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 17
	b.Text = text
	b.AutoButtonColor = false
	b.Active = true
	b.Draggable = false
	b.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = b
	local scale = Instance.new("UIScale")
	scale.Scale = S.Scale
	scale.Parent = b
	pills[name] = b
	return b
end

local statusLabel = Instance.new("TextLabel")
statusLabel.AnchorPoint = Vector2.new(0.5, 0)
statusLabel.Position = UDim2.fromScale(0.5, 0.60)
statusLabel.Size = UDim2.fromOffset(300, 22)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
statusLabel.TextStrokeTransparency = 0.5
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextSize = 14
statusLabel.Text = ""
statusLabel.Parent = gui

local function setStatus(t) statusLabel.Text = t end

---------------------------------------------------------------------------
-- Game-button resolver and activator
---------------------------------------------------------------------------
local gameButtonCache = {}

local function asGuiButton(obj)
	local cur = obj
	while cur and cur ~= game do
		if cur:IsA("GuiButton") then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function resolveGameButton(label)
	local cached = gameButtonCache[label]
	if cached and cached.Parent and cached:IsDescendantOf(game) then
		return cached
	end
	gameButtonCache[label] = nil
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local want = normalizeText(label)
	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextButton") or obj:IsA("TextLabel")) and not obj:IsDescendantOf(gui) and normalizeText(obj.Text) == want then
			local btn = asGuiButton(obj)
			if btn then
				gameButtonCache[label] = btn
				return btn
			end
		end
	end
	return nil
end

local function activateGameButton(btn)
	if not firesignal then
		return false, "executor has no firesignal"
	end
	local anyOk = false
	for _, signalName in ipairs(CONFIG.GameButtonSignals) do
		local sig = btn[signalName]
		if sig and pcall(firesignal, sig) then
			anyOk = true
		end
	end
	return anyOk, anyOk and nil or "firesignal failed"
end

---------------------------------------------------------------------------
-- Sequence runner
---------------------------------------------------------------------------
local token = 0
local activeId = nil

local function findTool(name)
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	local char = LocalPlayer.Character
	for _, holder in ipairs({ char, backpack }) do
		if holder then
			for _, child in ipairs(holder:GetChildren()) do
				if child:IsA("Tool") and toolMatches(child, name) then
					return child
				end
			end
		end
	end
	return nil
end

local function runStep(step)
	if step.t == "wait" then
		task.wait(step.s * S.DelayMul)
		return true
	end
	local char, hum = getCharacter()
	if not hum then
		return false, "no living character"
	end
	if step.t == "equip" then
		local tool = findTool(step.name)
		if not tool then
			return false, "tool '" .. step.name .. "' not found"
		end
		if tool.Parent ~= char then
			hum:EquipTool(tool)
		end
		return true
	elseif step.t == "unequip" then
		hum:UnequipTools()
		return true
	elseif step.t == "game" then
		local btn = resolveGameButton(step.label)
		if not btn then
			return false, "game button '" .. step.label .. "' not found"
		end
		return activateGameButton(btn)
	end
	return false, "unknown step type"
end

local function refreshVisuals()
	for id = 1, 3 do
		local b = pills["Combo" .. id]
		if b then
			local running = activeId == id
			b.BackgroundColor3 = running and Color3.fromRGB(40, 120, 70) or Color3.fromRGB(30, 30, 34)
			b.BackgroundTransparency = S.On and S.Transparency or 0.7
			b.TextTransparency = S.On and 0 or 0.5
		end
	end
	local on = pills.On
	on.Text = S.On and "ON" or "OFF"
	on.BackgroundColor3 = S.On and Color3.fromRGB(40, 120, 70) or Color3.fromRGB(140, 40, 40)
end

local function stop(reason)
	token += 1
	activeId = nil
	refreshVisuals()
	if reason then
		setStatus(reason)
	end
end

local function start(id)
	if not S.On or S.Unlocked then
		return
	end
	if activeId == id then
		stop("COMBO " .. id .. " stopped")
		return
	end
	stop()
	token += 1
	local mine = token
	activeId = id
	refreshVisuals()
	task.spawn(function()
		local steps = CONFIG.Sequences[id]
		repeat
			for i, step in ipairs(steps) do
				if mine ~= token then return end
				setStatus(string.format("COMBO %d: step %d/%d", id, i, #steps))
				local ok, err = runStep(step)
				if mine ~= token then return end
				if not ok then
					stop(string.format("COMBO %d failed: %s", id, tostring(err)))
					return
				end
			end
			if S.Loop then task.wait(0.05) end
		until not S.Loop or mine ~= token
		if mine == token then
			stop("COMBO " .. id .. " done")
		end
	end)
end

-- Stop on death.
local function hookCharacter(char)
	local hum = char:WaitForChild("Humanoid", 5)
	if hum then
		track(hum.Died:Connect(function() stop("stopped: character died") end))
	end
end
if LocalPlayer.Character then task.spawn(hookCharacter, LocalPlayer.Character) end
track(LocalPlayer.CharacterAdded:Connect(hookCharacter))

---------------------------------------------------------------------------
-- Main buttons
---------------------------------------------------------------------------
for id = 1, 3 do
	local b = makePill("Combo" .. id, "COMBO " .. id, CONFIG.Layout["Combo" .. id], CONFIG.ButtonSize)
	track(b.Activated:Connect(function() start(id) end))
end

local onButton = makePill("On", "ON", CONFIG.Layout.On, Vector2.new(92, 44))
track(onButton.Activated:Connect(function()
	if S.Unlocked then return end
	S.On = not S.On
	if not S.On then
		stop("script OFF")
	else
		setStatus("script ON")
	end
	refreshVisuals()
end))

local settingsButton = makePill("Settings", "⚙", CONFIG.Layout.Settings, CONFIG.SettingsSize)
settingsButton.TextSize = 26

---------------------------------------------------------------------------
-- Settings panel
---------------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(280, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
panel.BackgroundTransparency = 0.05
panel.Visible = false
panel.Active = true
panel.Parent = gui
do
	local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 12) c.Parent = panel
	local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 6) l.SortOrder = Enum.SortOrder.LayoutOrder l.Parent = panel
	local p = Instance.new("UIPadding")
	p.PaddingTop, p.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10)
	p.PaddingLeft, p.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	p.Parent = panel
end

local rowOrder = 0
local function panelRow(height)
	rowOrder += 1
	local r = Instance.new("Frame")
	r.Size = UDim2.new(1, 0, 0, height or 44)
	r.BackgroundTransparency = 1
	r.LayoutOrder = rowOrder
	r.Parent = panel
	return r
end

local function styledButton(parent, text, size, position)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = position or UDim2.new()
	b.BackgroundColor3 = Color3.fromRGB(48, 48, 60)
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 15
	b.Text = text
	b.Parent = parent
	local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 8) c.Parent = b
	return b
end

local function toggleRow(label, key, onChange)
	local r = panelRow()
	local b = styledButton(r, "", UDim2.fromScale(1, 1))
	local function refresh()
		b.Text = label .. ": " .. (S[key] and "ON" or "OFF")
		b.BackgroundColor3 = S[key] and Color3.fromRGB(40, 120, 70) or Color3.fromRGB(48, 48, 60)
	end
	b.Activated:Connect(function()
		S[key] = not S[key]
		if onChange then onChange(S[key]) end
		refresh()
	end)
	refresh()
end

local function stepperRow(label, key, step, lo, hi, fmt, onChange)
	local r = panelRow()
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, -96, 1, 0)
	text.Position = UDim2.fromOffset(48, 0)
	text.TextColor3 = Color3.fromRGB(255, 255, 255)
	text.Font = Enum.Font.GothamMedium
	text.TextSize = 14
	text.Parent = r
	local function refresh() text.Text = label .. " " .. string.format(fmt, S[key]) end
	local minus = styledButton(r, "-", UDim2.fromOffset(44, 44))
	local plus = styledButton(r, "+", UDim2.fromOffset(44, 44), UDim2.new(1, -44, 0, 0))
	minus.Activated:Connect(function()
		S[key] = clamp(math.floor((S[key] - step) / step + 0.5) * step, lo, hi)
		if onChange then onChange() end
		refresh()
	end)
	plus.Activated:Connect(function()
		S[key] = clamp(math.floor((S[key] + step) / step + 0.5) * step, lo, hi)
		if onChange then onChange() end
		refresh()
	end)
	refresh()
end

local function applyAppearance()
	for _, b in pairs(pills) do
		local scale = b:FindFirstChildOfClass("UIScale")
		if scale then scale.Scale = S.Scale end
	end
	refreshVisuals()
end

toggleRow("Loop sequence", "Loop")
stepperRow("Delay x", "DelayMul", 0.25, 0.5, 2, "%.2f", nil)
stepperRow("Button size x", "Scale", 0.1, 0.8, 1.6, "%.1f", applyAppearance)
stepperRow("Opacity (lower=solid)", "Transparency", 0.1, 0, 0.6, "%.1f", applyAppearance)
toggleRow("Move buttons", "Unlocked", function(on)
	if on then stop("drag buttons, then turn Move off") end
	for name, b in pairs(pills) do
		b.Draggable = on
	end
end)

do
	local r = panelRow()
	local close = styledButton(r, "Close", UDim2.fromScale(0.48, 1))
	close.Activated:Connect(function() panel.Visible = false end)
	local unload = styledButton(r, "Unload", UDim2.fromScale(0.48, 1), UDim2.fromScale(0.52, 0))
	unload.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
	unload.Activated:Connect(function()
		if env.__BaddiesCombo then env.__BaddiesCombo.Unload() end
	end)
end

track(settingsButton.Activated:Connect(function()
	if S.Unlocked then return end
	panel.Visible = not panel.Visible
end))

---------------------------------------------------------------------------
-- Unload
---------------------------------------------------------------------------
local function unload()
	token += 1
	activeId = nil
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	table.clear(connections)
	if gui then gui:Destroy() end
	env.__BaddiesCombo = nil
end
env.__BaddiesCombo = { Unload = unload }

refreshVisuals()
setStatus("ready")
