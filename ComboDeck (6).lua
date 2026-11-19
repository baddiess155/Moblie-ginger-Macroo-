--[[ ComboDeck: tool-combo macro menu for Roblox executors (mobile-friendly).
     Layout modelled on the screen recording: Combo / Settings / Credits tabs, five tool slots per
     combo, two floating trigger buttons, active-users panel, minimise + reopen button.
     Own-character tool sequencing only. No game-specific remotes are used. ]]

local CONFIG = {
	-- Behavioural values: UNCALIBRATED, tune per game (source: my assumption, not from your video).
	EquipDelay = 0.01,   -- seconds between EquipTool and Activate (your requested value)
	StepDelay  = 0.01,   -- seconds between slots (your requested value)
	SlotCount  = 5,      -- video shows Slot 1-5 on a scrolling list; more may exist (unknown)
	ComboCount = 2,      -- video shows Combo 1 and Combo 2
	SaveFile   = "ComboDeck_settings.json",
	Title      = "ComboDeck",
	-- Rapid fire applies to every tool whose name contains one of these words (comma separated, case-insensitive).
	-- "rocket" comes from your video ("Space Rocket Launcher"); "rpg" is my guess. Edit the list in the RPG tab.
	RapidWords = "rpg,rocket",

}

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local RunService       = game:GetService("RunService")
local HttpService      = game:GetService("HttpService")

local player = Players.LocalPlayer
if not player then return end

---------------------------------------------------------------- settings
local DEFAULTS = {
	combos      = {},      -- combos[i][slot] = tool name or ""
	triggerW    = 100,
	triggerH    = 42,
	transparency = 0.61,   -- shown as percent
	scale       = 1,
	animations  = true,
	watermark   = true,
	floating    = true,
	reposition  = false,
	theme       = "Midnight",
	windowPos   = nil,     -- {xs, xo, ys, yo}
	openPos     = nil,     -- position of the OPEN button, same format
	triggerPos  = {},      -- triggerPos[i] = {xs, xo, ys, yo}
	rapidWords  = CONFIG.RapidWords,
	fov         = 70,
	fovCustom   = false,   -- true once the slider has been moved; until then the game's own FOV is left alone
}

local cfg = {}
local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local r = {}
	for k, v in pairs(t) do r[k] = deepCopy(v) end
	return r
end
for k, v in pairs(DEFAULTS) do cfg[k] = deepCopy(v) end
for i = 1, CONFIG.ComboCount do
	cfg.combos[i] = {}
	for s = 1, CONFIG.SlotCount do cfg.combos[i][s] = "" end
end

local function canFile()
	return type(readfile) == "function" and type(writefile) == "function"
end

local function loadCfg()
	if not canFile() then return end
	local ok, raw = pcall(function()
		if type(isfile) == "function" and not isfile(CONFIG.SaveFile) then return nil end
		return readfile(CONFIG.SaveFile)
	end)
	if not ok or type(raw) ~= "string" then return end
	local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok2 or type(data) ~= "table" then return end
	for k, v in pairs(data) do
		if k ~= "combos" and (((k == "windowPos" or k == "openPos") and type(v) == "table") or (DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]))) then cfg[k] = v end
	end
	if type(data.combos) == "table" then
		for i = 1, CONFIG.ComboCount do
			local row = data.combos[i]
			if type(row) == "table" then
				for s = 1, CONFIG.SlotCount do
					if type(row[s]) == "string" then cfg.combos[i][s] = row[s] end
				end
			end
		end
	end
	cfg.scale = math.clamp(tonumber(cfg.scale) or 1, 0.6, 1.4)
	cfg.transparency = math.clamp(tonumber(cfg.transparency) or 0.61, 0, 0.9)
	cfg.triggerW = math.clamp(tonumber(cfg.triggerW) or 100, 60, 180)
	cfg.triggerH = math.clamp(tonumber(cfg.triggerH) or 42, 30, 80)
end

local saveQueued = false
local function saveCfg()
	if not canFile() or saveQueued then return end
	saveQueued = true
	task.delay(0.5, function()
		saveQueued = false
		pcall(function() writefile(CONFIG.SaveFile, HttpService:JSONEncode(cfg)) end)
	end)
