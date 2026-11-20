-- BaddiesPanel.lua
-- Executor-environment Luau. Rebuilt from the screen recording you sent.
-- Not run in-game by the author: test it and report what breaks.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- CONFIG. nil = UNKNOWN (feature stays gated until you fill it in).
-- ---------------------------------------------------------------------------
local CONFIG = {
	TOGGLE_KEY = Enum.KeyCode.K,          -- from the "K" button visible in the video
	STOMP_KEY = Enum.KeyCode.E,           -- read from the HUD labels in the video (G / F / E / M1 / Ctrl / Shift)
	STOMP_RANGE = 8,                      -- studs. UNCALIBRATED
	STOMP_COOLDOWN = 0.6,                 -- seconds. UNCALIBRATED
	EQUIP_DELAY = 0.12,                   -- seconds between equip and activate. UNCALIBRATED
	ACTIVATE_DELAY = 0.12,                -- seconds after activate. UNCALIBRATED
	HITBOX_MIN = 2,
	HITBOX_MAX = 50,
	MAX_SLOTS = 6,

	DOWNED_ATTRIBUTE = nil,               -- UNKNOWN: attribute name on the victim's Character or Humanoid that marks "downed"
	STOMP_CUTSCENE_REMOTE_PATH = nil,     -- UNKNOWN: path under ReplicatedStorage, e.g. { "Folder", "RemoteName" }
	MUSIC_GIST_URL = nil,                 -- UNKNOWN: your raw gist URL (script that loads the music)
}

local SETTINGS_FILE = "BaddiesPanel.json"

-- ---------------------------------------------------------------------------
-- Single-instance guard and cleanup
-- ---------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if type(env.BaddiesPanelCleanup) == "function" then
	pcall(env.BaddiesPanelCleanup)
end