end
loadCfg()

---------------------------------------------------------------- themes
local THEMES = {
	Midnight = { bg = Color3.fromRGB(22, 22, 26), panel = Color3.fromRGB(38, 38, 44), accent = Color3.fromRGB(70, 200, 120), text = Color3.fromRGB(240, 240, 245), sub = Color3.fromRGB(165, 165, 175) },
	Slate    = { bg = Color3.fromRGB(34, 38, 46), panel = Color3.fromRGB(52, 58, 68), accent = Color3.fromRGB(120, 170, 255), text = Color3.fromRGB(240, 242, 247), sub = Color3.fromRGB(170, 176, 188) },
	Ocean    = { bg = Color3.fromRGB(12, 30, 44), panel = Color3.fromRGB(22, 52, 72), accent = Color3.fromRGB(60, 200, 220), text = Color3.fromRGB(235, 246, 250), sub = Color3.fromRGB(150, 185, 200) },
}
local THEME_ORDER = { "Midnight", "Slate", "Ocean" }
if not THEMES[cfg.theme] then cfg.theme = "Midnight" end

local skinned = {}
local function skin(inst, prop, key)
	table.insert(skinned, { inst = inst, prop = prop, key = key })
	inst[prop] = THEMES[cfg.theme][key]
end
local function applyTheme()
	for i = #skinned, 1, -1 do
		local e = skinned[i]
		if e.inst.Parent == nil and not e.inst:IsDescendantOf(game) then
			table.remove(skinned, i)
		else
			e.inst[e.prop] = THEMES[cfg.theme][e.key]
		end
	end
end

---------------------------------------------------------------- gui helpers
local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and typeof(h) == "Instance" then return h end
	local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok2 and cg then
		local t = Instance.new("Folder")
		if pcall(function() t.Parent = cg end) then t:Destroy() return cg end
	end
	return player:WaitForChild("PlayerGui")
end

pcall(function()
	local p = guiParent()
	local old = p:FindFirstChild("ComboDeckGui")
	if old then old:Destroy() end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "ComboDeckGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
gui.Parent = guiParent()

local function new(class, props, parent)
	local i = Instance.new(class)
	for k, v in pairs(props) do i[k] = v end
	if parent then i.Parent = parent end
	return i
end
local function corner(inst, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, inst) end

local function label(parent, text, size, key, props)
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Text = text, TextSize = size or 14, Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
	}, parent)
	for k, v in pairs(props or {}) do l[k] = v end
	skin(l, "TextColor3", key or "text")
	return l
end

local function posFrom(t, fallback)
	if type(t) == "table" and #t == 4 then return UDim2.new(t[1], t[2], t[3], t[4]) end
	return fallback
end
local function posTo(u) return { u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset } end

local function makeDraggable(handle, target, canDrag, onDone)
	local dragging, startInput, startPos, startMouse = false, nil, nil, nil
	handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if canDrag and not canDrag() then return end
		dragging, startInput, startPos, startMouse = true, input, target.Position, input.Position
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input ~= startInput then return end
		local d = input.Position - startMouse
		target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input == startInput or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			if onDone then onDone() end
		end
	end)
end

---------------------------------------------------------------- combo engine
local running = false
local cancel = false

local function findTool(name)
	if name == "" then return nil end
	local want = name:lower()
	local containers = { player.Character, player:FindFirstChildOfClass("Backpack") }
	for _, c in ipairs(containers) do
		if c then
			for _, ch in ipairs(c:GetChildren()) do
				if ch:IsA("Tool") and ch.Name:lower() == want then return ch end
			end
		end
	end
	return nil
end

local function listTools()
	local seen, out = {}, {}
	for _, c in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		if c then
			for _, ch in ipairs(c:GetChildren()) do
				if ch:IsA("Tool") and not seen[ch.Name] then
					seen[ch.Name] = true
					table.insert(out, ch.Name)
				end
			end
		end
	end
	table.sort(out)
	return out
end

local function aliveHumanoid()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then return hum, ch end
	return nil
end

local rapidList = {}
local function parseRapidWords()
	rapidList = {}
	for w in tostring(cfg.rapidWords):gmatch("[^,]+") do
		w = w:match("^%s*(.-)%s*$"):lower()
		if w ~= "" then table.insert(rapidList, w) end
	end
end
parseRapidWords()

local function isRapid(name)
	local n = name:lower()
	for _, w in ipairs(rapidList) do
		if n:find(w, 1, true) then return true end
	end
	return false
end

-- the equipped matching tool first, then the first matching tool in the backpack
local function findRapidTool()
	for _, c in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
		if c then
			for _, ch in ipairs(c:GetChildren()) do
				if ch:IsA("Tool") and isRapid(ch.Name) then return ch end
			end
		end
	end
	return nil
end

local function runCombo(index, onState)
	if running then cancel = true return end -- tapping again while running stops the combo
	running, cancel = true, false
	if onState then onState(true) end
	task.spawn(function()
		pcall(function()
			for s = 1, CONFIG.SlotCount do
				if cancel then break end
				local name = cfg.combos[index][s]
				if name ~= "" then
					local hum, ch = aliveHumanoid()
					if not hum then break end
					local tool = findTool(name)
					if tool then
						-- the rapid-fire tool gets no waits at all (one Heartbeat only if the equip has not landed yet)
						local rapid = isRapid(tool.Name)
						if tool.Parent ~= ch then
							hum:EquipTool(tool)
							if rapid then
								if tool.Parent ~= ch then RunService.Heartbeat:Wait() end
							else
								task.wait(CONFIG.EquipDelay)
							end
						end
						if tool.Parent == ch then tool:Activate() end
						if not rapid then task.wait(CONFIG.StepDelay) end
					end
				end
			end
		end)
		running, cancel = false, false
		if onState then onState(false) end
	end)
end

---------------------------------------------------------------- window
local window = new("Frame", {
	Name = "Window", Size = UDim2.fromOffset(440, 230), AnchorPoint = Vector2.new(0.5, 0.5),
	Position = posFrom(cfg.windowPos, UDim2.fromScale(0.5, 0.45)), BorderSizePixel = 0, Active = true,
}, gui)
corner(window, 14)
skin(window, "BackgroundColor3", "bg")
local uiScale = new("UIScale", { Scale = cfg.scale }, window)

local function applyTransparency() window.BackgroundTransparency = cfg.transparency end
applyTransparency()

-- header
local header = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1 }, window)
local avatar = new("ImageLabel", { Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(10, 6), BackgroundTransparency = 1 }, header)
corner(avatar, 14)
task.spawn(function()
	pcall(function()
		avatar.Image = Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
	end)
end)
label(header, "@" .. player.Name, 15, "text", { Position = UDim2.fromOffset(46, 0), Size = UDim2.new(1, -110, 1, 0), Font = Enum.Font.GothamBold })
local minBtn = new("TextButton", { Text = "–", TextSize = 20, Font = Enum.Font.GothamBold, Size = UDim2.fromOffset(32, 26), Position = UDim2.new(1, -42, 0, 7), AutoButtonColor = true, BorderSizePixel = 0 }, header)
corner(minBtn, 8)
skin(minBtn, "BackgroundColor3", "panel")
skin(minBtn, "TextColor3", "text")
makeDraggable(header, window, nil, function() cfg.windowPos = posTo(window.Position) saveCfg() end)

-- sidebar
local sidebar = new("Frame", { Position = UDim2.fromOffset(8, 46), Size = UDim2.fromOffset(92, 176), BackgroundTransparency = 1 }, window)
new("UIListLayout", { Padding = UDim.new(0, 6) }, sidebar)

-- panels
local content = new("Frame", { Position = UDim2.fromOffset(108, 46), Size = UDim2.fromOffset(218, 176), BackgroundTransparency = 1, ClipsDescendants = true }, window)
local usersPanel = new("Frame", { Position = UDim2.fromOffset(334, 46), Size = UDim2.fromOffset(98, 176), BorderSizePixel = 0 }, window)
corner(usersPanel, 10)
skin(usersPanel, "BackgroundColor3", "panel")
label(usersPanel, "ACTIVE USERS", 10, "sub", { Position = UDim2.fromOffset(8, 6), Size = UDim2.new(1, -16, 0, 14), Font = Enum.Font.GothamBold })
-- Cross-server user list needs a backend that I do not have; this shows only the local user.
label(usersPanel, player.Name, 11, "text", { Position = UDim2.fromOffset(8, 26), Size = UDim2.new(1, -16, 0, 18) })