local connections = {}
local function track(conn)
	connections[#connections + 1] = conn
	return conn
end

-- ---------------------------------------------------------------------------
-- Settings and macro data (persisted when writefile exists)
-- ---------------------------------------------------------------------------
local settings = { uiAnimations = true, watermark = true, hitboxSize = 5, posX = nil, posY = nil }
local macros = {
	{ bind = "", slots = { "", "", "" } },
	{ bind = "", slots = { "", "", "" } },
	{ bind = "", slots = { "", "", "" } },
}

local function saveData()
	if not writefile then return end
	pcall(function()
		writefile(SETTINGS_FILE, HttpService:JSONEncode({ settings = settings, macros = macros }))
	end)
end

local function loadData()
	if not (isfile and readfile) then return end
	local ok, data = pcall(function()
		if isfile(SETTINGS_FILE) then
			return HttpService:JSONDecode(readfile(SETTINGS_FILE))
		end
	end)
	if not ok or type(data) ~= "table" then return end
	local s = data.settings
	if type(s) == "table" then
		if type(s.uiAnimations) == "boolean" then settings.uiAnimations = s.uiAnimations end
		if type(s.watermark) == "boolean" then settings.watermark = s.watermark end
		if type(s.hitboxSize) == "number" and s.hitboxSize == s.hitboxSize then
			settings.hitboxSize = math.clamp(s.hitboxSize, CONFIG.HITBOX_MIN, CONFIG.HITBOX_MAX)
		end
		if type(s.posX) == "number" and type(s.posY) == "number" then
			settings.posX, settings.posY = s.posX, s.posY
		end
	end
	if type(data.macros) == "table" then
		for i = 1, 3 do
			local m = data.macros[i]
			if type(m) == "table" then
				if type(m.bind) == "string" then macros[i].bind = m.bind end
				if type(m.slots) == "table" then
					local slots = {}
					for j = 1, math.min(#m.slots, CONFIG.MAX_SLOTS) do
						slots[j] = type(m.slots[j]) == "string" and m.slots[j] or ""
					end
					if #slots > 0 then macros[i].slots = slots end
				end
			end
		end
	end
end
loadData()

-- ---------------------------------------------------------------------------
-- Feature state
-- ---------------------------------------------------------------------------
local state = {
	hitboxEnabled = false,
	autoStomp = false,
	blockCutscene = false,
	macroBusy = false,
	capturingBind = nil, -- macro index while waiting for a button press
}

local originals = setmetatable({}, { __mode = "k" })
local disabledConnections = {}

local function getCharacterParts(player)
	local char = player.Character
	if not char then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not root:IsA("BasePart") then return nil end
	return char, hum, root
end

-- Hitbox extender -----------------------------------------------------------
local function applyHitbox(root)
	if not originals[root] then
		originals[root] = { Size = root.Size, Transparency = root.Transparency, CanCollide = root.CanCollide }
	end
	local s = settings.hitboxSize
	root.Size = Vector3.new(s, s, s)
	root.Transparency = 0.7
	root.CanCollide = false
end

local function restoreHitboxes()
	for part, orig in pairs(originals) do
		if part.Parent then
			part.Size = orig.Size
			part.Transparency = orig.Transparency
			part.CanCollide = orig.CanCollide
		end
		originals[part] = nil
	end
end

-- Auto stomp ----------------------------------------------------------------
local function isDowned(char, hum)
	local name = CONFIG.DOWNED_ATTRIBUTE
	if not name then return false end
	return char:GetAttribute(name) == true or hum:GetAttribute(name) == true
end

local lastStomp = 0
local function pressStompKey()
	VirtualInputManager:SendKeyEvent(true, CONFIG.STOMP_KEY, false, game)
	task.wait(0.05)
	VirtualInputManager:SendKeyEvent(false, CONFIG.STOMP_KEY, false, game)
end

local function autoStompStep()
	local now = os.clock()
	if now - lastStomp < CONFIG.STOMP_COOLDOWN then return end
	local _, myHum, myRoot = getCharacterParts(LocalPlayer)
	if not myHum or myHum.Health <= 0 then return end
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local char, hum, root = getCharacterParts(player)
			if char and isDowned(char, hum) then
				local d = (root.Position - myRoot.Position).Magnitude
				if d == d and d <= CONFIG.STOMP_RANGE then
					lastStomp = now
					task.spawn(pressStompKey)
					return
				end
			end
		end
	end
end

-- Stomp cutscene block ------------------------------------------------------
local function resolveCutsceneRemote()
	local path = CONFIG.STOMP_CUTSCENE_REMOTE_PATH
	if type(path) ~= "table" or #path == 0 then return nil end
	local inst = ReplicatedStorage
	for _, name in ipairs(path) do
		inst = inst:FindFirstChild(name)
		if not inst then return nil end
	end
	return inst
end

local function setCutsceneBlocked(blocked)
	if not getconnections then return false, "getconnections is not available in this executor" end
	local remote = resolveCutsceneRemote()
	if not remote or not remote:IsA("RemoteEvent") then
		return false, "Cutscene remote path is unset or not found (CONFIG.STOMP_CUTSCENE_REMOTE_PATH)"
	end
	if blocked then
		for _, conn in ipairs(getconnections(remote.OnClientEvent)) do
			pcall(function() conn:Disable() end)
			disabledConnections[#disabledConnections + 1] = conn
		end
	else
		for _, conn in ipairs(disabledConnections) do
			pcall(function() conn:Enable() end)
		end
		table.clear(disabledConnections)
	end
	return true
end

-- Controller macro ----------------------------------------------------------
local function findTool(name)
	local function search(container)
		if not container then return nil end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child.Name == name then return child end
		end
	end
	return search(LocalPlayer:FindFirstChildOfClass("Backpack")) or search(LocalPlayer.Character)
end

local function listToolNames()
	local names, seen = {}, {}
	local function collect(container)
		if not container then return end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and not seen[child.Name] then
				seen[child.Name] = true
				names[#names + 1] = child.Name
			end
		end
	end
	collect(LocalPlayer:FindFirstChildOfClass("Backpack"))
	collect(LocalPlayer.Character)
	table.sort(names)
	return names
end

local function runMacro(index)
	if state.macroBusy then return end
	state.macroBusy = true
	task.spawn(function()
		pcall(function()
			for _, toolName in ipairs(macros[index].slots) do
				local _, hum = getCharacterParts(LocalPlayer)
				if not hum or hum.Health <= 0 then break end
				if toolName ~= "" then
					local tool = findTool(toolName)
					if tool then
						hum:EquipTool(tool)
						task.wait(CONFIG.EQUIP_DELAY)
						tool:Activate()
						task.wait(CONFIG.ACTIVATE_DELAY)
					end
				end
			end
		end)
		state.macroBusy = false
	end)
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------
local COLORS = {
	bg = Color3.fromRGB(28, 28, 32),
	panel = Color3.fromRGB(40, 40, 46),
	row = Color3.fromRGB(50, 50, 58),
	field = Color3.fromRGB(34, 34, 40),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(160, 160, 170),
	accent = Color3.fromRGB(150, 120, 220),
	good = Color3.fromRGB(120, 200, 130),
	bad = Color3.fromRGB(220, 110, 110),
}

local function make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do inst[k] = v end
	inst.Parent = parent
	return inst
end

local function round(inst, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, inst)
end

local function tween(obj, props)
	if settings.uiAnimations then
		TweenService:Create(obj, TweenInfo.new(0.15), props):Play()
	else
		for k, v in pairs(props) do obj[k] = v end
	end
end

local function label(parent, text, size, pos, opts)
	opts = opts or {}
	return make("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = opts.color or COLORS.text,
		Font = opts.font or Enum.Font.GothamMedium,
		TextSize = opts.textSize or 14,
		TextXAlignment = opts.align or Enum.TextXAlignment.Left,
		TextWrapped = opts.wrap or false,
		Size = size,
		Position = pos or UDim2.new(),
	}, parent)
end

local function button(parent, text, size, pos, onClick, opts)
	opts = opts or {}
	local b = make("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = opts.bg or COLORS.field,
		Text = text,
		TextColor3 = opts.color or COLORS.text,
		Font = Enum.Font.GothamBold,
		TextSize = opts.textSize or 13,
		Size = size,
		Position = pos or UDim2.new(),
	}, parent)
	round(b, 6)
	if onClick then b.MouseButton1Click:Connect(onClick) end
	return b
end

-- Toggle: returns the frame and a setter that does not fire the callback.
local function toggle(parent, initial, onChanged)
	local frame = make("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(0, 44, 0, 22),
		BackgroundColor3 = initial and COLORS.good or COLORS.field,
	}, parent)
	round(frame, 11)
	local knob = make("Frame", {
		Size = UDim2.new(0, 18, 0, 18),
		Position = initial and UDim2.new(1, -20, 0, 2) or UDim2.new(0, 2, 0, 2),
		BackgroundColor3 = COLORS.text,
	}, frame)
	round(knob, 9)
	local value = initial
	local function render()
		tween(frame, { BackgroundColor3 = value and COLORS.good or COLORS.field })
		tween(knob, { Position = value and UDim2.new(1, -20, 0, 2) or UDim2.new(0, 2, 0, 2) })
	end
	frame.MouseButton1Click:Connect(function()
		local accepted = onChanged(not value)
		if accepted ~= false then
			value = not value
			render()
		end
	end)
	local function set(v)
		value = v
		render()
	end
	return frame, set
end

-- ---------------------------------------------------------------------------
-- Build the window
-- ---------------------------------------------------------------------------
local guiParent
do
	local ok, result = pcall(function() return (gethui and gethui()) or game:GetService("CoreGui") end)
	guiParent = ok and result or LocalPlayer:WaitForChild("PlayerGui")
end

local screen = make("ScreenGui", {
	Name = "BaddiesPanel",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
}, guiParent)

local WINDOW_SIZE = UDim2.new(0, 600, 0, 330)
local function centerPosition()
	return UDim2.new(0.5, -300, 0.5, -165)
end

local main = make("Frame", {
	Size = WINDOW_SIZE,
	Position = (settings.posX and settings.posY) and UDim2.new(0, settings.posX, 0, settings.posY) or centerPosition(),
	BackgroundColor3 = COLORS.bg,
	BackgroundTransparency = 0.08,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, screen)
round(main, 12)

-- Header (drag handle) with the local username
local header = make("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, main)
label(header, "@" .. LocalPlayer.Name, UDim2.new(0, 300, 1, 0), UDim2.new(0, 14, 0, 0), { font = Enum.Font.GothamBold, textSize = 15 })

do
	local dragging, dragStart, startPos
	track(header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			settings.posX, settings.posY = main.AbsolutePosition.X, main.AbsolutePosition.Y
			saveData()
		end
	end))
end

-- Sidebar
local sidebar = make("Frame", { Size = UDim2.new(0, 130, 1, -42), Position = UDim2.new(0, 8, 0, 36), BackgroundTransparency = 1 }, main)
make("UIListLayout", { Padding = UDim.new(0, 6) }, sidebar)

-- Content area and right-hand panel
local content = make("Frame", { Size = UDim2.new(0, 330, 1, -64), Position = UDim2.new(0, 146, 0, 36), BackgroundTransparency = 1 }, main)
local statusLabel = label(main, "", UDim2.new(0, 330, 0, 22), UDim2.new(0, 146, 1, -26), { textSize = 12, color = COLORS.dim })

local function notify(text, good)
	statusLabel.Text = text
	statusLabel.TextColor3 = good and COLORS.good or COLORS.bad
end

local playersPanel = make("Frame", { Size = UDim2.new(0, 110, 1, -42), Position = UDim2.new(1, -118, 0, 36), BackgroundColor3 = COLORS.panel }, main)
round(playersPanel, 8)
label(playersPanel, "PLAYERS IN SERVER", UDim2.new(1, -10, 0, 22), UDim2.new(0, 8, 0, 4), { font = Enum.Font.GothamBold, textSize = 11 })
local playersList = make("ScrollingFrame", {
	Size = UDim2.new(1, -8, 1, -30), Position = UDim2.new(0, 4, 0, 26), BackgroundTransparency = 1,
	ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0,
}, playersPanel)
make("UIListLayout", { Padding = UDim.new(0, 2) }, playersList)

local function refreshPlayers()
	for _, child in ipairs(playersList:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		label(playersList, player.Name, UDim2.new(1, -4, 0, 16), nil, { textSize = 11, color = COLORS.dim })
	end
end
refreshPlayers()
track(Players.PlayerAdded:Connect(refreshPlayers))
track(Players.PlayerRemoving:Connect(function() task.defer(refreshPlayers) end))

-- Pages
local pages, tabButtons = {}, {}
local function newPage(name, scrolling)
	local page
	if scrolling then
		page = make("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
		}, content)
		make("UIListLayout", { Padding = UDim.new(0, 6) }, page)
	else
		page = make("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Visible = false }, content)
	end
	pages[name] = page
	return page
end

local function showPage(name)
	for pageName, page in pairs(pages) do
		page.Visible = pageName == name
	end
	for tabName, b in pairs(tabButtons) do
		tween(b, { BackgroundTransparency = tabName == name and 0.3 or 1 })
	end
end

local function addTab(name)
	local b = button(sidebar, name, UDim2.new(1, 0, 0, 34), nil, function() showPage(name) end, { bg = COLORS.panel })
	b.BackgroundTransparency = 1
	b.TextXAlignment = Enum.TextXAlignment.Left
	make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, b)
	tabButtons[name] = b
end

local function row(parent, text, height)
	local r = make("Frame", { Size = UDim2.new(1, -6, 0, height or 38), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.4 }, parent)
	round(r, 8)
	label(r, text, UDim2.new(0.6, 0, 1, 0), UDim2.new(0, 10, 0, 0))
	return r
end

local function section(parent, text)
	return label(parent, text, UDim2.new(1, -6, 0, 24), nil, { font = Enum.Font.GothamBold, textSize = 14, color = COLORS.accent })
end

-- ---------------------------------------------------------------------------
-- Page: Controller Macro
-- ---------------------------------------------------------------------------
local macroPage = newPage("Controller Macro", false)
local currentMacro = 1
local macroTabButtons = {}
local bindButton, slotsHolder

local picker = make("ScrollingFrame", {
	Size = UDim2.new(0, 220, 0, 150), BackgroundColor3 = COLORS.panel, Visible = false, ZIndex = 10,
	ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0,
}, main)
round(picker, 8)
make("UIListLayout", { Padding = UDim.new(0, 2) }, picker)

local refreshSlots

local function openPicker(slotIndex, anchor)
	for _, child in ipairs(picker:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	local function addChoice(text, value)
		local b = button(picker, text, UDim2.new(1, -6, 0, 26), nil, function()
			macros[currentMacro].slots[slotIndex] = value
			picker.Visible = false
			saveData()
			refreshSlots()
		end)
		b.ZIndex = 11
	end
	addChoice("(none)", "")
	for _, name in ipairs(listToolNames()) do addChoice(name, name) end
	local abs, mainAbs = anchor.AbsolutePosition, main.AbsolutePosition
	picker.Position = UDim2.new(0, abs.X - mainAbs.X, 0, abs.Y - mainAbs.Y + anchor.AbsoluteSize.Y)
	picker.Visible = true
end

function refreshSlots()
	for _, child in ipairs(slotsHolder:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	local m = macros[currentMacro]
	for i, toolName in ipairs(m.slots) do
		local r = make("Frame", { Size = UDim2.new(1, -6, 0, 38), BackgroundColor3 = COLORS.row, BackgroundTransparency = 0.4 }, slotsHolder)
		round(r, 8)
		label(r, "Slot " .. i, UDim2.new(0, 60, 1, 0), UDim2.new(0, 10, 0, 0))
		local pick
		pick = button(r, toolName == "" and "Tap to select tool..." or toolName, UDim2.new(1, -84, 0, 26), UDim2.new(0, 74, 0, 6), function()
			openPicker(i, pick)
		end, { color = toolName == "" and COLORS.dim or COLORS.text })
	end
	bindButton.Text = macros[currentMacro].bind ~= "" and macros[currentMacro].bind or "Bind"
	for i, b in ipairs(macroTabButtons) do
		tween(b, { BackgroundColor3 = i == currentMacro and COLORS.accent or COLORS.field })
	end
end

for i = 1, 3 do
	macroTabButtons[i] = button(macroPage, "Macro " .. i, UDim2.new(0, 100, 0, 28), UDim2.new(0, (i - 1) * 106, 0, 0), function()
		currentMacro = i
		state.capturingBind = nil
		picker.Visible = false
		refreshSlots()
	end)
end

bindButton = button(macroPage, "Bind", UDim2.new(0, 120, 0, 28), UDim2.new(0, 0, 0, 34), function()
	state.capturingBind = currentMacro
	bindButton.Text = "Press a button..."
end)
button(macroPage, "+ Add", UDim2.new(0, 90, 0, 28), UDim2.new(0, 126, 0, 34), function()
	local slots = macros[currentMacro].slots
	if #slots < CONFIG.MAX_SLOTS then
		slots[#slots + 1] = ""
		saveData()
		refreshSlots()
	end
end, { color = COLORS.good })
button(macroPage, "- Remove", UDim2.new(0, 90, 0, 28), UDim2.new(0, 222, 0, 34), function()
	local slots = macros[currentMacro].slots
	if #slots > 1 then
		slots[#slots] = nil
		saveData()
		refreshSlots()
	end
end, { color = COLORS.bad })

slotsHolder = make("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -70), Position = UDim2.new(0, 0, 0, 68), BackgroundTransparency = 1,
	BorderSizePixel = 0, ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, macroPage)
make("UIListLayout", { Padding = UDim.new(0, 6) }, slotsHolder)

-- ---------------------------------------------------------------------------
-- Page: Misc
-- ---------------------------------------------------------------------------
local miscPage = newPage("Misc", true)
section(miscPage, "Hitbox / Extender Settings")

local hitboxRow = row(miscPage, "Hitbox Extender")
local hitboxToggle = toggle(hitboxRow, false, function(value)
	state.hitboxEnabled = value
	if not value then restoreHitboxes() end
	return true
end)
hitboxToggle.Position = UDim2.new(1, -54, 0.5, -11)

local sizeRow = row(miscPage, "Hitbox Size")
local sizeBox = make("TextBox", {
	Size = UDim2.new(0, 70, 0, 26), Position = UDim2.new(1, -80, 0.5, -13), BackgroundColor3 = COLORS.field,
	Text = tostring(settings.hitboxSize), TextColor3 = COLORS.text, Font = Enum.Font.GothamBold, TextSize = 13,
	ClearTextOnFocus = false,
}, sizeRow)
round(sizeBox, 6)
sizeBox.FocusLost:Connect(function()
	local n = tonumber(sizeBox.Text)
	if n and n == n and n ~= math.huge and n ~= -math.huge then
		settings.hitboxSize = math.clamp(n, CONFIG.HITBOX_MIN, CONFIG.HITBOX_MAX)
		saveData()
	end
	sizeBox.Text = tostring(settings.hitboxSize)
end)

local stompRow = row(miscPage, "Auto Stomp")
local stompToggle, setStompToggle = toggle(stompRow, false, function(value)
	if value and not CONFIG.DOWNED_ATTRIBUTE then
		notify("Auto Stomp gated: CONFIG.DOWNED_ATTRIBUTE is unknown (see notes).", false)
		return false
	end
	state.autoStomp = value
	return true
end)
stompToggle.Position = UDim2.new(1, -54, 0.5, -11)

-- ---------------------------------------------------------------------------
-- Page: Settings
-- ---------------------------------------------------------------------------
local settingsPage = newPage("Settings", true)
local setAnim, setWatermark

local animRow = row(settingsPage, "UI Animations")
local animToggle
animToggle, setAnim = toggle(animRow, settings.uiAnimations, function(value)
	settings.uiAnimations = value
	saveData()
	return true
end)
animToggle.Position = UDim2.new(1, -54, 0.5, -11)

local watermark = label(screen, "Baddies Panel | press K to hide", UDim2.new(0, 260, 0, 18), UDim2.new(0, 10, 1, -24), { textSize = 12, color = COLORS.dim })
watermark.Visible = settings.watermark

local wmRow = row(settingsPage, "Watermark")
local wmToggle
wmToggle, setWatermark = toggle(wmRow, settings.watermark, function(value)
	settings.watermark = value
	watermark.Visible = value
	saveData()
	return true
end)
wmToggle.Position = UDim2.new(1, -54, 0.5, -11)

section(settingsPage, "Layout")
local posRow = row(settingsPage, "Reset UI Position")
button(posRow, "RESET", UDim2.new(0, 90, 0, 26), UDim2.new(1, -100, 0.5, -13), function()
	main.Position = centerPosition()
	settings.posX, settings.posY = nil, nil
	saveData()
end)
local resetRow = row(settingsPage, "Reset UI Settings")
button(resetRow, "RESET", UDim2.new(0, 90, 0, 26), UDim2.new(1, -100, 0.5, -13), function()
	settings.uiAnimations, settings.watermark, settings.hitboxSize = true, true, 5
	setAnim(true)
	setWatermark(true)
	watermark.Visible = true
	sizeBox.Text = tostring(settings.hitboxSize)
	saveData()
end)

-- ---------------------------------------------------------------------------
-- Page: Extras
-- ---------------------------------------------------------------------------
local extrasPage = newPage("Extras", true)

section(extrasPage, "Music")
local musicRow = row(extrasPage, "Music Gist (preset URL in CONFIG)", 46)
button(musicRow, "LOAD MUSIC", UDim2.new(0, 110, 0, 28), UDim2.new(1, -120, 0.5, -14), function()
	if not CONFIG.MUSIC_GIST_URL then
		notify("Music gated: CONFIG.MUSIC_GIST_URL is unset.", false)
		return
	end
	if not loadstring then
		notify("loadstring is not available in this executor.", false)
		return
	end
	local ok, body = pcall(function() return game:HttpGet(CONFIG.MUSIC_GIST_URL) end)
	if not ok or type(body) ~= "string" or body == "" then
		notify("Could not download the music gist.", false)
		return
	end
	local fn, err = loadstring(body)
	if not fn then
		notify("Music gist failed to compile: " .. tostring(err), false)
		return
	end
	local ran, runErr = pcall(fn)
	notify(ran and "Music loaded." or ("Music script error: " .. tostring(runErr)), ran)
end)

section(extrasPage, "Server")
local rejoinRow = row(extrasPage, "Rejoin Server")
button(rejoinRow, "REJOIN", UDim2.new(0, 90, 0, 26), UDim2.new(1, -100, 0.5, -13), function()
	local ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
	end)
	if not ok then notify("Rejoin failed: " .. tostring(err), false) end
end)

local hopRow = row(extrasPage, "Server Hop")
button(hopRow, "HOP", UDim2.new(0, 90, 0, 26), UDim2.new(1, -100, 0.5, -13), function()
	local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok then notify("Server list request failed.", false) return end
	local decoded
	ok, decoded = pcall(function() return HttpService:JSONDecode(body) end)
	if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
		notify("Unexpected server list response.", false)
		return
	end
	local choices = {}
	for _, server in ipairs(decoded.data) do
		if type(server) == "table" and server.id ~= game.JobId
			and type(server.playing) == "number" and type(server.maxPlayers) == "number"
			and server.playing < server.maxPlayers then
			choices[#choices + 1] = server.id
		end
	end
	if #choices == 0 then notify("No other open server found.", false) return end
	local tpOk, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, choices[math.random(#choices)], LocalPlayer)
	end)
	if not tpOk then notify("Hop failed: " .. tostring(err), false) end
end)

section(extrasPage, "Reset")
local resetCharRow = row(extrasPage, "Force Reset")
button(resetCharRow, "RESET x2", UDim2.new(0, 90, 0, 26), UDim2.new(1, -100, 0.5, -13), function()
	for _ = 1, 2 do
		local char, hum = getCharacterParts(LocalPlayer)
		if char and hum then
			hum.Health = 0
			pcall(function() char:BreakJoints() end)
		end
		task.wait(0.15)
	end
end)

section(extrasPage, "Stomp Cutscene")
local cutsceneRow = row(extrasPage, "Block Stomp Cutscene")
local cutsceneToggle = toggle(cutsceneRow, false, function(value)
	local ok, reason = setCutsceneBlocked(value)
	if not ok then
		notify(reason, false)
		return false
	end
	state.blockCutscene = value
	return true
end)
cutsceneToggle.Position = UDim2.new(1, -54, 0.5, -11)
label(extrasPage, "To turn the finishers back on, toggle this off and rejoin the server/game.",
	UDim2.new(1, -6, 0, 34), nil, { textSize = 12, color = COLORS.dim, wrap = true })

-- ---------------------------------------------------------------------------
-- Page: Credits
-- ---------------------------------------------------------------------------
local creditsPage = newPage("Credits", false)
label(creditsPage, "Baddies Panel\nRebuilt from a screen recording of the original panel.\nEdit this text in the script to credit whoever you like.",
	UDim2.new(1, -10, 0, 80), UDim2.new(0, 6, 0, 6), { wrap = true, color = COLORS.dim })

for _, name in ipairs({ "Controller Macro", "Misc", "Settings", "Extras", "Credits" }) do addTab(name) end

-- Touch-friendly toggle button (the "K" square in the video)
local kButton = button(screen, "K", UDim2.new(0, 44, 0, 44), UDim2.new(1, -60, 0.5, -22), function()
	main.Visible = not main.Visible
end, { bg = COLORS.bg, color = COLORS.accent, textSize = 20 })
kButton.ZIndex = 5

refreshSlots()
showPage("Controller Macro")

-- ---------------------------------------------------------------------------
-- Input and feature loops
-- ---------------------------------------------------------------------------
track(UserInputService.InputBegan:Connect(function(input)
	local code = input.KeyCode
	if code == Enum.KeyCode.Unknown then return end

	if state.capturingBind then
		local isGamepad = input.UserInputType.Name:find("Gamepad") ~= nil
		if isGamepad or input.UserInputType == Enum.UserInputType.Keyboard then
			macros[state.capturingBind].bind = code.Name
			state.capturingBind = nil
			saveData()
			refreshSlots()
		end
		return
	end

	if UserInputService:GetFocusedTextBox() then return end

	if code == CONFIG.TOGGLE_KEY then
		main.Visible = not main.Visible
		return
	end

	for i, m in ipairs(macros) do
		if m.bind ~= "" and m.bind == code.Name then
			runMacro(i)
		end
	end
end))

local accumulator = 0
track(RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < 0.2 then return end
	accumulator = 0

	if state.hitboxEnabled then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= LocalPlayer then
				local _, _, root = getCharacterParts(player)
				if root then applyHitbox(root) end
			end
		end
	end

	if state.autoStomp then autoStompStep() end
end))

-- Single cleanup path
env.BaddiesPanelCleanup = function()
	state.hitboxEnabled, state.autoStomp = false, false
	restoreHitboxes()
	pcall(setCutsceneBlocked, false)
	for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
	table.clear(connections)
	if screen then screen:Destroy() end
end

notify("Loaded. Press K or tap the K button to hide/show.", true)