local panels, tabButtons = {}, {}
local function scrollPanel()
	local sf = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
	}, content)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	new("UIPadding", { PaddingRight = UDim.new(0, 6) }, sf)
	return sf
end

local function showTab(name)
	for n, p in pairs(panels) do p.Visible = (n == name) end
	for n, b in pairs(tabButtons) do
		b.TextColor3 = (n == name) and THEMES[cfg.theme].accent or THEMES[cfg.theme].sub
	end
	tabButtons._current = name
end
local function addTab(name)
	local b = new("TextButton", { Text = name, TextSize = 14, Font = Enum.Font.GothamMedium, Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left }, sidebar)
	new("UIPadding", { PaddingLeft = UDim.new(0, 6) }, b)
	tabButtons[name] = b
	panels[name] = scrollPanel()
	b.Activated:Connect(function() showTab(name) end)
	return panels[name]
end

---------------------------------------------------------------- reusable controls
local function row(parent, h, order)
	local r = new("Frame", { Size = UDim2.new(1, 0, 0, h or 36), BorderSizePixel = 0, LayoutOrder = order or 0 }, parent)
	corner(r, 8)
	skin(r, "BackgroundColor3", "panel")
	return r
end

local function toggle(parent, text, key, onChange)
	local r = row(parent, 34)
	label(r, text, 13, "text", { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -70, 1, 0) })
	local sw = new("TextButton", { Text = "", Size = UDim2.fromOffset(44, 22), Position = UDim2.new(1, -54, 0.5, -11), BorderSizePixel = 0, AutoButtonColor = false }, r)
	corner(sw, 11)
	local knob = new("Frame", { Size = UDim2.fromOffset(18, 18), BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1) }, sw)
	corner(knob, 9)
	local function render(animate)
		local on = cfg[key]
		local kp = on and UDim2.fromOffset(24, 2) or UDim2.fromOffset(2, 2)
		local col = on and THEMES[cfg.theme].accent or Color3.fromRGB(80, 80, 88)
		if animate and cfg.animations then
			TweenService:Create(knob, TweenInfo.new(0.15), { Position = kp }):Play()
			TweenService:Create(sw, TweenInfo.new(0.15), { BackgroundColor3 = col }):Play()
		else
			knob.Position, sw.BackgroundColor3 = kp, col
		end
	end
	render(false)
	sw.Activated:Connect(function()
		cfg[key] = not cfg[key]
		render(true)
		if onChange then onChange(cfg[key]) end
		saveCfg()
	end)
	return render
end

local function slider(parent, text, min, max, get, set, fmt)
	local r = row(parent, 44)
	label(r, text, 13, "text", { Position = UDim2.fromOffset(10, 2), Size = UDim2.new(0.6, 0, 0, 20) })
	local val = label(r, "", 12, "sub", { Position = UDim2.new(0.5, 0, 0, 2), Size = UDim2.new(0.5, -10, 0, 20), TextXAlignment = Enum.TextXAlignment.Right })
	local track = new("TextButton", { Text = "", AutoButtonColor = false, Position = UDim2.new(0, 10, 0, 28), Size = UDim2.new(1, -20, 0, 6), BorderSizePixel = 0 }, r)
	corner(track, 3)
	track.BackgroundColor3 = Color3.fromRGB(70, 70, 78)
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0 }, track)
	corner(fill, 3)
	skin(fill, "BackgroundColor3", "accent")
	local function render()
		local v = get()
		fill.Size = UDim2.fromScale(math.clamp((v - min) / (max - min), 0, 1), 1)
		val.Text = fmt(v)
	end
	local dragging, startInput = false, nil
	local function update(px)
		local w = track.AbsoluteSize.X
		if w <= 0 then return end
		local a = math.clamp((px - track.AbsolutePosition.X) / w, 0, 1)
		set(min + (max - min) * a)
		render()
	end
	track.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startInput = true, i
			update(i.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i == startInput) then update(i.Position.X) end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if dragging and (i == startInput or i.UserInputType == Enum.UserInputType.MouseButton1) then dragging = false saveCfg() end
	end)
	render()
	return render
end

local function button(parent, text, onClick, btnText)
	local r = row(parent, 34)
	label(r, text, 13, "text", { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -90, 1, 0) })
	local b = new("TextButton", { Text = btnText or "RESET", TextSize = 11, Font = Enum.Font.GothamBold, Size = UDim2.fromOffset(64, 24), Position = UDim2.new(1, -72, 0.5, -12), BorderSizePixel = 0 }, r)
	corner(b, 6)
	b.BackgroundColor3 = Color3.fromRGB(70, 70, 78)
	skin(b, "TextColor3", "text")
	b.Activated:Connect(onClick)
end

---------------------------------------------------------------- tool picker
local picker = new("Frame", { Visible = false, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = 20 }, window)
corner(picker, 14)
skin(picker, "BackgroundColor3", "bg")
local pickerTitle = label(picker, "Select tool", 14, "text", { Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -90, 0, 24), ZIndex = 21, Font = Enum.Font.GothamBold })
local pickerClose = new("TextButton", { Text = "Close", TextSize = 12, Font = Enum.Font.GothamBold, Size = UDim2.fromOffset(56, 24), Position = UDim2.new(1, -66, 0, 8), BorderSizePixel = 0, ZIndex = 21 }, picker)
corner(pickerClose, 6)
skin(pickerClose, "BackgroundColor3", "panel")
skin(pickerClose, "TextColor3", "text")
local pickerList = new("ScrollingFrame", { Position = UDim2.fromOffset(10, 40), Size = UDim2.new(1, -20, 1, -50), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 21 }, picker)
new("UIListLayout", { Padding = UDim.new(0, 4) }, pickerList)
pickerClose.Activated:Connect(function() picker.Visible = false end)

local function openPicker(title, onChoose, onPicked)
	pickerTitle.Text = title
	for _, c in ipairs(pickerList:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
	local function entry(text, value)
		local b = new("TextButton", { Text = text, TextSize = 13, Font = Enum.Font.GothamMedium, Size = UDim2.new(1, -6, 0, 30), BorderSizePixel = 0, ZIndex = 22 }, pickerList)
		corner(b, 6)
		skin(b, "BackgroundColor3", "panel")
		skin(b, "TextColor3", "text")
		b.Activated:Connect(function()
			onChoose(value)
			picker.Visible = false
			onPicked()
			saveCfg()
		end)
	end
	entry("None (clear slot)", "")
	for _, n in ipairs(listTools()) do entry(n, n) end
	picker.Visible = true
end

---------------------------------------------------------------- combo tab
local comboPanel = addTab("Combo")
local currentCombo = 1
local comboTabs = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 0 }, comboPanel)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, comboTabs)
local comboTitle = label(comboPanel, "Combo 1", 14, "text", { Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 1, Font = Enum.Font.GothamBold })
local slotButtons = {}
local comboTabButtons = {}

local function refreshSlots()
	comboTitle.Text = "Combo " .. currentCombo
	for s = 1, CONFIG.SlotCount do
		local n = cfg.combos[currentCombo][s]
		slotButtons[s].Text = (n ~= "") and n or "Tap to select tool..."
	end
	for i, b in ipairs(comboTabButtons) do
		b.BackgroundColor3 = (i == currentCombo) and Color3.fromRGB(85, 85, 95) or THEMES[cfg.theme].panel
	end
end

for i = 1, CONFIG.ComboCount do
	local b = new("TextButton", { Text = "Combo " .. i, TextSize = 12, Font = Enum.Font.GothamMedium, Size = UDim2.fromOffset(70, 28), BorderSizePixel = 0 }, comboTabs)
	corner(b, 7)
	skin(b, "TextColor3", "text")
	comboTabButtons[i] = b
	b.Activated:Connect(function() currentCombo = i refreshSlots() end)
end

for s = 1, CONFIG.SlotCount do
	local r = row(comboPanel, 40, 1 + s)
	label(r, "Slot " .. s, 12, "text", { Position = UDim2.fromOffset(10, 0), Size = UDim2.fromOffset(44, 40) })
	local b = new("TextButton", { Text = "", TextSize = 12, Font = Enum.Font.Gotham, Position = UDim2.fromOffset(58, 6), Size = UDim2.new(1, -66, 0, 28), BorderSizePixel = 0, TextTruncate = Enum.TextTruncate.AtEnd }, r)
	corner(b, 6)
	b.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	skin(b, "TextColor3", "text")
	slotButtons[s] = b
	b.Activated:Connect(function()
		local c = currentCombo
		openPicker(("Combo %d - Slot %d"):format(c, s), function(v) cfg.combos[c][s] = v end, refreshSlots)
	end)
end
local note = label(comboPanel, "Tip: type the tool's exact in-game name as it appears in the picker. Tools do not need to be on your hotbar; they are equipped from your backpack.", 11, "sub", { Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 50 })

---------------------------------------------------------------- triggers
local triggers = {}
local function layoutTriggers()
	for i, t in ipairs(triggers) do
		t.Size = UDim2.fromOffset(cfg.triggerW, cfg.triggerH)
		t.Visible = cfg.floating
	end
end

for i = 1, CONFIG.ComboCount do
	local t = new("TextButton", {
		Text = "COMBO " .. i, TextSize = 13, Font = Enum.Font.GothamBold, AnchorPoint = Vector2.new(0.5, 1),
		Position = posFrom(cfg.triggerPos[i], UDim2.new(0.5, (i - 1.5) * 120, 1, -24)),
		BackgroundTransparency = 0.35, BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 5,
	}, gui)
	corner(t, 20)
	skin(t, "BackgroundColor3", "bg")
	skin(t, "TextColor3", "text")
	triggers[i] = t
	makeDraggable(t, t, function() return cfg.reposition end, function() cfg.triggerPos[i] = posTo(t.Position) saveCfg() end)
	t.Activated:Connect(function()
		if cfg.reposition then return end
		runCombo(i, function(active) t.BackgroundTransparency = active and 0.1 or 0.35 end)
	end)
end

-- RPG rapid-fire: while on, equips (if needed) and activates the selected tool every Heartbeat, with no wait.
local rapidConn, rapidBtn
local rapidStatus
local function setRapid(on)
	if rapidConn then rapidConn:Disconnect() rapidConn = nil end
	if on then
		rapidConn = RunService.Heartbeat:Connect(function()
			if running or #rapidList == 0 then return end
			local hum, ch = aliveHumanoid()
			if not hum then return end
			local tool = findRapidTool()
			if not tool then return end
			if tool.Parent ~= ch then hum:EquipTool(tool) end
			if tool.Parent == ch then tool:Activate() end
		end)
	end
	rapidBtn.Text = on and "RPG: ON" or "RPG"
	rapidBtn.BackgroundTransparency = on and 0.1 or 0.35
	if rapidStatus then rapidStatus.Text = on and "Rapid fire is ON." or "Rapid fire is off." end
end

do
	local i = CONFIG.ComboCount + 1
	rapidBtn = new("TextButton", {
		Text = "RPG", TextSize = 13, Font = Enum.Font.GothamBold, AnchorPoint = Vector2.new(0.5, 1),
		Position = posFrom(cfg.triggerPos[i], UDim2.new(0.5, 0, 1, -76)),
		BackgroundTransparency = 0.35, BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 5,
	}, gui)
	corner(rapidBtn, 20)
	skin(rapidBtn, "BackgroundColor3", "bg")
	skin(rapidBtn, "TextColor3", "text")
	triggers[i] = rapidBtn
	makeDraggable(rapidBtn, rapidBtn, function() return cfg.reposition end, function() cfg.triggerPos[i] = posTo(rapidBtn.Position) saveCfg() end)
	rapidBtn.Activated:Connect(function()
		if cfg.reposition then return end
		setRapid(rapidConn == nil)
	end)
	gui.Destroying:Connect(function() if rapidConn then rapidConn:Disconnect() end end)
end
layoutTriggers()

---------------------------------------------------------------- settings tab
local settings = addTab("Settings")
local function header2(text, order) label(settings, text, 12, "sub", { Size = UDim2.new(1, 0, 0, 18), LayoutOrder = order, Font = Enum.Font.GothamBold }) end

header2("INTERFACE & TRIGGER CONTROLS", 1)
local renderers = {}
local function placed(order, builder)
	local r = builder()
	if r then table.insert(renderers, r) end
	for _, c in ipairs(settings:GetChildren()) do
		if c:IsA("GuiObject") and c.LayoutOrder == 0 then c.LayoutOrder = order end
	end
end

placed(2, function() return toggle(settings, "Reposition Triggers", "reposition") end)
placed(3, function()
	return slider(settings, "Trigger Size", 0, 1,
		function() return (cfg.triggerW - 60) / 120 end,
		function(a) cfg.triggerW = math.floor(60 + 120 * a + 0.5) cfg.triggerH = math.floor(30 + 50 * a + 0.5) layoutTriggers() end,
		function() return ("%dx%d"):format(cfg.triggerW, cfg.triggerH) end)
end)
header2("APPEARANCE", 4)
placed(5, function()
	return slider(settings, "UI Transparency", 0, 0.9,
		function() return cfg.transparency end,
		function(v) cfg.transparency = v applyTransparency() end,
		function(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end)
end)
placed(6, function()
	return slider(settings, "UI Scale", 0.6, 1.4,
		function() return cfg.scale end,
		function(v) cfg.scale = v uiScale.Scale = v end,
		function(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end)
end)

local themeRow = row(settings, 34, 7)
label(themeRow, "Theme", 13, "text", { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0.5, 0, 1, 0) })
local themeBtn = new("TextButton", { Text = cfg.theme, TextSize = 12, Font = Enum.Font.GothamBold, Size = UDim2.fromOffset(90, 24), Position = UDim2.new(1, -98, 0.5, -12), BorderSizePixel = 0 }, themeRow)
corner(themeBtn, 6)
themeBtn.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
skin(themeBtn, "TextColor3", "accent")
themeBtn.Activated:Connect(function()
	local idx = table.find(THEME_ORDER, cfg.theme) or 1
	cfg.theme = THEME_ORDER[idx % #THEME_ORDER + 1]
	themeBtn.Text = cfg.theme
	applyTheme()
	showTab(tabButtons._current or "Combo")
	refreshSlots()
	saveCfg()
end)

local watermark
local openBtn
placed(8, function() return toggle(settings, "UI Animations", "animations") end)
placed(9, function() return toggle(settings, "Watermark", "watermark", function(on) if watermark then watermark.Visible = on end end) end)
placed(10, function() return toggle(settings, "Floating Triggers", "floating", layoutTriggers) end)
header2("CAMERA", 11)
do
	local cam = workspace.CurrentCamera
	if not cfg.fovCustom and cam then cfg.fov = math.clamp(math.floor(cam.FieldOfView + 0.5), 70, 120) end
	cfg.fov = math.clamp(tonumber(cfg.fov) or 70, 70, 120)
end
placed(12, function()
	return slider(settings, "Field of View", 70, 120,
		function() return cfg.fov end,
		function(v) cfg.fov = math.floor(v + 0.5) cfg.fovCustom = true end,
		function(v) return ("%d°"):format(math.floor(v + 0.5)) end)
end)
header2("LAYOUT", 13)
placed(14, function()
	button(settings, "Reset UI Position", function()
		cfg.windowPos, cfg.openPos = nil, nil
		openBtn.Position = UDim2.new(0.5, 0, 0, 56)
		window.Position = UDim2.fromScale(0.5, 0.45)
		cfg.triggerPos = {}
		for i, t in ipairs(triggers) do t.Position = UDim2.new(0.5, (i - 1.5) * 120, 1, -24) end
		saveCfg()
	end)
end)
placed(15, function()
	button(settings, "Reset UI Settings", function()
		cfg.triggerW, cfg.triggerH, cfg.transparency, cfg.scale = DEFAULTS.triggerW, DEFAULTS.triggerH, DEFAULTS.transparency, DEFAULTS.scale
		cfg.animations, cfg.watermark, cfg.floating, cfg.reposition, cfg.theme = true, true, true, false, "Midnight"
		cfg.fovCustom = false
		uiScale.Scale = cfg.scale
		applyTransparency()
		applyTheme()
		layoutTriggers()
		if watermark then watermark.Visible = true end
		themeBtn.Text = cfg.theme
		saveCfg()
		for _, render in ipairs(renderers) do render() end
		showTab("Settings")
	end)
end)

---------------------------------------------------------------- fov apply
local fovConn = RunService.RenderStepped:Connect(function()
	if not cfg.fovCustom then return end
	local cam = workspace.CurrentCamera
	if cam and cam.FieldOfView ~= cfg.fov then cam.FieldOfView = cfg.fov end
end)
gui.Destroying:Connect(function() fovConn:Disconnect() end)

---------------------------------------------------------------- rpg tab
local rpgPanel = addTab("RPG")
local rpgRow = row(rpgPanel, 62, 1)
label(rpgRow, "Rapid-fire tool names contain:", 12, "text", { Position = UDim2.fromOffset(10, 2), Size = UDim2.new(1, -20, 0, 20) })
local rpgBox = new("TextBox", { Text = cfg.rapidWords, PlaceholderText = "rpg, rocket", ClearTextOnFocus = false, TextSize = 12, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 0, 26), BorderSizePixel = 0 }, rpgRow)
corner(rpgBox, 6)
rpgBox.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
skin(rpgBox, "TextColor3", "accent")
skin(rpgBox, "PlaceholderColor3", "sub")
new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, rpgBox)
rpgBox.FocusLost:Connect(function()
	cfg.rapidWords = rpgBox.Text
	parseRapidWords()
	saveCfg()
end)
rapidStatus = label(rpgPanel, "Rapid fire is off.", 12, "sub", { Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 2 })
label(rpgPanel, "Tap the floating RPG button to start and stop. It works with every tool whose name contains one of the words above (separate words with commas). While on, the tool is equipped and fired every frame with no wait. In a combo, matching tools also run with no wait. The server may still enforce its own cooldown.", 11, "sub", { Size = UDim2.new(1, 0, 0, 80), LayoutOrder = 3 })

---------------------------------------------------------------- credits tab
local credits = addTab("Credits")
label(credits, CONFIG.Title .. "\nTool-combo macro menu.\nEdit this text to credit yourself.", 13, "text", { Size = UDim2.new(1, 0, 0, 70) })

---------------------------------------------------------------- watermark, open/minimise
watermark = label(gui, CONFIG.Title, 11, "sub", { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -8, 1, -4), Size = UDim2.fromOffset(120, 14), TextXAlignment = Enum.TextXAlignment.Right, Visible = cfg.watermark })

openBtn = new("TextButton", { Text = "OPEN " .. CONFIG.Title:upper(), TextSize = 12, Font = Enum.Font.GothamBold, AnchorPoint = Vector2.new(0.5, 0), Position = posFrom(cfg.openPos, UDim2.new(0.5, 0, 0, 56)), Size = UDim2.fromOffset(150, 30), BorderSizePixel = 0, Visible = false }, gui)
corner(openBtn, 15)
skin(openBtn, "BackgroundColor3", "bg")
skin(openBtn, "TextColor3", "text")

local function setOpen(open)
	if open then
		openBtn.Visible = false
		window.Visible = true
		if cfg.animations then
			uiScale.Scale = cfg.scale * 0.9
			TweenService:Create(uiScale, TweenInfo.new(0.15), { Scale = cfg.scale }):Play()
		else
			uiScale.Scale = cfg.scale
		end
	else
		picker.Visible = false
		window.Visible = false
		openBtn.Visible = true
	end
end
minBtn.Activated:Connect(function() setOpen(false) end)
-- drag the OPEN button anywhere; a tap (no movement) still opens the menu
local pressPos
openBtn.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then pressPos = openBtn.Position end
end)
makeDraggable(openBtn, openBtn, nil, function() cfg.openPos = posTo(openBtn.Position) saveCfg() end)
openBtn.Activated:Connect(function()
	if pressPos then
		local dx = math.abs(openBtn.Position.X.Offset - pressPos.X.Offset)
		local dy = math.abs(openBtn.Position.Y.Offset - pressPos.Y.Offset)
		if dx > 6 or dy > 6 then return end
	end
	setOpen(true)
end)

---------------------------------------------------------------- start
refreshSlots()
showTab("Combo")
-- the video opens with the menu minimised and only the open button visible
setOpen(false)
