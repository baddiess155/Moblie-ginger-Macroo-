-- ChrisMobileMacro.lua
-- Roblox executor script (Luau), rebuilt from your screen recordings and branded "Chris Mobile Macro".
-- Not run in-game by the author: test it and report what breaks.
--
-- Values marked UNKNOWN or UNCALIBRATED in CONFIG are things the recordings do not show.
-- Features that depend on an UNKNOWN value refuse to turn on and say why in the status bar.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer

local BRAND = "CHRIS MOBILE MACRO"
local SAVE_FILE = "ChrisMobileMacro.json"

local CONFIG = {
	STOMP_KEY = Enum.KeyCode.E,          -- read from the HUD labels in your first recording
	STOMP_RANGE = 8,                     -- studs. UNCALIBRATED
	STOMP_COOLDOWN = 0.6,                -- seconds. UNCALIBRATED
	STOMP_HEALTH_FRACTION = 0.2,         -- "low on health" threshold, 0..1. UNCALIBRATED
	AIM_SMOOTHING = 1,                   -- 1 = hard lock, lower = softer pull toward the target. UNCALIBRATED
	HITBOX_MIN = 2,
	HITBOX_MAX = 50,
	COMBO_COUNT = 4,
	MAX_SLOTS = 5,
	SHIFT_LOCK_MIN_HEALTH = 5,           -- from the in-menu text ("5 HP or less")

	SNOWBALL_EVENT_PATH = nil,           -- UNKNOWN: game's snowball remote. "Use Snowball Events" stays gated.
	STOMP_CUTSCENE_REMOTE_PATH = nil,    -- UNKNOWN: path under ReplicatedStorage, e.g. { "Folder", "RemoteName" }
	MUSIC_GIST_URL = nil,                -- UNKNOWN: your raw gist URL
	CARRIED_ATTRIBUTE = nil,             -- UNKNOWN: attribute that marks "carried" so Shift Lock can turn itself off
}

-- ---------------------------------------------------------------------------
-- Single-instance guard and cleanup tracking
-- ---------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if type(env.ChrisMobileMacroCleanup) == "function" then
	pcall(env.ChrisMobileMacroCleanup)
end

local Janitor = { items = {} }
function Janitor.add(item)
	Janitor.items[#Janitor.items + 1] = item
	return item
end
function Janitor.clean()
	for i = #Janitor.items, 1, -1 do
		local item = Janitor.items[i]
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			pcall(function() item:Disconnect() end)
		elseif kind == "Instance" then
			pcall(function() item:Destroy() end)
		elseif kind == "function" then
			pcall(item)
		end
	end
	table.clear(Janitor.items)
end

local UI = {}
local Theme = { hooks = {}, binds = {} }

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do inst[k] = v end
	if parent then inst.Parent = parent end
	return inst
end

-- ---------------------------------------------------------------------------
-- Controller buttons
-- ---------------------------------------------------------------------------
local BUTTONS = {
	{ label = "None", code = "None" },
	{ label = "D-Pad Left", code = "DPadLeft" },
	{ label = "D-Pad Up", code = "DPadUp" },
	{ label = "D-Pad Right", code = "DPadRight" },
	{ label = "D-Pad Down", code = "DPadDown" },
	{ label = "Button A", code = "ButtonA" },
	{ label = "Button B", code = "ButtonB" },
	{ label = "Button X", code = "ButtonX" },
	{ label = "Button Y", code = "ButtonY" },
	{ label = "L1", code = "ButtonL1" },
	{ label = "R1", code = "ButtonR1" },
	{ label = "L2", code = "ButtonL2" },
	{ label = "R2", code = "ButtonR2" },
	{ label = "L3", code = "ButtonL3" },
	{ label = "R3", code = "ButtonR3" },
}
local BUTTON_LABELS = {}
for _, b in ipairs(BUTTONS) do BUTTON_LABELS[#BUTTON_LABELS + 1] = b.label end

local function buttonLabel(code)
	for _, b in ipairs(BUTTONS) do
		if b.code == code then return b.label end
	end
	return nil
end
local function buttonCode(label)
	for _, b in ipairs(BUTTONS) do
		if b.label == label then return b.code end
	end
	return "None"
end

-- ---------------------------------------------------------------------------
-- Store: every setting, combos and the whitelist. Saved to SAVE_FILE when writefile exists.
-- ---------------------------------------------------------------------------
local DEFAULTS = {
	-- Combo settings
	comboHotbarKey = "5",
	actionDelayMs = 10,
	reequipPrevious = false,
	rpgToolName = "RPG", rpgFireMethod = "Click", rpgEquipWaitMs = 150,
	-- Snowball
	useSnowballEvents = false,
	targetPlayers = false, stickyTarget = true, targetHighlight = true,
	prediction = true, projectileSpeed = 200, maxLeadTime = 2, leadStrength = 1, aimAheadOffset = 5,
	snowballFov = 90, targetDistance = 300,
	customFireHeight = false, fireHeightOffset = 0,
	customRocketHeight = false, rocketHeightOffset = 0,
	fovCircle = false,
	-- Combat
	hitboxExtender = false, hitboxSize = 5, hitboxVisualizer = false,
	autoStomp = false, blockStompCutscene = false,
	-- Visuals
	friendEsp = false, whitelistEsp = false, showNames = true, showDistance = true,
	fovChanger = false, fov = 70, stretchRes = false, stretchAmount = 75,
	crosshair = false, crosshairStyle = "Built-in Plus", customCrosshairId = "",
	crosshairSize = 40, crosshairX = 0, crosshairY = 0,
	-- Whitelist
	whitelistFriends = false, whitelistTeammates = false,
	-- Performance
	gfx_shadows = false, gfx_plastic = false, gfx_textures = false, gfx_particles = false,
	gfx_lights = false, gfx_post = false, gfx_mesh = false, gfx_water = false,
	gfx_lighting = false, gfx_quality = false,
	showFps = false, fpsCap = false, fpsCapValue = 120,
	-- Utilities
	antiAfk = true, shiftLock = false, shiftLockButton = "D-Pad Down",
	-- Settings
	theme = "Midnight", toggleKey = "RightShift", uiAnimations = true,
	backgroundImage = false, backgroundImageId = "", backgroundTransparency = 65,
	mobileButtons = UserInputService.TouchEnabled,
	-- Saved positions (-1 = unset)
	winPosX = -1, winPosY = -1, btnPosX = -1, btnPosY = -1, comboPosX = -1, comboPosY = -1,
}

DEFAULTS.repositionMode = false
DEFAULTS.comboButtonScale = 1
DEFAULTS.comboButtonsShown = true
DEFAULTS.clickFireTools = "RPG"
for i = 1, CONFIG.COMBO_COUNT + 3 do
	DEFAULTS["cbx" .. i] = -1
	DEFAULTS["cby" .. i] = -1
end

local Store = { values = {}, subs = {}, combos = {}, whitelist = {}, wlSubs = {}, pending = false }
for k, v in pairs(DEFAULTS) do Store.values[k] = v end
Store.values.repositionMode = false

local function defaultCombos()
	local buttons = { "DPadLeft", "DPadUp", "DPadRight", "None" }
	local combos = {}
	for i = 1, CONFIG.COMBO_COUNT do
		local count = (i == 1) and 5 or 3
		local slots, waits = {}, {}
		for j = 1, count do slots[j] = ""; waits[j] = 0 end
		combos[i] = { button = buttons[i], endClick = true, fireRpg = (i == 1), slots = slots, waits = waits }
	end
	return combos
end
Store.combos = defaultCombos()

function Store.get(key)
	return Store.values[key]
end

function Store.sub(key, fn)
	local list = Store.subs[key]
	if not list then list = {}; Store.subs[key] = list end
	list[#list + 1] = fn
	return function()
		local i = table.find(list, fn)
		if i then table.remove(list, i) end
	end
end

function Store.set(key, value)
	if Store.values[key] == value then return end
	Store.values[key] = value
	local list = Store.subs[key]
	if list then
		for _, fn in ipairs(table.clone(list)) do pcall(fn, value) end
	end
	Store.queueSave()
end

function Store.onWhitelist(fn)
	Store.wlSubs[#Store.wlSubs + 1] = fn
end
function Store.fireWhitelist()
	for _, fn in ipairs(Store.wlSubs) do pcall(fn) end
	Store.queueSave()
end

function Store.queueSave()
	if Store.pending then return end
	Store.pending = true
	task.delay(1, function()
		Store.pending = false
		Store.save()
	end)
end

function Store.save()
	if not writefile then return false end
	local ok = pcall(function()
		writefile(SAVE_FILE, HttpService:JSONEncode({
			values = Store.values, combos = Store.combos, whitelist = Store.whitelist,
		}))
	end)
	return ok
end

-- Reads and validates the save file. Returns nil when there is nothing usable.
function Store.readFile()
	if not (isfile and readfile) then return nil end
	local ok, data = pcall(function()
		if isfile(SAVE_FILE) then return HttpService:JSONDecode(readfile(SAVE_FILE)) end
	end)
	if ok and type(data) == "table" then return data end
	return nil
end

function Store.applyData(data, fire)
	if type(data.values) == "table" then
		for key, default in pairs(DEFAULTS) do
			local v = data.values[key]
			if type(v) == type(default) then
				local fine = true
				if type(v) == "number" then fine = (v == v and math.abs(v) < 1e9) end
				if fine then
					if fire then Store.set(key, v) else Store.values[key] = v end
				end
			end
		end
	end
	if type(data.combos) == "table" then
		for i = 1, CONFIG.COMBO_COUNT do
			local c, combo = data.combos[i], Store.combos[i]
			if type(c) == "table" then
				if type(c.button) == "string" and buttonLabel(c.button) then combo.button = c.button end
				if type(c.endClick) == "boolean" then combo.endClick = c.endClick end
				if type(c.fireRpg) == "boolean" then combo.fireRpg = c.fireRpg end
				if type(c.slots) == "table" then
					local slots, waits = {}, {}
					for j = 1, math.min(#c.slots, CONFIG.MAX_SLOTS) do
						slots[j] = type(c.slots[j]) == "string" and c.slots[j] or ""
						local w = type(c.waits) == "table" and c.waits[j] or nil
						waits[j] = (type(w) == "number" and w == w and w >= 0 and w <= 2) and w or 0
					end
					if #slots >= 1 then combo.slots, combo.waits = slots, waits end
				end
			end
		end
	end
	if type(data.whitelist) == "table" then
		Store.whitelist = {}
		for id, name in pairs(data.whitelist) do
			if type(id) == "string" and type(name) == "string" then Store.whitelist[id] = name end
		end
	end
end

do
	local data = Store.readFile()
	if data then Store.applyData(data, false) end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local Util = { friendCache = {} }

function Util.finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function Util.parts(player)
	local char = player.Character
	if not char then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not root:IsA("BasePart") then return nil end
	return char, hum, root
end

function Util.refreshFriend(player)
	task.spawn(function()
		local ok, result = pcall(function() return LocalPlayer:IsFriendsWith(player.UserId) end)
		Util.friendCache[player.UserId] = ok and result == true
	end)
end

function Util.isFriend(player)
	return Util.friendCache[player.UserId] == true
end

function Util.isWhitelisted(player)
	if Store.whitelist[tostring(player.UserId)] then return true end
	if Store.get("whitelistFriends") and Util.isFriend(player) then return true end
	if Store.get("whitelistTeammates") and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then return true end
	return false
end

function Util.findPlayer(text)
	text = string.lower(text or "")
	if text == "" then return nil end
	local prefixMatch
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local n, d = string.lower(player.Name), string.lower(player.DisplayName)
			if n == text or d == text then return player end
			if not prefixMatch and (string.sub(n, 1, #text) == text or string.sub(d, 1, #text) == text) then
				prefixMatch = player
			end
		end
	end
	return prefixMatch
end

function Util.delaySeconds()
	return math.max(Store.get("actionDelayMs"), 0) / 1000
end

function Util.resolvePath(root, path)
	if type(path) ~= "table" or #path == 0 then return nil end
	local inst = root
	for _, name in ipairs(path) do
		inst = inst:FindFirstChild(name)
		if not inst then return nil end
	end
	return inst
end

function UI.notify(text, good)
	if UI.status then
		UI.status.Text = text
		UI.status.TextColor3 = good and Theme.current.good or Theme.current.bad
		UI.statusToken = (UI.statusToken or 0) + 1
		local token = UI.statusToken
		task.delay(5, function()
			if UI.statusToken == token and UI.status then UI.status.Text = "" end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Combo engine
-- ---------------------------------------------------------------------------
local Macro = { busy = false }
local HOTBAR_KEYS = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five,
	Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
}

function Macro.findTool(name)
	local function search(container)
		if not container then return nil end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child.Name == name then return child end
		end
		return nil
	end
	return search(LocalPlayer:FindFirstChildOfClass("Backpack")) or search(LocalPlayer.Character)
end

function Macro.toolNames()
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

function Macro.tap(key)
	VirtualInputManager:SendKeyEvent(true, key, false, game)
	task.wait(0.03)
	VirtualInputManager:SendKeyEvent(false, key, false, game)
end

function Macro.click(hold)
	local camera = workspace.CurrentCamera
	if not camera then return end
	local size = camera.ViewportSize
	VirtualInputManager:SendMouseButtonEvent(size.X / 2, size.Y / 2, 0, true, game, 1)
	task.wait(hold or 0.03)
	VirtualInputManager:SendMouseButtonEvent(size.X / 2, size.Y / 2, 0, false, game, 1)
end

function Macro.usesClick(toolName)
	local lname = string.lower(toolName)
	for entry in string.gmatch(string.lower(tostring(Store.get("clickFireTools") or "")), "[^,]+") do
		entry = string.match(entry, "^%s*(.-)%s*$")
		if entry ~= "" and string.find(lname, entry, 1, true) then return true end
	end
	return false
end

function Macro.findToolMatching(word)
	word = string.lower(tostring(word or ""))
	if word == "" then return nil end
	local function search(container)
		if not container then return nil end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and string.find(string.lower(child.Name), word, 1, true) then return child end
		end
		return nil
	end
	return search(LocalPlayer:FindFirstChildOfClass("Backpack")) or search(LocalPlayer.Character)
end

function Macro.fireRpg()
	local _, hum = Util.parts(LocalPlayer)
	if not hum or hum.Health <= 0 then return end
	local name = Store.get("rpgToolName")
	local tool = Macro.findToolMatching(name)
	if not tool then
		UI.notify("RPG not found: no tool name contains '" .. tostring(name) .. "'.", false)
		return
	end
	if tool.Parent ~= hum.Parent then hum:EquipTool(tool) end
	task.wait(math.max(Store.get("rpgEquipWaitMs"), 0) / 1000)
	local method = Store.get("rpgFireMethod")
	if method == "Click" or method == "Both" then Macro.click(0.06) end
	if method == "Activate" or method == "Both" then tool:Activate() end
end

function Macro.runOne(index)
	local combo = Store.combos[index]
	local _, startHum = Util.parts(LocalPlayer)
	local previousTool = startHum and startHum.Parent and startHum.Parent:FindFirstChildOfClass("Tool")
	for slotIndex, toolName in ipairs(combo.slots) do
		local _, hum = Util.parts(LocalPlayer)
		if not hum or hum.Health <= 0 then return end
		if toolName ~= "" then
			local tool = Macro.findTool(toolName)
			if tool then
				hum:EquipTool(tool)
				local slotWait = combo.waits[slotIndex]
				task.wait((slotWait and slotWait > 0) and slotWait or Util.delaySeconds())
				if Macro.usesClick(toolName) then Macro.click() else tool:Activate() end
				task.wait(Util.delaySeconds())
			end
		end
	end
	if combo.fireRpg then
		Macro.fireRpg()
	elseif combo.endClick then
		local n = tonumber(Store.get("comboHotbarKey")) or 5
		local key = HOTBAR_KEYS[math.clamp(math.floor(n), 1, 9)]
		Macro.tap(key)
		task.wait(Util.delaySeconds())
		Macro.click()
	end
	if Store.get("reequipPrevious") and previousTool and previousTool.Parent then
		local _, hum = Util.parts(LocalPlayer)
		if hum and hum.Health > 0 and previousTool.Parent ~= hum.Parent then
			hum:EquipTool(previousTool)
		end
	end
end

function Macro.runMany(indices)
	if Macro.busy then return end
	Macro.busy = true
	task.spawn(function()
		for _, index in ipairs(indices) do
			pcall(Macro.runOne, index)
		end
		Macro.busy = false
	end)
end

function Macro.run(index)
	Macro.runMany({ index })
end

function Macro.runAll()
	local indices = {}
	for i, combo in ipairs(Store.combos) do
		local used = combo.fireRpg == true
		for _, toolName in ipairs(combo.slots) do
			if toolName ~= "" then used = true; break end
		end
		if used then indices[#indices + 1] = i end
	end
	if #indices > 0 then Macro.runMany(indices) end
end

-- ---------------------------------------------------------------------------
-- Hitbox extender + visualizer
-- ---------------------------------------------------------------------------
local Hitbox = {
	originals = setmetatable({}, { __mode = "k" }),
	vis = setmetatable({}, { __mode = "k" }),
}

function Hitbox.destroyVis(root)
	local it = Hitbox.vis[root]
	if it then
		for _, inst in pairs(it) do pcall(function() inst:Destroy() end) end
		Hitbox.vis[root] = nil
	end
end

function Hitbox.ensureVis(root)
	local it = Hitbox.vis[root]
	if it and it.box.Parent then return it end
	Hitbox.destroyVis(root)
	it = {}
	it.box = new("BoxHandleAdornment", {
		Adornee = root, Size = root.Size, Color3 = Color3.fromRGB(120, 200, 255),
		Transparency = 0.65, AlwaysOnTop = true, ZIndex = 1,
	}, root)
	it.outline = new("SelectionBox", {
		Adornee = root, Color3 = Color3.fromRGB(150, 20, 30), LineThickness = 0.04,
	}, root)
	it.scan = new("BoxHandleAdornment", {
		Adornee = root, Size = Vector3.new(root.Size.X, 0.15, root.Size.Z),
		Color3 = Color3.fromRGB(255, 255, 255), Transparency = 0.25, AlwaysOnTop = true, ZIndex = 2,
	}, root)
	Hitbox.vis[root] = it
	return it
end

function Hitbox.restore(root)
	local orig = Hitbox.originals[root]
	if orig and root.Parent then
		root.Size, root.Transparency, root.CanCollide = orig.Size, orig.Transparency, orig.CanCollide
	end
	Hitbox.originals[root] = nil
	Hitbox.destroyVis(root)
end

function Hitbox.restoreAll()
	for root in pairs(Hitbox.originals) do Hitbox.restore(root) end
	for root in pairs(Hitbox.vis) do Hitbox.destroyVis(root) end
end

function Hitbox.apply(root)
	if not Hitbox.originals[root] then
		Hitbox.originals[root] = { Size = root.Size, Transparency = root.Transparency, CanCollide = root.CanCollide }
	end
	local s = Store.get("hitboxSize")
	root.Size = Vector3.new(s, s, s)
	root.Transparency = Store.get("hitboxVisualizer") and 1 or 0.7
	root.CanCollide = false
end

function Hitbox.step()
	if not Store.get("hitboxExtender") then return end
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local _, _, root = Util.parts(player)
			if root then
				if Util.isWhitelisted(player) then
					Hitbox.restore(root)
				else
					Hitbox.apply(root)
					if Store.get("hitboxVisualizer") then Hitbox.ensureVis(root) else Hitbox.destroyVis(root) end
				end
			end
		end
	end
end

function Hitbox.animate()
	local t = os.clock()
	for root, it in pairs(Hitbox.vis) do
		if root.Parent and it.box.Parent then
			it.box.Size = root.Size
			it.scan.Size = Vector3.new(root.Size.X, 0.15, root.Size.Z)
			it.scan.CFrame = CFrame.new(0, (root.Size.Y / 2) * math.sin(t * 2.2), 0)
			it.outline.Transparency = 0.3 + 0.3 * math.sin(t * 4)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Auto stomp and stomp cutscene block
-- ---------------------------------------------------------------------------
local Stomp = { last = 0, disabled = {} }

function Stomp.step()
	if not Store.get("autoStomp") then return end
	local now = os.clock()
	if now - Stomp.last < CONFIG.STOMP_COOLDOWN then return end
	local _, myHum, myRoot = Util.parts(LocalPlayer)
	if not myHum or myHum.Health <= 0 then return end
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and not Util.isWhitelisted(player) then
			local _, hum, root = Util.parts(player)
			if hum and hum.MaxHealth > 0 and hum.Health > 0
				and hum.Health / hum.MaxHealth <= CONFIG.STOMP_HEALTH_FRACTION then
				local d = (root.Position - myRoot.Position).Magnitude
				if d == d and d <= CONFIG.STOMP_RANGE then
					Stomp.last = now
					task.spawn(Macro.tap, CONFIG.STOMP_KEY)
					return
				end
			end
		end
	end
end

function Stomp.gate()
	if not getconnections then return "Gated: this executor has no getconnections." end
	local remote = Util.resolvePath(ReplicatedStorage, CONFIG.STOMP_CUTSCENE_REMOTE_PATH)
	if not remote or not remote:IsA("RemoteEvent") then
		return "Gated: the stomp cutscene remote is unknown (set CONFIG.STOMP_CUTSCENE_REMOTE_PATH)."
	end
	return nil
end

function Stomp.setBlocked(blocked)
	if Stomp.gate() then return end
	local remote = Util.resolvePath(ReplicatedStorage, CONFIG.STOMP_CUTSCENE_REMOTE_PATH)
	if blocked then
		for _, conn in ipairs(getconnections(remote.OnClientEvent)) do
			pcall(function() conn:Disable() end)
			Stomp.disabled[#Stomp.disabled + 1] = conn
		end
	else
		for _, conn in ipairs(Stomp.disabled) do pcall(function() conn:Enable() end) end
		table.clear(Stomp.disabled)
	end
end

-- ---------------------------------------------------------------------------
-- Snowball targeting (Target Players). Aims the camera at the chosen player.
-- ---------------------------------------------------------------------------
local Target = { current = nil, highlight = nil }

function Target.clearHighlight()
	if Target.highlight then
		Target.highlight:Destroy()
		Target.highlight = nil
	end
end

function Target.visible(camera, char, root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local origin = camera.CFrame.Position
	local result = workspace:Raycast(origin, root.Position - origin, params)
	return result == nil or result.Instance:IsDescendantOf(char)
end

function Target.angleTo(camera, position)
	local dir = position - camera.CFrame.Position
	if dir.Magnitude < 0.001 then return math.pi end
	local dot = math.clamp(camera.CFrame.LookVector:Dot(dir.Unit), -1, 1)
	return math.acos(dot)
end

function Target.valid(camera, player, myRoot)
	if not player or not player.Parent or Util.isWhitelisted(player) then return false end
	local char, hum, root = Util.parts(player)
	if not char or hum.Health <= 0 then return false end
	local dist = (root.Position - myRoot.Position).Magnitude
	if not Util.finite(dist) or dist > Store.get("targetDistance") then return false end
	if Target.angleTo(camera, root.Position) > math.rad(Store.get("snowballFov")) / 2 then return false end
	return Target.visible(camera, char, root)
end

function Target.pick(camera, myRoot)
	if Store.get("stickyTarget") and Target.valid(camera, Target.current, myRoot) then
		return Target.current
	end
	local best, bestAngle = nil, math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and Target.valid(camera, player, myRoot) then
			local _, _, root = Util.parts(player)
			local a = Target.angleTo(camera, root.Position)
			if a < bestAngle then best, bestAngle = player, a end
		end
	end
	return best
end

function Target.aimPoint(camera, root)
	local pos = root.Position
	if Store.get("prediction") then
		local vel = root.AssemblyLinearVelocity
		local dist = (pos - camera.CFrame.Position).Magnitude
		local speed = math.max(Store.get("projectileSpeed"), 1)
		local t = math.min(dist / speed, Store.get("maxLeadTime"))
		local strength = Store.get("leadStrength")
		pos = pos + vel * t * strength
		if vel.Magnitude > 1 then
			pos = pos + vel.Unit * Store.get("aimAheadOffset") * strength
		end
	end
	return pos
end

function Target.setHighlight(player)
	if not player or not Store.get("targetHighlight") then
		Target.clearHighlight()
		return
	end
	local char = player.Character
	if not char then Target.clearHighlight() return end
	if Target.highlight and Target.highlight.Adornee == char then return end
	Target.clearHighlight()
	Target.highlight = new("Highlight", {
		Name = HttpService:GenerateGUID(false), Adornee = char,
		FillColor = Color3.fromRGB(255, 90, 110), FillTransparency = 0.65,
		OutlineColor = Color3.fromRGB(255, 255, 255),
		DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
	}, char)
end

function Target.step()
	if not Store.get("targetPlayers") then
		if Target.current then Target.current = nil; Target.clearHighlight() end
		return
	end
	local camera = workspace.CurrentCamera
	if not camera or UserInputService:GetFocusedTextBox() then return end
	local _, myHum, myRoot = Util.parts(LocalPlayer)
	if not myHum or myHum.Health <= 0 then Target.setHighlight(nil) return end
	local player = Target.pick(camera, myRoot)
	Target.current = player
	Target.setHighlight(player)
	if player then
		local _, _, root = Util.parts(player)
		if root then
			local goal = CFrame.lookAt(camera.CFrame.Position, Target.aimPoint(camera, root))
			camera.CFrame = camera.CFrame:Lerp(goal, CONFIG.AIM_SMOOTHING)
		end
	end
end

-- ---------------------------------------------------------------------------
-- ESP (friends / whitelisted players) with name and distance tags
-- ---------------------------------------------------------------------------
local Esp = { objects = {} }

function Esp.remove(player)
	local o = Esp.objects[player]
	if o then
		if o.highlight then o.highlight:Destroy() end
		if o.tag then o.tag:Destroy() end
		Esp.objects[player] = nil
	end
end

function Esp.clear()
	for player in pairs(Esp.objects) do Esp.remove(player) end
end

function Esp.step()
	local friendOn, whitelistOn = Store.get("friendEsp"), Store.get("whitelistEsp")
	if not friendOn and not whitelistOn then
		if next(Esp.objects) then Esp.clear() end
		return
	end
	local camera = workspace.CurrentCamera
	local _, _, myRoot = Util.parts(LocalPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local char, _, root = Util.parts(player)
			local color
			if char then
				if whitelistOn and Util.isWhitelisted(player) then color = Color3.fromRGB(80, 220, 130)
				elseif friendOn and Util.isFriend(player) then color = Color3.fromRGB(80, 160, 255) end
			end
			if not color then
				Esp.remove(player)
			else
				local o = Esp.objects[player]
				if not o or o.char ~= char or not o.highlight.Parent then
					Esp.remove(player)
					o = { char = char }
					o.highlight = new("Highlight", {
						Name = HttpService:GenerateGUID(false), Adornee = char, FillColor = color,
						FillTransparency = 0.7, OutlineColor = color,
						DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
					}, char)
					o.tag = new("BillboardGui", {
						Name = HttpService:GenerateGUID(false), Adornee = char:FindFirstChild("Head") or root,
						Size = UDim2.fromOffset(180, 30), StudsOffset = Vector3.new(0, 3, 0), AlwaysOnTop = true,
					}, char)
					o.label = new("TextLabel", {
						BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBold,
						TextSize = 14, TextStrokeTransparency = 0.4, TextColor3 = color,
					}, o.tag)
					Esp.objects[player] = o
				end
				o.highlight.FillColor, o.highlight.OutlineColor, o.label.TextColor3 = color, color, color
				local parts = {}
				if Store.get("showNames") then parts[#parts + 1] = player.DisplayName end
				if Store.get("showDistance") and myRoot and camera then
					parts[#parts + 1] = string.format("[%d]", math.floor((root.Position - myRoot.Position).Magnitude))
				end
				o.tag.Enabled = #parts > 0
				o.label.Text = table.concat(parts, " ")
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Camera effects (FOV changer, stretch resolution)
-- ---------------------------------------------------------------------------
local CameraFx = {}

function CameraFx.fovStep()
	local camera = workspace.CurrentCamera
	if camera and Store.get("fovChanger") then
		camera.FieldOfView = math.clamp(Store.get("fov"), 20, 120)
	end
end

function CameraFx.stretchStep()
	local camera = workspace.CurrentCamera
	if camera and Store.get("stretchRes") then
		local y = math.clamp(Store.get("stretchAmount"), 30, 100) / 100
		camera.CFrame = camera.CFrame * CFrame.new(0, 0, 0, 1, 0, 0, 0, y, 0, 0, 0, 1)
	end
end

function CameraFx.refresh()
	local camera = workspace.CurrentCamera
	local _, hum = Util.parts(LocalPlayer)
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		if hum then camera.CameraSubject = hum end
	end
end

-- ---------------------------------------------------------------------------
-- Performance: reversible graphics options
-- ---------------------------------------------------------------------------
local Gfx = { saved = {}, active = {} }
local GFX_KEYS = { "shadows", "plastic", "textures", "particles", "lights", "post", "mesh", "water", "lighting", "quality" }
for _, key in ipairs(GFX_KEYS) do Gfx.saved[key] = setmetatable({}, { __mode = "k" }) end

local function remember(opt, inst, prop, value)
	local bucket = Gfx.saved[opt]
	local props = bucket[inst]
	if not props then props = {}; bucket[inst] = props end
	if props[prop] == nil then props[prop] = inst[prop] end
	inst[prop] = value
end

local INSTANCE_RULES = {
	shadows = function(i)
		if i:IsA("BasePart") then remember("shadows", i, "CastShadow", false) end
	end,
	plastic = function(i)
		if i:IsA("BasePart") and not i:IsA("Terrain") then remember("plastic", i, "Material", Enum.Material.Plastic) end
	end,
	textures = function(i)
		if i:IsA("Decal") or i:IsA("Texture") then remember("textures", i, "Transparency", 1) end
	end,
	particles = function(i)
		if i:IsA("ParticleEmitter") or i:IsA("Trail") or i:IsA("Beam") or i:IsA("Smoke")
			or i:IsA("Fire") or i:IsA("Sparkles") then
			remember("particles", i, "Enabled", false)
		end
	end,
	lights = function(i)
		if i:IsA("PointLight") or i:IsA("SpotLight") or i:IsA("SurfaceLight") then
			remember("lights", i, "Enabled", false)
		end
	end,
	post = function(i)
		if i:IsA("PostEffect") then remember("post", i, "Enabled", false)
		elseif i:IsA("Atmosphere") then remember("post", i, "Density", 0) end
	end,
	mesh = function(i)
		if i:IsA("MeshPart") or i:IsA("PartOperation") then
			remember("mesh", i, "RenderFidelity", Enum.RenderFidelity.Performance)
		end
	end,
}

local GLOBAL_RULES = {
	shadows = function() remember("shadows", Lighting, "GlobalShadows", false) end,
	water = function()
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		if terrain then
			remember("water", terrain, "WaterWaveSize", 0)
			remember("water", terrain, "WaterWaveSpeed", 0)
			remember("water", terrain, "WaterReflectance", 0)
			remember("water", terrain, "WaterTransparency", 1)
		end
	end,
	lighting = function()
		remember("lighting", Lighting, "EnvironmentDiffuseScale", 0)
		remember("lighting", Lighting, "EnvironmentSpecularScale", 0)
		remember("lighting", Lighting, "ShadowSoftness", 0)
	end,
	quality = function()
		remember("quality", settings().Rendering, "QualityLevel", Enum.QualityLevel.Level01)
	end,
}

function Gfx.restore(opt)
	for inst, props in pairs(Gfx.saved[opt]) do
		for prop, value in pairs(props) do
			pcall(function() inst[prop] = value end)
		end
		Gfx.saved[opt][inst] = nil
	end
end

function Gfx.set(opt, on)
	Gfx.active[opt] = on or nil
	if not on then
		Gfx.restore(opt)
		return
	end
	task.spawn(function()
		if GLOBAL_RULES[opt] then pcall(GLOBAL_RULES[opt]) end
		local rule = INSTANCE_RULES[opt]
		if not rule then return end
		local count = 0
		for _, root in ipairs({ workspace, Lighting }) do
			for _, inst in ipairs(root:GetDescendants()) do
				if not Gfx.active[opt] then return end
				pcall(rule, inst)
				count += 1
				if count % 300 == 0 then task.wait() end
			end
		end
	end)
end

function Gfx.restoreAll()
	for _, key in ipairs(GFX_KEYS) do
		Gfx.active[key] = nil
		Gfx.restore(key)
	end
end

function Gfx.init()
	for _, key in ipairs(GFX_KEYS) do
		local storeKey = "gfx_" .. key
		Janitor.add(Store.sub(storeKey, function(v) Gfx.set(key, v) end))
		if Store.get(storeKey) then Gfx.set(key, true) end
	end
	Janitor.add(workspace.DescendantAdded:Connect(function(inst)
		for opt in pairs(Gfx.active) do
			local rule = INSTANCE_RULES[opt]
			if rule then pcall(rule, inst) end
		end
	end))
end

function Gfx.setAll(on)
	for _, key in ipairs(GFX_KEYS) do Store.set("gfx_" .. key, on) end
end

-- ---------------------------------------------------------------------------
-- Utilities: FPS, anti-AFK, shift lock, server tools, music
-- ---------------------------------------------------------------------------
local Misc = { fpsFrames = 0, fpsTimer = 0, shiftWasLocked = false }

function Misc.fpsStep(dt)
	if not Store.get("showFps") or not UI.fpsLabel then return end
	Misc.fpsFrames += 1
	Misc.fpsTimer += dt
	if Misc.fpsTimer >= 0.5 then
		UI.fpsLabel.Text = string.format("FPS %d", math.floor(Misc.fpsFrames / Misc.fpsTimer + 0.5))
		Misc.fpsFrames, Misc.fpsTimer = 0, 0
	end
end

function Misc.applyFpsCap()
	if not setfpscap then return false end
	pcall(setfpscap, Store.get("fpsCap") and math.clamp(Store.get("fpsCapValue"), 10, 999) or 0)
	return true
end

function Misc.initAntiAfk()
	Janitor.add(LocalPlayer.Idled:Connect(function()
		if not Store.get("antiAfk") then return end
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end))
end

local BLOCKED_STATES = {
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Flying] = true,
	[Enum.HumanoidStateType.Seated] = true,
}

function Misc.shiftLockStep()
	local camera = workspace.CurrentCamera
	local char, hum, root = Util.parts(LocalPlayer)
	if not camera or not hum then return end
	local carried = CONFIG.CARRIED_ATTRIBUTE and char:GetAttribute(CONFIG.CARRIED_ATTRIBUTE) == true
	local allowed = Store.get("shiftLock") and hum.Health > CONFIG.SHIFT_LOCK_MIN_HEALTH
		and not hum.Sit and not hum.PlatformStand and not BLOCKED_STATES[hum:GetState()] and not carried
	if allowed then
		hum.AutoRotate = false
		Misc.shiftWasLocked = true
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.001 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
		end
	elseif Misc.shiftWasLocked then
		hum.AutoRotate = true
		Misc.shiftWasLocked = false
	end
end

function Misc.rejoin()
	local ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
	end)
	if not ok then UI.notify("Rejoin failed: " .. tostring(err), false) end
end

function Misc.serverHop()
	local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok then UI.notify("Server list request failed.", false) return end
	local decoded
	ok, decoded = pcall(function() return HttpService:JSONDecode(body) end)
	if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
		UI.notify("Unexpected server list response.", false)
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
	if #choices == 0 then UI.notify("No other open server found.", false) return end
	local tpOk, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, choices[math.random(#choices)], LocalPlayer)
	end)
	if not tpOk then UI.notify("Hop failed: " .. tostring(err), false) end
end

function Misc.loadMusic()
	if not CONFIG.MUSIC_GIST_URL then UI.notify("Music gated: CONFIG.MUSIC_GIST_URL is unset.", false) return end
	if not loadstring then UI.notify("loadstring is not available in this executor.", false) return end
	local ok, body = pcall(function() return game:HttpGet(CONFIG.MUSIC_GIST_URL) end)
	if not ok or type(body) ~= "string" or body == "" then UI.notify("Could not download the music gist.", false) return end
	local fn, err = loadstring(body)
	if not fn then UI.notify("Music gist failed to compile: " .. tostring(err), false) return end
	local ran, runErr = pcall(fn)
	UI.notify(ran and "Music loaded." or ("Music script error: " .. tostring(runErr)), ran)
end

-- ---------------------------------------------------------------------------
-- Themes
-- ---------------------------------------------------------------------------
local THEMES = {
	Midnight = {
		bg = Color3.fromRGB(13, 14, 21), side = Color3.fromRGB(18, 20, 30), card = Color3.fromRGB(25, 27, 40),
		divider = Color3.fromRGB(34, 37, 54), text = Color3.fromRGB(236, 238, 248), dim = Color3.fromRGB(148, 154, 178),
		accent = Color3.fromRGB(124, 131, 255), accent2 = Color3.fromRGB(96, 210, 255), off = Color3.fromRGB(58, 62, 86),
		good = Color3.fromRGB(110, 220, 150), bad = Color3.fromRGB(240, 110, 120),
	},
	Ocean = {
		bg = Color3.fromRGB(10, 18, 26), side = Color3.fromRGB(14, 25, 36), card = Color3.fromRGB(20, 35, 50),
		divider = Color3.fromRGB(29, 48, 66), text = Color3.fromRGB(232, 244, 252), dim = Color3.fromRGB(136, 164, 184),
		accent = Color3.fromRGB(56, 189, 248), accent2 = Color3.fromRGB(45, 212, 191), off = Color3.fromRGB(50, 72, 92),
		good = Color3.fromRGB(110, 225, 160), bad = Color3.fromRGB(245, 120, 120),
	},
	Rose = {
		bg = Color3.fromRGB(21, 12, 18), side = Color3.fromRGB(30, 17, 26), card = Color3.fromRGB(42, 24, 36),
		divider = Color3.fromRGB(58, 34, 50), text = Color3.fromRGB(252, 236, 244), dim = Color3.fromRGB(190, 150, 172),
		accent = Color3.fromRGB(244, 114, 182), accent2 = Color3.fromRGB(251, 146, 120), off = Color3.fromRGB(90, 58, 78),
		good = Color3.fromRGB(120, 225, 160), bad = Color3.fromRGB(255, 120, 120),
	},
	Emerald = {
		bg = Color3.fromRGB(10, 20, 16), side = Color3.fromRGB(14, 28, 22), card = Color3.fromRGB(20, 40, 32),
		divider = Color3.fromRGB(29, 56, 45), text = Color3.fromRGB(232, 252, 242), dim = Color3.fromRGB(138, 182, 160),
		accent = Color3.fromRGB(52, 211, 153), accent2 = Color3.fromRGB(163, 230, 53), off = Color3.fromRGB(48, 84, 68),
		good = Color3.fromRGB(130, 235, 160), bad = Color3.fromRGB(245, 120, 120),
	},
}
local THEME_NAMES = { "Midnight", "Ocean", "Rose", "Emerald" }
Theme.current = THEMES[Store.get("theme")] or THEMES.Midnight

function Theme.bind(inst, prop, key)
	inst[prop] = Theme.current[key]
	Theme.binds[#Theme.binds + 1] = { inst, prop, key }
end

function Theme.apply(name)
	Theme.current = THEMES[name] or THEMES.Midnight
	local alive = {}
	for _, b in ipairs(Theme.binds) do
		if UI.screen and b[1]:IsDescendantOf(UI.screen) then
			b[1][b[2]] = Theme.current[b[3]]
			alive[#alive + 1] = b
		end
	end
	Theme.binds = alive
	local hooks = {}
	for _, fn in ipairs(Theme.hooks) do
		local keep = fn()
		if keep ~= false then hooks[#hooks + 1] = fn end
	end
	Theme.hooks = hooks
end

-- ---------------------------------------------------------------------------
-- UI framework
-- ---------------------------------------------------------------------------
UI.registry = {}
UI.pages = {}
UI.tabButtons = {}
UI.keyCapture = nil

local function corner(inst, radius)
	new("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, inst)
end

local function stroke(inst, key, thickness, transparency)
	local s = new("UIStroke", {
		Thickness = thickness or 1, Transparency = transparency or 0.55,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
	Theme.bind(s, "Color", key or "divider")
	return s
end

local function label(parent, text, props)
	props = props or {}
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Text = text, Font = props.font or Enum.Font.GothamMedium,
		TextSize = props.size or 14, TextXAlignment = props.align or Enum.TextXAlignment.Left,
		TextWrapped = props.wrap or false, Size = props.sizeUdim or UDim2.new(1, 0, 0, 0),
		Position = props.position or UDim2.new(), AutomaticSize = props.auto,
	}, parent)
	Theme.bind(l, "TextColor3", props.colorKey or "text")
	return l
end

function UI.tween(obj, props)
	if Store.get("uiAnimations") then
		TweenService:Create(obj, TweenInfo.new(0.16, Enum.EasingStyle.Quad), props):Play()
	else
		for k, v in pairs(props) do obj[k] = v end
	end
end

function UI.lockScroll(locked)
	for _, page in pairs(UI.pages) do page.ScrollingEnabled = not locked end
end

function UI.makeDraggable(handle, target, onDone, onTap, canMove)
	local dragging, activeInput, dragStart, startPos, moved = false, nil, nil, nil, 0
	Janitor.add(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, activeInput, dragStart, startPos, moved = true, input, input.Position, target.Position, 0
		end
	end))
	Janitor.add(UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		local isMove = input.UserInputType == Enum.UserInputType.MouseMovement
		if isMove or input == activeInput then
			local d = input.Position - dragStart
			moved = math.max(moved, d.Magnitude)
			if moved >= 8 and (canMove == nil or canMove()) then
				target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end
	end))
	Janitor.add(UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input == activeInput) then
			dragging = false
			if moved < 8 then
				if onTap then onTap() end
			elseif canMove == nil or canMove() then
				local camera = workspace.CurrentCamera
				local x, y = target.AbsolutePosition.X, target.AbsolutePosition.Y
				if camera then
					x = math.clamp(x, 0, math.max(0, camera.ViewportSize.X - target.AbsoluteSize.X))
					y = math.clamp(y, 0, math.max(0, camera.ViewportSize.Y - target.AbsoluteSize.Y))
				end
				target.Position = UDim2.fromOffset(x, y)
				if onDone then onDone(x, y) end
			end
		end
	end))
end

-- Rows -----------------------------------------------------------------------
function UI.rowBase(parent, title, desc, controlWidth)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0,
	}, parent)
	Theme.bind(row, "BackgroundColor3", "card")
	new("UISizeConstraint", { MinSize = Vector2.new(0, 52) }, row)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
	}, row)
	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -((controlWidth or 0) + 12), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, row)
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
	local titleLabel = label(holder, title or "", { font = Enum.Font.GothamBold, size = 14, wrap = true, auto = Enum.AutomaticSize.Y })
	local descLabel
	if desc and desc ~= "" then
		descLabel = label(holder, desc, { size = 12, wrap = true, auto = Enum.AutomaticSize.Y, colorKey = "dim" })
	end
	return row, titleLabel, descLabel
end

function UI.access(spec)
	if spec.key then
		local key = spec.key
		return function() return Store.get(key) end,
			function(v) Store.set(key, v) end,
			function(fn) return Store.sub(key, fn) end
	end
	return spec.get, spec.set, spec.sub or function() return function() end end
end

local function onRowDestroyed(row, fn)
	row.Destroying:Connect(fn)
end

function UI.addToggle(parent, spec)
	local row = UI.rowBase(parent, spec.title, spec.desc, 50)
	local get, set, sub = UI.access(spec)
	local track = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(46, 24),
		Text = "", AutoButtonColor = false, BorderSizePixel = 0,
	}, row)
	corner(track, 12)
	local knob = new("Frame", {
		Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, track)
	corner(knob, 9)
	local function render(v)
		UI.tween(track, { BackgroundColor3 = v and Theme.current.accent or Theme.current.off })
		UI.tween(knob, { Position = v and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3) })
	end
	render(get() == true)
	local off = sub(render)
	Theme.hooks[#Theme.hooks + 1] = function()
		if not row:IsDescendantOf(UI.screen) then return false end
		render(get() == true)
		return true
	end
	onRowDestroyed(row, off)
	track.Activated:Connect(function()
		local nv = not get()
		if nv and spec.gate then
			local reason = spec.gate()
			if reason then UI.notify(reason, false) return end
		end
		set(nv)
		render(get() == true)
	end)
	return row
end

function UI.addSlider(parent, spec)
	local row = UI.rowBase(parent, spec.title, spec.desc, 200)
	local get, set, sub = UI.access(spec)
	local min, max, step = spec.min, spec.max, spec.step or 1
	local holder = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(190, 30),
	}, row)
	local valueLabel = label(holder, "", { size = 13, align = Enum.TextXAlignment.Right, sizeUdim = UDim2.new(0, 46, 1, 0), font = Enum.Font.GothamBold })
	local bar = new("Frame", { Position = UDim2.new(0, 56, 0.5, -3), Size = UDim2.new(1, -56, 0, 6), BorderSizePixel = 0 }, holder)
	Theme.bind(bar, "BackgroundColor3", "off")
	corner(bar, 3)
	local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BorderSizePixel = 0 }, bar)
	Theme.bind(fill, "BackgroundColor3", "accent")
	corner(fill, 3)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, bar)
	corner(knob, 8)
	local function format(v)
		local text = step < 1 and string.format("%.2f", v) or tostring(v)
		return text .. (spec.suffix or "")
	end
	local function render(v)
		v = math.clamp(tonumber(v) or min, min, max)
		local alpha = (v - min) / (max - min)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		valueLabel.Text = format(v)
	end
	render(get())
	local off = sub(render)
	local function setFromX(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local v = min + a * (max - min)
		v = math.floor(v / step + 0.5) * step
		v = tonumber(string.format("%.4f", math.clamp(v, min, max)))
		set(v)
		render(v)
	end
	local hit = new("TextButton", {
		BackgroundTransparency = 1, Text = "", Position = UDim2.new(0, 50, 0, 0), Size = UDim2.new(1, -50, 1, 0),
	}, holder)
	local dragging, active = false, nil
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, active = true, input
			UI.lockScroll(true)
			setFromX(input.Position.X)
		end
	end)
	local c1 = UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input == active) then
			setFromX(input.Position.X)
		end
	end)
	local c2 = UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input == active) then
			dragging = false
			UI.lockScroll(false)
		end
	end)
	onRowDestroyed(row, function() off(); c1:Disconnect(); c2:Disconnect(); UI.lockScroll(false) end)
	return row
end

function UI.addDropdown(parent, spec)
	local row = UI.rowBase(parent, spec.title, spec.desc, 160)
	local get, set, sub = UI.access(spec)
	local button = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(152, 32),
		Text = "", AutoButtonColor = false, BorderSizePixel = 0,
	}, row)
	Theme.bind(button, "BackgroundColor3", "divider")
	corner(button, 8)
	local text = label(button, "", { size = 13, sizeUdim = UDim2.new(1, -30, 1, 0), position = UDim2.fromOffset(10, 0) })
	text.TextTruncate = Enum.TextTruncate.AtEnd
	label(button, "v", { size = 12, colorKey = "dim", align = Enum.TextXAlignment.Center,
		sizeUdim = UDim2.new(0, 20, 1, 0), position = UDim2.new(1, -22, 0, 0) })
	local function render(v) text.Text = (v == nil or v == "") and "--" or tostring(v) end
	render(get())
	local off = sub(render)
	onRowDestroyed(row, off)
	button.Activated:Connect(function()
		local options = type(spec.options) == "function" and spec.options() or spec.options
		UI.openDropdown(button, options, get(), function(value)
			set(value)
			render(get())
		end)
	end)
	return row
end

function UI.addTextbox(parent, spec)
	local row = UI.rowBase(parent, spec.title, spec.desc, 170)
	local get, set, sub = UI.access(spec)
	local box = new("TextBox", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(162, 32),
		Text = "", PlaceholderText = spec.placeholder or "",
		ClearTextOnFocus = false, Font = Enum.Font.GothamMedium, TextSize = 13, BorderSizePixel = 0,
	}, row)
	Theme.bind(box, "BackgroundColor3", "divider")
	Theme.bind(box, "TextColor3", "text")
	Theme.bind(box, "PlaceholderColor3", "dim")
	corner(box, 8)
	if spec.key then box.Text = tostring(get() or "") end
	box.FocusLost:Connect(function(enter)
		if spec.onSubmit then
			if enter then
				spec.onSubmit(box.Text)
				if spec.clearOnSubmit then box.Text = "" end
			end
		else
			set(box.Text)
		end
	end)
	local off = spec.key and sub(function(v) if not box:IsFocused() then box.Text = tostring(v) end end) or function() end
	onRowDestroyed(row, off)
	return row
end

function UI.addKeybind(parent, spec)
	local row = UI.rowBase(parent, spec.title, spec.desc, 120)
	local get, set = UI.access(spec)
	local button = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(112, 32),
		Text = tostring(get()), Font = Enum.Font.GothamBold, TextSize = 13, AutoButtonColor = false, BorderSizePixel = 0,
	}, row)
	Theme.bind(button, "BackgroundColor3", "divider")
	Theme.bind(button, "TextColor3", "text")
	corner(button, 8)
	button.Activated:Connect(function()
		button.Text = "Press a key..."
		UI.keyCapture = function(input)
			UI.keyCapture = nil
			if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then
				set(input.KeyCode.Name)
			end
			button.Text = tostring(get())
		end
	end)
	return row
end

function UI.addButton(parent, spec)
	local row = UI.rowBase(parent, spec.title, spec.desc, 96)
	local button = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(88, 32),
		Text = spec.button or "RUN", Font = Enum.Font.GothamBold, TextSize = 13, AutoButtonColor = true, BorderSizePixel = 0,
	}, row)
	Theme.bind(button, "BackgroundColor3", "accent")
	button.TextColor3 = Color3.new(1, 1, 1)
	corner(button, 8)
	button.Activated:Connect(function() spec.run() end)
	return row
end

function UI.addInfo(parent, spec)
	return UI.rowBase(parent, spec.title, spec.desc, 0)
end

local ADDERS = {
	toggle = UI.addToggle, slider = UI.addSlider, dropdown = UI.addDropdown, textbox = UI.addTextbox,
	keybind = UI.addKeybind, button = UI.addButton, info = UI.addInfo,
}

function UI.add(card, spec, tab)
	if tab and spec.searchable ~= false and spec.type ~= "info" then
		UI.registry[#UI.registry + 1] = { tab = tab, spec = spec }
	end
	return ADDERS[spec.type](card, spec)
end

function UI.section(page, title)
	local wrap = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, page)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, wrap)
	local header = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 1 }, wrap)
	label(header, title, { font = Enum.Font.GothamBold, size = 15, sizeUdim = UDim2.new(1, -30, 1, 0), position = UDim2.fromOffset(4, 0) })
	local arrow = label(header, "v", { size = 13, colorKey = "dim", align = Enum.TextXAlignment.Right, sizeUdim = UDim2.new(0, 24, 1, 0), position = UDim2.new(1, -24, 0, 0) })
	local card = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = 2 }, wrap)
	Theme.bind(card, "BackgroundColor3", "divider")
	corner(card, 12)
	stroke(card, "divider", 1, 0.3)
	new("UIListLayout", { Padding = UDim.new(0, 1), SortOrder = Enum.SortOrder.LayoutOrder }, card)
	header.Activated:Connect(function()
		card.Visible = not card.Visible
		arrow.Text = card.Visible and "v" or ">"
	end)
	return card
end

function UI.clearCard(card)
	for _, child in ipairs(card:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UICorner") and not child:IsA("UIStroke") then
			child:Destroy()
		end
	end
end

-- Dropdown popup -------------------------------------------------------------
function UI.buildPopup()
	UI.blocker = new("TextButton", {
		BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 50, AutoButtonColor = false,
	}, UI.screen)
	UI.popup = new("ScrollingFrame", {
		Visible = false, ZIndex = 51, BorderSizePixel = 0, ScrollBarThickness = 3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, UI.screen)
	Theme.bind(UI.popup, "BackgroundColor3", "side")
	Theme.bind(UI.popup, "ScrollBarImageColor3", "accent")
	corner(UI.popup, 10)
	stroke(UI.popup, "accent", 1, 0.5)
	new("UIListLayout", { Padding = UDim.new(0, 2) }, UI.popup)
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, UI.popup)
	UI.blocker.Activated:Connect(function() UI.closeDropdown() end)
end

function UI.closeDropdown()
	UI.blocker.Visible = false
	UI.popup.Visible = false
end

function UI.openDropdown(anchor, options, current, onPick)
	for _, child in ipairs(UI.popup:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	for _, option in ipairs(options or {}) do
		local isCurrent = option == current
		local b = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 32), Text = tostring(option), Font = Enum.Font.GothamMedium, TextSize = 13,
			AutoButtonColor = true, BorderSizePixel = 0, ZIndex = 52,
			BackgroundTransparency = isCurrent and 0.7 or 1,
		}, UI.popup)
		Theme.bind(b, "TextColor3", isCurrent and "accent" or "text")
		Theme.bind(b, "BackgroundColor3", "accent")
		corner(b, 6)
		b.Activated:Connect(function()
			UI.closeDropdown()
			onPick(option)
		end)
	end
	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(800, 400)
	local width = math.max(anchor.AbsoluteSize.X, 150)
	local height = math.min(#options * 34 + 8, 230)
	local x = math.clamp(anchor.AbsolutePosition.X + anchor.AbsoluteSize.X - width, 4, math.max(4, view.X - width - 4))
	local y = anchor.AbsolutePosition.Y + anchor.AbsoluteSize.Y + 4
	if y + height > view.Y - 4 then y = math.max(4, anchor.AbsolutePosition.Y - height - 4) end
	UI.popup.Position = UDim2.fromOffset(x, y)
	UI.popup.Size = UDim2.fromOffset(width, height)
	UI.blocker.Visible = true
	UI.popup.Visible = true
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local TABS = {
	{ "Combos", "⚡" }, { "Snowball", "❄" }, { "Combat", "⚔" }, { "Visuals", "👁" },
	{ "Whitelist", "👥" }, { "Performance", "🚀" }, { "Utilities", "🧰" }, { "Settings", "⚙" },
}

function UI.gradient(inst)
	local g = new("UIGradient", { Rotation = 45 }, inst)
	local function paint() g.Color = ColorSequence.new(Theme.current.accent, Theme.current.accent2) end
	paint()
	Theme.hooks[#Theme.hooks + 1] = function()
		if not inst:IsDescendantOf(UI.screen) then return false end
		paint()
		return true
	end
end

function UI.paintTabs()
	for name, t in pairs(UI.tabButtons) do
		local active = name == UI.currentTab
		t.button.BackgroundTransparency = active and 0.78 or 1
		t.text.TextColor3 = active and Theme.current.accent or Theme.current.text
	end
end

function UI.showTab(name, isSearch)
	for pageName, page in pairs(UI.pages) do page.Visible = (pageName == name) end
	if not isSearch then UI.lastTab = name; UI.currentTab = name else UI.currentTab = nil end
	for tabName, t in pairs(UI.tabButtons) do
		local active = tabName == UI.currentTab
		UI.tween(t.button, { BackgroundTransparency = active and 0.78 or 1 })
		t.text.TextColor3 = active and Theme.current.accent or Theme.current.text
	end
end

function UI.runSearch(text)
	text = string.lower(text or "")
	local page = UI.pages.Search
	for _, child in ipairs(page:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
	end
	if text == "" then
		UI.showTab(UI.lastTab or "Combos")
		return
	end
	local card = UI.section(page, "Search results")
	local count = 0
	for _, entry in ipairs(UI.registry) do
		local s = entry.spec
		local hay = string.lower((s.title or "") .. " " .. (s.desc or "") .. " " .. entry.tab)
		if string.find(hay, text, 1, true) then
			count += 1
			if count <= 40 then UI.add(card, s, nil) end
		end
	end
	if count == 0 then UI.add(card, { type = "info", title = "No results", desc = "Nothing matches that search." }) end
	UI.showTab("Search", true)
end

function UI.toggleVisible()
	UI.main.Visible = not UI.main.Visible
end

function UI.defaultWindowPosition()
	local view = workspace.CurrentCamera.ViewportSize
	local size = UI.maximized and UI.maxSize or UI.normalSize
	return UDim2.fromOffset((view.X - size.X) / 2, (view.Y - size.Y) / 2)
end

function UI.applyBackground()
	local id = tostring(Store.get("backgroundImageId") or "")
	local on = Store.get("backgroundImage") and id ~= ""
	UI.bgImage.Visible = on
	if on then
		UI.bgImage.Image = string.match(id, "^%d+$") and ("rbxassetid://" .. id) or id
		UI.bgImage.ImageTransparency = math.clamp(Store.get("backgroundTransparency"), 0, 100) / 100
	end
end

function UI.updateFovCircle()
	local circle = UI.fovCircle
	local on = Store.get("fovCircle")
	circle.Visible = on
	if not on then return end
	local camera = workspace.CurrentCamera
	local half = math.rad(math.clamp(Store.get("snowballFov"), 5, 170)) / 2
	local camHalf = math.rad(math.clamp(camera.FieldOfView, 10, 120)) / 2
	local radius = math.clamp((camera.ViewportSize.Y / 2) * math.tan(half) / math.tan(camHalf), 4, 3000)
	circle.Size = UDim2.fromOffset(radius * 2, radius * 2)
end

local Crosshair = {}
function Crosshair.build()
	local root = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(40, 40),
		Position = UDim2.fromScale(0.5, 0.5), Visible = false, ZIndex = 5,
	}, UI.screen)
	local function bit(props)
		local f = new("Frame", props, root)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BorderSizePixel = 0
		f.ZIndex = 5
		new("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.3 }, f)
		return f
	end
	Crosshair.root = root
	Crosshair.dot = bit({ Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(5, 5) })
	corner(Crosshair.dot, 3)
	Crosshair.h = bit({ Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 0, 0, 2) })
	Crosshair.v = bit({ Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 2, 1, 0) })
	Crosshair.image = new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 5 }, root)
end
function Crosshair.refresh()
	local root = Crosshair.root
	root.Visible = Store.get("crosshair")
	local size = math.clamp(Store.get("crosshairSize"), 6, 200)
	root.Size = UDim2.fromOffset(size, size)
	root.Position = UDim2.new(0.5, Store.get("crosshairX"), 0.5, Store.get("crosshairY"))
	local style = Store.get("crosshairStyle")
	Crosshair.dot.Visible = style == "Dot" or style == "Built-in Plus"
	Crosshair.h.Visible = style == "Built-in Plus"
	Crosshair.v.Visible = style == "Built-in Plus"
	local id = tostring(Store.get("customCrosshairId") or "")
	Crosshair.image.Visible = style == "Custom" and id ~= ""
	if Crosshair.image.Visible then
		Crosshair.image.Image = string.match(id, "^%d+$") and ("rbxassetid://" .. id) or id
	end
end

function UI.build()
	local ok, parent = pcall(function() return (gethui and gethui()) or game:GetService("CoreGui") end)
	UI.parent = ok and parent or LocalPlayer:WaitForChild("PlayerGui")
	UI.screen = Janitor.add(new("ScreenGui", {
		Name = HttpService:GenerateGUID(false), ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
	}, UI.parent))

	local camera = workspace.CurrentCamera
	local view = camera and camera.ViewportSize or Vector2.new(800, 400)
	UI.normalSize = Vector2.new(math.min(720, view.X - 24), math.min(380, view.Y - 24))
	UI.maxSize = Vector2.new(view.X - 24, view.Y - 24)
	UI.maximized, UI.minimized = false, false

	local startPos = (Store.get("winPosX") >= 0 and Store.get("winPosY") >= 0)
		and UDim2.fromOffset(Store.get("winPosX"), Store.get("winPosY")) or UI.defaultWindowPosition()
	UI.main = new("Frame", {
		Size = UDim2.fromOffset(UI.normalSize.X, UI.normalSize.Y), Position = startPos,
		BorderSizePixel = 0, ClipsDescendants = true, BackgroundTransparency = 0.03,
	}, UI.screen)
	Theme.bind(UI.main, "BackgroundColor3", "bg")
	corner(UI.main, 18)
	stroke(UI.main, "accent", 1.5, 0.55)

	UI.bgImage = new("ImageLabel", {
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Crop, Visible = false, ZIndex = 0,
	}, UI.main)
	corner(UI.bgImage, 18)

	-- Header
	local header = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52) }, UI.main)
	local logo = new("Frame", { Position = UDim2.fromOffset(16, 10), Size = UDim2.fromOffset(32, 32), BorderSizePixel = 0 }, header)
	Theme.bind(logo, "BackgroundColor3", "accent")
	corner(logo, 16)
	UI.gradient(logo)
	local logoText = label(logo, "C", { font = Enum.Font.GothamBold, size = 17, align = Enum.TextXAlignment.Center, sizeUdim = UDim2.fromScale(1, 1) })
	logoText.TextColor3 = Color3.new(1, 1, 1)
	label(header, BRAND, { font = Enum.Font.GothamBold, size = 16, sizeUdim = UDim2.new(0.6, 0, 0, 20), position = UDim2.fromOffset(58, 8) })
	label(header, "Mobile + Controller", { size = 12, colorKey = "dim", sizeUdim = UDim2.new(0.6, 0, 0, 16), position = UDim2.fromOffset(58, 28) })

	local function winButton(text, indexFromRight, callback)
		local b = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(14 + (indexFromRight - 1) * 36), 0.5, 0),
			Size = UDim2.fromOffset(30, 30), Text = text, Font = Enum.Font.GothamBold, TextSize = 14, AutoButtonColor = true,
			BorderSizePixel = 0,
		}, header)
		Theme.bind(b, "BackgroundColor3", "divider")
		Theme.bind(b, "TextColor3", "text")
		corner(b, 15)
		b.Activated:Connect(callback)
		return b
	end

	UI.body = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 52), Size = UDim2.new(1, 0, 1, -52) }, UI.main)

	winButton("X", 1, function() UI.main.Visible = false end)
	winButton("[]", 2, function()
		UI.maximized = not UI.maximized
		local target = UI.maximized and UI.maxSize or UI.normalSize
		UI.minimized = false
		UI.body.Visible = true
		UI.tween(UI.main, { Size = UDim2.fromOffset(target.X, target.Y) })
		if UI.maximized then
			UI.restorePos = UI.main.Position
			UI.tween(UI.main, { Position = UDim2.fromOffset(12, 12) })
		elseif UI.restorePos then
			UI.tween(UI.main, { Position = UI.restorePos })
		end
	end)
	winButton("-", 3, function()
		UI.minimized = not UI.minimized
		local target = UI.maximized and UI.maxSize or UI.normalSize
		UI.body.Visible = not UI.minimized
		UI.tween(UI.main, { Size = UDim2.fromOffset(target.X, UI.minimized and 52 or target.Y) })
	end)
	UI.makeDraggable(header, UI.main, function(x, y)
		Store.set("winPosX", x)
		Store.set("winPosY", y)
	end)

	-- Sidebar
	local side = new("Frame", {
		Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0, 168, 1, -34), BorderSizePixel = 0, BackgroundTransparency = 0.1,
	}, UI.body)
	Theme.bind(side, "BackgroundColor3", "side")
	corner(side, 14)
	UI.search = new("TextBox", {
		Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 0, 34), Text = "", PlaceholderText = "Search...",
		ClearTextOnFocus = false, Font = Enum.Font.GothamMedium, TextSize = 13, BorderSizePixel = 0,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, side)
	Theme.bind(UI.search, "BackgroundColor3", "divider")
	Theme.bind(UI.search, "TextColor3", "text")
	Theme.bind(UI.search, "PlaceholderColor3", "dim")
	corner(UI.search, 10)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12) }, UI.search)
	UI.tabList = new("ScrollingFrame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 1, -54),
		ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0,
	}, side)
	new("UIListLayout", { Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Center }, UI.tabList)

	-- Content pages
	UI.content = new("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(188, 0), Size = UDim2.new(1, -198, 1, -34),
	}, UI.body)
	local function makePage(name)
		local page = new("ScrollingFrame", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, BorderSizePixel = 0,
			ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, UI.content)
		Theme.bind(page, "ScrollBarImageColor3", "accent")
		new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, page)
		new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 12), PaddingRight = UDim.new(0, 6) }, page)
		UI.pages[name] = page
	end
	for _, tab in ipairs(TABS) do
		local name, icon = tab[1], tab[2]
		makePage(name)
		local b = new("TextButton", {
			Size = UDim2.new(1, -16, 0, 40), Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1,
		}, UI.tabList)
		Theme.bind(b, "BackgroundColor3", "accent")
		corner(b, 10)
		label(b, icon, { size = 15, align = Enum.TextXAlignment.Center, sizeUdim = UDim2.new(0, 30, 1, 0), position = UDim2.fromOffset(6, 0) })
		local tx = label(b, name, { size = 14, sizeUdim = UDim2.new(1, -44, 1, 0), position = UDim2.fromOffset(40, 0) })
		UI.tabButtons[name] = { button = b, text = tx }
		b.Activated:Connect(function()
			if UI.search.Text ~= "" then UI.search.Text = "" end
			UI.showTab(name)
		end)
	end
	makePage("Search")
	Janitor.add(UI.search:GetPropertyChangedSignal("Text"):Connect(function() UI.runSearch(UI.search.Text) end))

	-- Status bar
	UI.status = new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.new(0, 190, 1, -30), Size = UDim2.new(1, -204, 0, 24),
		Font = Enum.Font.GothamMedium, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Text = "",
	}, UI.body)
	Theme.bind(UI.status, "TextColor3", "dim")

	UI.buildPopup()

	-- Chris button (menu toggle, draggable)
	local btnPos = (Store.get("btnPosX") >= 0 and Store.get("btnPosY") >= 0)
		and UDim2.fromOffset(Store.get("btnPosX"), Store.get("btnPosY")) or UDim2.fromOffset(16, 64)
	UI.chris = new("TextButton", {
		Size = UDim2.fromOffset(50, 50), Position = btnPos, Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 20,
	}, UI.screen)
	Theme.bind(UI.chris, "BackgroundColor3", "accent")
	corner(UI.chris, 25)
	stroke(UI.chris, "accent2", 2, 0.15)
	UI.gradient(UI.chris)
	local chrisText = label(UI.chris, "C", { font = Enum.Font.GothamBold, size = 24, align = Enum.TextXAlignment.Center, sizeUdim = UDim2.fromScale(1, 1) })
	chrisText.TextColor3 = Color3.new(1, 1, 1)
	chrisText.ZIndex = 21
	UI.makeDraggable(UI.chris, UI.chris, function(x, y)
		Store.set("btnPosX", x)
		Store.set("btnPosY", y)
	end, UI.toggleVisible)

	-- FPS counter, FOV circle, crosshair
	UI.fpsLabel = new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(84, 10), Size = UDim2.fromOffset(120, 22), Text = "FPS --",
		Font = Enum.Font.GothamBold, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Visible = false, ZIndex = 20,
		TextStrokeTransparency = 0.4,
	}, UI.screen)
	Theme.bind(UI.fpsLabel, "TextColor3", "good")
	UI.fovCircle = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(100, 100), Visible = false, ZIndex = 4,
	}, UI.screen)
	corner(UI.fovCircle, 2000)
	stroke(UI.fovCircle, "accent", 2, 0.2)
	Crosshair.build()

	Theme.hooks[#Theme.hooks + 1] = function() UI.paintTabs() return true end
end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------
local Pages = { comboCards = {} }

local function addSection(tab, title, specs)
	local card = UI.section(UI.pages[tab], title)
	for _, spec in ipairs(specs) do UI.add(card, spec, tab) end
	return card
end

-- One slot row: tool dropdown plus a per-slot wait box (blank = use Action Delay)
function UI.addSlotRow(card, comboIndex, slotIndex)
	local combo = Store.combos[comboIndex]
	local row = UI.rowBase(card, "Slot " .. slotIndex, "Tap to select tool...", 244)
	local dd = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(152, 32),
		Text = "", AutoButtonColor = false, BorderSizePixel = 0,
	}, row)
	Theme.bind(dd, "BackgroundColor3", "divider")
	corner(dd, 8)
	local ddText = label(dd, "", { size = 13, sizeUdim = UDim2.new(1, -30, 1, 0), position = UDim2.fromOffset(10, 0) })
	ddText.TextTruncate = Enum.TextTruncate.AtEnd
	label(dd, "v", { size = 12, colorKey = "dim", align = Enum.TextXAlignment.Center, sizeUdim = UDim2.new(0, 20, 1, 0), position = UDim2.new(1, -22, 0, 0) })
	local function renderTool()
		local name = combo.slots[slotIndex]
		ddText.Text = (name == nil or name == "") and "--" or name
	end
	renderTool()
	dd.Activated:Connect(function()
		local options = { "--" }
		for _, name in ipairs(Macro.toolNames()) do options[#options + 1] = name end
		UI.openDropdown(dd, options, combo.slots[slotIndex], function(value)
			combo.slots[slotIndex] = (value == "--") and "" or value
			Store.queueSave()
			renderTool()
		end)
	end)
	local waitBox = new("TextBox", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -160, 0.5, 0), Size = UDim2.fromOffset(76, 32),
		Text = (combo.waits[slotIndex] or 0) > 0 and tostring(combo.waits[slotIndex]) or "",
		PlaceholderText = "wait (s)", ClearTextOnFocus = false, Font = Enum.Font.GothamMedium, TextSize = 12, BorderSizePixel = 0,
	}, row)
	Theme.bind(waitBox, "BackgroundColor3", "divider")
	Theme.bind(waitBox, "TextColor3", "text")
	Theme.bind(waitBox, "PlaceholderColor3", "dim")
	corner(waitBox, 8)
	waitBox.FocusLost:Connect(function()
		local n = tonumber(waitBox.Text)
		if waitBox.Text == "" then
			combo.waits[slotIndex] = 0
		elseif n and Util.finite(n) and n >= 0 then
			combo.waits[slotIndex] = math.min(n, 2)
		end
		waitBox.Text = (combo.waits[slotIndex] or 0) > 0 and tostring(combo.waits[slotIndex]) or ""
		Store.queueSave()
	end)
	return row
end

function Pages.fillCombo(card, i)
	UI.clearCard(card)
	local combo = Store.combos[i]
	UI.add(card, {
		type = "dropdown", title = "Controller Button", desc = "Controller button that runs Combo " .. i .. ".",
		options = BUTTON_LABELS,
		get = function() return buttonLabel(combo.button) or "None" end,
		set = function(v) combo.button = buttonCode(v); Store.queueSave() end,
	})
	UI.add(card, {
		type = "toggle", title = "Hotbar Number + Left Click at End",
		desc = "On: Combo " .. i .. " finishes with the hotbar number + a left click. Off: it only uses the tools.",
		get = function() return combo.endClick end,
		set = function(v) combo.endClick = v; Store.queueSave() end,
	})
	UI.add(card, {
		type = "toggle", title = "Fire RPG at End",
		desc = "After the slots, equips the RPG and fires it, like one tap = one RPG shot. Replaces the hotbar number + left click step for this combo.",
		get = function() return combo.fireRpg == true end,
		set = function(v) combo.fireRpg = v; Store.queueSave() end,
	})
	UI.add(card, { type = "info", title = string.format("Slots in use: %d / %d  (empty slots are skipped)", #combo.slots, CONFIG.MAX_SLOTS) })
	for j = 1, #combo.slots do UI.addSlotRow(card, i, j) end
	UI.add(card, {
		type = "button", title = "+ Add Slot", desc = "Adds another tool slot to Combo " .. i .. " (max " .. CONFIG.MAX_SLOTS .. ").", button = "ADD",
		run = function()
			if #combo.slots < CONFIG.MAX_SLOTS then
				combo.slots[#combo.slots + 1] = ""
				combo.waits[#combo.slots] = 0
				Store.queueSave()
				Pages.fillCombo(card, i)
			end
		end,
	})
	UI.add(card, {
		type = "button", title = "- Remove Slot", desc = "Removes the last tool slot from Combo " .. i .. " (keeps at least 1).", button = "REMOVE",
		run = function()
			if #combo.slots > 1 then
				combo.waits[#combo.slots] = nil
				combo.slots[#combo.slots] = nil
				Store.queueSave()
				Pages.fillCombo(card, i)
			end
		end,
	})
	UI.add(card, {
		type = "button", title = "Refresh Tool List", desc = "Reloads the tool lists if a tool is missing.", button = "REFRESH",
		run = function() Pages.fillCombo(card, i); UI.notify("Tool list refreshed.", true) end,
	})
	UI.add(card, {
		type = "button", title = "Clear Combo " .. i, desc = "Clears every tool in this combo.", button = "CLEAR",
		run = function()
			for j = 1, #combo.slots do combo.slots[j] = ""; combo.waits[j] = 0 end
			Store.queueSave()
			Pages.fillCombo(card, i)
		end,
	})
end

function Pages.rebuildCombos()
	for i, card in ipairs(Pages.comboCards) do Pages.fillCombo(card, i) end
end

function Pages.buildCombos()
	local page = UI.pages.Combos
	UI.add(UI.section(page, "Note"), {
		type = "info", title = "Note: for brass, use '1 punches' (not 'brass knuckles').",
		desc = "Items do not need to be in your bottom hotbar.",
	})
	for i = 1, CONFIG.COMBO_COUNT do
		local card = UI.section(page, "Combo " .. i)
		Pages.comboCards[i] = card
		Pages.fillCombo(card, i)
	end
	local hotbarOptions = {}
	for n = 1, 9 do hotbarOptions[n] = tostring(n) end
	addSection("Combos", "Combo Buttons", {
		{ type = "toggle", key = "comboButtonsShown", title = "Show Combo Buttons", desc = "Shows or hides the on-screen COMBO buttons. The small HIDE / SHOW button on screen does the same thing." },
		{ type = "slider", key = "comboButtonScale", min = 0.5, max = 2, step = 0.05, suffix = "x", title = "Combo Button Size",
			desc = "Makes every combo button bigger or smaller." },
		{ type = "toggle", key = "repositionMode", title = "Reposition Combo Buttons",
			desc = "On: drag each combo button anywhere on its own. Off: the buttons are locked and fire when tapped. The MOVE / DONE button does the same thing." },
	})
	addSection("Combos", "Combo Settings", {
		{ type = "dropdown", key = "comboHotbarKey", options = hotbarOptions, title = "Combo Hotbar Key",
			desc = "The number key pressed (then a left click) at the end of combos that have it turned on." },
		{ type = "slider", key = "actionDelayMs", min = 0, max = 500, step = 1, suffix = " ms", title = "Action Delay (ms)",
			desc = "Pause between combo actions. Raise it if combos skip tools. 0 is fastest." },
		{ type = "toggle", key = "reequipPrevious", title = "Re-equip Previous Tool",
			desc = "After a combo, switch back to the tool you were holding before it started." },
		{ type = "textbox", key = "rpgToolName", placeholder = "RPG", title = "RPG Tool Name",
			desc = "Any tool whose name contains this word counts as your RPG for the Fire RPG at End step." },
		{ type = "dropdown", key = "rpgFireMethod", options = { "Click", "Activate", "Both" }, title = "RPG Fire Method",
			desc = "Click = a real tap in the middle of the screen. Activate = the tool's own activation. Both = does both." },
		{ type = "slider", key = "rpgEquipWaitMs", min = 0, max = 1000, step = 10, suffix = " ms", title = "RPG Equip Wait (ms)",
			desc = "How long to wait after equipping the RPG before firing. Raise it if the RPG equips but does not shoot." },
		{ type = "textbox", key = "clickFireTools", placeholder = "RPG, Rocket", title = "Click-Fire Tools",
			desc = "Tools whose name contains one of these words (comma separated) fire with a real screen tap in the middle of the screen instead of the normal tool activation. Use it for the RPG. Clear it to turn it off." },
		{ type = "info", title = "Controller: pick each combo's button in its section above (defaults: D-pad Left / Up / Right; Combo 4 is unbound because D-pad Down is Shift Lock).",
			desc = "Each slot has an optional wait (s) box: leave it blank to use Action Delay, or give one tool a longer wait." },
	})
end

function Pages.buildSnowball()
	local gateFire = function() return "Gated: the game's projectile aim input is unknown, so this can't be applied yet." end
	addSection("Snowball", "Snowball Macro", {
		{ type = "info", title = "Snowball Launcher reloads every 10 shots. Golden reloads every 20." },
		{ type = "toggle", key = "useSnowballEvents", title = "Use Snowball Events",
			desc = "Fires snowballs with the game's events instead of clicking. Combos won't tap the launchers while this is on.",
			gate = function() return "Gated: the game's snowball remote and its arguments are unknown (CONFIG.SNOWBALL_EVENT_PATH)." end },
	})
	addSection("Snowball", "Targeting", {
		{ type = "toggle", key = "targetPlayers", title = "Target Players", desc = "Aims at the closest player you can see inside the FOV circle." },
		{ type = "toggle", key = "stickyTarget", title = "Sticky Target", desc = "Stays on one player until they leave the FOV instead of switching." },
		{ type = "toggle", key = "targetHighlight", title = "Target Highlight", desc = "Highlights the player you're aiming at." },
	})
	addSection("Snowball", "Prediction", {
		{ type = "toggle", key = "prediction", title = "Prediction", desc = "Aims ahead of moving players." },
		{ type = "slider", key = "projectileSpeed", min = 20, max = 600, step = 5, title = "Projectile Speed",
			desc = "How fast snowballs fly. If shots land behind players, lower it. If they land ahead, raise it." },
		{ type = "slider", key = "maxLeadTime", min = 0, max = 5, step = 0.1, suffix = " s", title = "Max Lead Time (s)",
			desc = "The most the aim can lead a moving player, in seconds." },
		{ type = "slider", key = "leadStrength", min = 0, max = 1, step = 0.05, title = "Lead Strength",
			desc = "How strong the aim-ahead is. 1 = full, lower = closer to the player." },
		{ type = "slider", key = "aimAheadOffset", min = 0, max = 20, step = 1, title = "Aim Ahead Offset (studs)",
			desc = "Aims this many extra studs past the player." },
	})
	addSection("Snowball", "Aim Range", {
		{ type = "slider", key = "snowballFov", min = 10, max = 170, step = 5, suffix = " deg", title = "Snowball FOV",
			desc = "Width of the FOV circle in degrees of view." },
		{ type = "slider", key = "targetDistance", min = 50, max = 1000, step = 10, title = "Target Distance (studs)",
			desc = "Ignores players farther away than this." },
	})
	addSection("Snowball", "Snowball Fire Height", {
		{ type = "toggle", key = "customFireHeight", title = "Custom Fire Height",
			desc = "Fires snowballs from your own height. Only works while Target Players is off.", gate = gateFire },
		{ type = "slider", key = "fireHeightOffset", min = -10, max = 10, step = 0.5, title = "Fire Height Offset (studs)",
			desc = "How high (+) or low (-) snowballs fire, compared to your camera." },
	})
	addSection("Snowball", "Rocket Fire Height", {
		{ type = "toggle", key = "customRocketHeight", title = "Custom Rocket Height",
			desc = "Changes where RPG, Rocket, Launcher, Santa's Naughty or Nice and Trick or Treat shots aim, up or down.", gate = gateFire },
		{ type = "slider", key = "rocketHeightOffset", min = -10, max = 10, step = 0.5, title = "Rocket Height Offset (studs)",
			desc = "How high (+) or low (-) rocket shots aim. Try small steps first." },
	})
	addSection("Snowball", "FOV Circle", {
		{ type = "toggle", key = "fovCircle", title = "FOV Circle", desc = "Shows the circle that Target Players uses." },
	})
end

function Pages.buildCombat()
	addSection("Combat", "Hitbox", {
		{ type = "toggle", key = "hitboxExtender", title = "Hitbox Extender", desc = "Makes other players' hitboxes bigger so they're easier to hit." },
		{ type = "slider", key = "hitboxSize", min = CONFIG.HITBOX_MIN, max = CONFIG.HITBOX_MAX, step = 1, title = "Hitbox Size" },
		{ type = "toggle", key = "hitboxVisualizer", title = "Hitbox Visualizer",
			desc = "Shows each extended hitbox as a glowing light blue box with a pulsing dark red outline and a scan line. Its size follows Hitbox Size. Needs Hitbox Extender on." },
	})
	addSection("Combat", "Auto Stomp", {
		{ type = "toggle", key = "autoStomp", title = "Auto Stomp", desc = "Automatically stomps nearby players who are low on health." },
	})
	addSection("Combat", "Stomp Cutscene", {
		{ type = "toggle", key = "blockStompCutscene", title = "Block Stomp Cutscene",
			desc = "Skips the stomp cutscene. To turn it back on, toggle off and rejoin.", gate = Stomp.gate },
	})
end

function Pages.buildVisuals()
	addSection("Visuals", "Player ESP", {
		{ type = "toggle", key = "friendEsp", title = "Friend ESP", desc = "See your friends through walls (blue)." },
		{ type = "toggle", key = "whitelistEsp", title = "Whitelist ESP", desc = "See whitelisted players through walls (green)." },
	})
	addSection("Visuals", "Tag", {
		{ type = "toggle", key = "showNames", title = "Show Names" },
		{ type = "toggle", key = "showDistance", title = "Show Distance" },
	})
	addSection("Visuals", "Camera", {
		{ type = "toggle", key = "fovChanger", title = "FOV Changer", desc = "Keeps your camera at the field of view below." },
		{ type = "slider", key = "fov", min = 30, max = 120, step = 1, title = "FOV" },
		{ type = "toggle", key = "stretchRes", title = "Stretch Res", desc = "Squashes the screen so players look wider." },
		{ type = "slider", key = "stretchAmount", min = 30, max = 100, step = 1, suffix = "%", title = "Stretch Amount (%)",
			desc = "Lower = wider players. 100 = normal." },
	})
	addSection("Visuals", "Crosshair", {
		{ type = "toggle", key = "crosshair", title = "Crosshair", desc = "Shows a crosshair in the middle of your screen." },
		{ type = "dropdown", key = "crosshairStyle", options = { "Dot", "Built-in Plus", "Custom" }, title = "Crosshair Style",
			desc = "Pick a crosshair. Dot and Plus always work. Custom uses the image ID below." },
		{ type = "textbox", key = "customCrosshairId", placeholder = "Image ID", title = "Custom Crosshair ID", desc = "Roblox image ID for the Custom style." },
		{ type = "slider", key = "crosshairSize", min = 10, max = 120, step = 1, title = "Crosshair Size (px)" },
		{ type = "slider", key = "crosshairX", min = -200, max = 200, step = 1, title = "Crosshair X Position (px)", desc = "Moves the crosshair left (-) or right (+)." },
		{ type = "slider", key = "crosshairY", min = -200, max = 200, step = 1, title = "Crosshair Y Position (px)", desc = "Moves the crosshair up (-) or down (+)." },
	})
end

function Pages.buildWhitelist()
	local page = UI.pages.Whitelist
	local listCard = UI.section(page, "Whitelisted Players")
	UI.add(listCard, { type = "info", title = "Whitelisted players are never targeted by the snowball macro, auto stomped, or given an extended hitbox." })
	local _, listTitle, listDesc
	_, listTitle, listDesc = UI.addInfo(listCard, { title = "Whitelist (0)", desc = "Nobody whitelisted yet." })
	local function names()
		local list = {}
		for _, name in pairs(Store.whitelist) do list[#list + 1] = name end
		table.sort(list)
		return list
	end
	local function refreshList()
		local list = names()
		listTitle.Text = string.format("Whitelist (%d)", #list)
		if listDesc then listDesc.Text = #list == 0 and "Nobody whitelisted yet." or table.concat(list, ", ") end
	end
	Store.onWhitelist(refreshList)
	refreshList()

	local function addPlayer(player)
		if not player then UI.notify("No matching player in this server.", false) return end
		Store.whitelist[tostring(player.UserId)] = player.Name
		Store.fireWhitelist()
		UI.notify("Whitelisted " .. player.Name .. ".", true)
	end
	local function removeByName(text)
		text = string.lower(text or "")
		for id, name in pairs(Store.whitelist) do
			if string.lower(name) == text or string.sub(string.lower(name), 1, #text) == text and text ~= "" then
				Store.whitelist[id] = nil
				Store.fireWhitelist()
				UI.notify("Removed " .. name .. ".", true)
				return
			end
		end
		UI.notify("That player is not on the whitelist.", false)
	end

	addSection("Whitelist", "Add Players", {
		{ type = "textbox", title = "Whitelist Player (type a name)", desc = "Type a player's name (or the first part) and press Enter.",
			placeholder = "Player name", clearOnSubmit = true, onSubmit = function(text) addPlayer(Util.findPlayer(text)) end },
		{ type = "dropdown", title = "Add From Server", desc = "Pick a player who is in the server.",
			get = function() return "" end,
			options = function()
				local list = {}
				for _, p in ipairs(Players:GetPlayers()) do
					if p ~= LocalPlayer and not Store.whitelist[tostring(p.UserId)] then list[#list + 1] = p.Name end
				end
				table.sort(list)
				return list
			end,
			set = function(name) addPlayer(Util.findPlayer(name)) end },
	})
	addSection("Whitelist", "Remove Players", {
		{ type = "textbox", title = "Remove Player (type a name)", desc = "Type a whitelisted player's name and press Enter.",
			placeholder = "Player name", clearOnSubmit = true, onSubmit = removeByName },
		{ type = "dropdown", title = "Remove From Whitelist", desc = "Pick a whitelisted player to remove.",
			get = function() return "" end, options = names, set = removeByName },
		{ type = "button", title = "Refresh Lists", desc = "Reloads the player lists.", button = "REFRESH", run = function() refreshList(); UI.notify("Lists refreshed.", true) end },
		{ type = "button", title = "Clear Whitelist", desc = "Removes everyone from the whitelist.", button = "CLEAR",
			run = function() Store.whitelist = {}; Store.fireWhitelist(); UI.notify("Whitelist cleared.", true) end },
	})
	addSection("Whitelist", "Automatic", {
		{ type = "toggle", key = "whitelistFriends", title = "Whitelist Friends", desc = "Automatically whitelists your Roblox friends." },
		{ type = "toggle", key = "whitelistTeammates", title = "Whitelist Teammates", desc = "Automatically whitelists your teammates (only works in games with teams)." },
	})
end

function Pages.buildPerformance()
	addSection("Performance", "Presets", {
		{ type = "button", title = "Super Low Graphics", button = "APPLY",
			desc = "Turns on every graphics option below for the best FPS. Use Restore Graphics to undo it.", run = function() Gfx.setAll(true) end },
		{ type = "button", title = "Restore Graphics", button = "RESTORE", desc = "Puts your graphics back to normal.", run = function() Gfx.setAll(false) end },
	})
	addSection("Performance", "Graphics Options", {
		{ type = "toggle", key = "gfx_shadows", title = "Disable Shadows", desc = "Turns off global shadows and part shadows." },
		{ type = "toggle", key = "gfx_plastic", title = "Plastic Materials", desc = "Swaps every material for plain plastic." },
		{ type = "toggle", key = "gfx_textures", title = "Hide Textures & Decals", desc = "Hides textures and decals." },
		{ type = "toggle", key = "gfx_particles", title = "Disable Particles & Trails", desc = "Turns off particles, trails, beams, smoke, fire and sparkles." },
		{ type = "toggle", key = "gfx_lights", title = "Disable Lights", desc = "Turns off point, spot and surface lights." },
		{ type = "toggle", key = "gfx_post", title = "Disable Post-Processing", desc = "Turns off bloom, blur, colour correction, depth of field, sun rays and atmosphere." },
		{ type = "toggle", key = "gfx_mesh", title = "Lower Mesh Detail", desc = "Sets meshes and unions to performance render fidelity." },
		{ type = "toggle", key = "gfx_water", title = "Flat Water", desc = "Makes terrain water clear and still." },
		{ type = "toggle", key = "gfx_lighting", title = "Flat Lighting", desc = "Flat, darker lighting like the super low preset." },
		{ type = "toggle", key = "gfx_quality", title = "Lowest Quality Level", desc = "Sets Roblox's graphics quality to level 1." },
	})
	addSection("Performance", "FPS Tools", {
		{ type = "toggle", key = "showFps", title = "Show FPS Counter", desc = "Shows your FPS in the top-left corner." },
		{ type = "toggle", key = "fpsCap", title = "FPS Cap", desc = "Caps your FPS at the number below.",
			gate = function() if not setfpscap then return "Gated: this executor has no setfpscap." end end },
		{ type = "slider", key = "fpsCapValue", min = 15, max = 360, step = 5, title = "FPS Cap Value" },
	})
end

function Pages.buildUtilities()
	addSection("Utilities", "Anti-AFK", {
		{ type = "toggle", key = "antiAfk", title = "Anti-AFK", desc = "Stops Roblox from kicking you for being idle." },
	})
	addSection("Utilities", "Utilities", {
		{ type = "button", title = "Refresh Camera", desc = "Fixes the camera if it gets stuck or breaks.", button = "FIX", run = CameraFx.refresh },
		{ type = "button", title = "Save Chris Data", desc = "Saves your combos and settings right now.", button = "SAVE",
			run = function() local ok = Store.save(); UI.notify(ok and "Saved." or "Could not save (no writefile in this executor).", ok) end },
	})
	addSection("Utilities", "Music", {
		{ type = "button", title = "Load Music", desc = "Plays the music set in the script.", button = "LOAD", run = Misc.loadMusic },
	})
	addSection("Utilities", "Server", {
		{ type = "button", title = "Rejoin Server", desc = "Rejoins this game.", button = "REJOIN", run = Misc.rejoin },
		{ type = "button", title = "Server Hop", desc = "Joins a different server that isn't full.", button = "HOP", run = Misc.serverHop },
		{ type = "info", title = "Chris Mobile Macro", desc = "Chris Mobile Macro // Controller edition." },
	})
	addSection("Utilities", "Shift Lock", {
		{ type = "toggle", key = "shiftLock", title = "Shift Lock",
			desc = "Your character always faces where the camera points. Turns off by itself at 5 HP or less, or when ragdolled, seated or flying." },
		{ type = "dropdown", key = "shiftLockButton", options = BUTTON_LABELS, title = "Shift Lock Button",
			desc = "Button that turns Shift Lock on or off (default D-Pad Down). If a combo uses the same button, the combo runs instead." },
	})
end

function Pages.buildSettings()
	addSection("Settings", "Appearance", {
		{ type = "dropdown", key = "theme", options = THEME_NAMES, title = "Theme", desc = "Changes the menu colors." },
		{ type = "keybind", key = "toggleKey", title = "Toggle UI Key", desc = "Key that shows or hides the menu (on mobile use the Chris button)." },
		{ type = "toggle", key = "uiAnimations", title = "UI Animations", desc = "Smooth toggle and tab animations." },
	})
	addSection("Settings", "Mobile", {
		{ type = "toggle", key = "mobileButtons", title = "Mobile Combo Buttons", desc = "Master switch for every on-screen combo button, including MOVE and HIDE. Size, hide and reposition options are in the Combos tab." },
		{ type = "button", title = "Reset UI Position", desc = "Puts the menu, the Chris button and every combo button back in their default spots.", button = "RESET",
			run = function() UI.resetPositions() end },
	})
	addSection("Settings", "Background", {
		{ type = "toggle", key = "backgroundImage", title = "Background Image", desc = "Shows an image behind the menu." },
		{ type = "textbox", key = "backgroundImageId", placeholder = "Image ID", title = "Background Image ID",
			desc = "Image ID or link for the menu background. Must be an image ID, not a decal ID." },
		{ type = "slider", key = "backgroundTransparency", min = 0, max = 100, step = 1, title = "Background Transparency (%)", desc = "Higher = fainter image." },
	})
	addSection("Settings", "Data", {
		{ type = "button", title = "Unload Chris", desc = "Saves your settings and closes Chris Mobile Macro completely.", button = "UNLOAD", run = function() env.ChrisMobileMacroCleanup() end },
		{ type = "button", title = "Save Settings", desc = "Saves your current settings.", button = "SAVE",
			run = function() local ok = Store.save(); UI.notify(ok and "Settings saved." or "Could not save (no writefile in this executor).", ok) end },
		{ type = "button", title = "Reload Saved Settings", desc = "Loads your last saved settings.", button = "RELOAD",
			run = function()
				local data = Store.readFile()
				if not data then UI.notify("No saved settings found.", false) return end
				Store.applyData(data, true)
				Pages.rebuildCombos()
				Store.fireWhitelist()
				UI.notify("Saved settings loaded.", true)
			end },
	})
end

-- ---------------------------------------------------------------------------
-- Mobile combo buttons: dark pill buttons ("COMBO 1", "COMBO 2", ...), one per combo, plus ALL COMBOS,
-- a MOVE trigger and a HIDE / SHOW button. All of them scale with the Combo Button Size slider.
-- ---------------------------------------------------------------------------
local PILL_COLOR = Color3.fromRGB(46, 46, 52)

function UI.buttonScale()
	return math.clamp(Store.get("comboButtonScale"), 0.5, 2)
end

function UI.defaultButtonPosition(index)
	local scale = UI.buttonScale()
	local gap = 10 * scale
	local total = 0
	for i, def in ipairs(UI.buttonDefs) do
		total = total + def.h * scale + (i > 1 and gap or 0)
	end
	local offset = 0
	for i = 1, index - 1 do offset = offset + UI.buttonDefs[i].h * scale + gap end
	return UDim2.new(0, 16, 0.5, math.floor(-total / 2 + offset))
end

function UI.applyButtonScale()
	local scale = UI.buttonScale()
	for _, item in ipairs(UI.comboButtonList) do
		local def = item.def
		local w, h = def.w * scale, def.h * scale
		item.button.Size = UDim2.fromOffset(w, h)
		item.button.TextSize = math.clamp(math.floor(def.ts * scale + 0.5), 8, 32)
		item.corner.CornerRadius = UDim.new(0, h / 2)
		if Store.get("cbx" .. item.index) < 0 or Store.get("cby" .. item.index) < 0 then
			item.button.Position = UI.defaultButtonPosition(item.index)
		end
	end
end

function UI.updateButtonVisibility()
	local master, shown = Store.get("mobileButtons"), Store.get("comboButtonsShown")
	for _, item in ipairs(UI.comboButtonList) do
		item.button.Visible = master and (item.def.kind == "hide" or shown)
	end
	if UI.hideButton then UI.hideButton.Text = shown and "HIDE" or "SHOW" end
	if not shown and Store.get("repositionMode") then Store.set("repositionMode", false) end
end

function UI.setRepositioning(on, silent)
	UI.repositioning = on and true or false
	for _, item in ipairs(UI.comboButtonList) do
		item.outline.Thickness = UI.repositioning and 3 or 0
	end
	if UI.moveTrigger then UI.moveTrigger.Text = UI.repositioning and "DONE" or "MOVE" end
	if not silent then
		UI.notify(UI.repositioning and "Reposition on: drag any combo button, then tap DONE." or "Combo buttons locked.", true)
	end
end

function UI.buildComboButtons()
	UI.comboButtonList = {}
	UI.buttonDefs = {}
	local function define(def) UI.buttonDefs[#UI.buttonDefs + 1] = def end
	for i = 1, CONFIG.COMBO_COUNT do
		define({ kind = "combo", text = "COMBO " .. i, w = 116, h = 38, ts = 14, run = function() Macro.run(i) end })
	end
	define({ kind = "combo", text = "ALL COMBOS", w = 116, h = 38, ts = 14, run = Macro.runAll })
	define({ kind = "move", text = "MOVE", w = 116, h = 38, ts = 14 })
	define({ kind = "hide", text = "HIDE", w = 72, h = 30, ts = 12 })

	local function place(index)
		local x, y = Store.get("cbx" .. index), Store.get("cby" .. index)
		if x >= 0 and y >= 0 then return UDim2.fromOffset(x, y) end
		return UI.defaultButtonPosition(index)
	end
	local function saveAt(index)
		return function(x, y)
			Store.set("cbx" .. index, x)
			Store.set("cby" .. index, y)
		end
	end
	local function movable() return UI.repositioning end

	for index, def in ipairs(UI.buttonDefs) do
		local b = new("TextButton", {
			Size = UDim2.fromOffset(def.w, def.h), Position = place(index), Text = def.text,
			Font = Enum.Font.GothamBold, TextSize = def.ts, TextColor3 = Color3.new(1, 1, 1),
			BackgroundColor3 = PILL_COLOR, BackgroundTransparency = 0.12, AutoButtonColor = false,
			BorderSizePixel = 0, ZIndex = 15, Visible = false,
		}, UI.screen)
		local pill = new("UICorner", { CornerRadius = UDim.new(0, def.h / 2) }, b)
		local outline = new("UIStroke", {
			Thickness = 0, Color = Theme.current.accent2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, b)
		Theme.bind(outline, "Color", "accent2")
		UI.comboButtonList[#UI.comboButtonList + 1] = { button = b, outline = outline, corner = pill, index = index, def = def }
		if def.kind == "move" then UI.moveTrigger = b end
		if def.kind == "hide" then UI.hideButton = b end

		UI.makeDraggable(b, b, saveAt(index), function()
			if def.kind == "move" then
				Store.set("repositionMode", not Store.get("repositionMode"))
			elseif def.kind == "hide" then
				Store.set("comboButtonsShown", not Store.get("comboButtonsShown"))
			elseif not UI.repositioning then
				b.BackgroundColor3 = Theme.current.accent
				UI.tween(b, { BackgroundColor3 = PILL_COLOR })
				def.run()
			end
		end, movable)
	end
	UI.applyButtonScale()
	UI.updateButtonVisibility()
	UI.setRepositioning(false, true)
end

function UI.resetPositions()
	Store.set("winPosX", -1); Store.set("winPosY", -1)
	Store.set("btnPosX", -1); Store.set("btnPosY", -1)
	for i = 1, CONFIG.COMBO_COUNT + 3 do
		Store.set("cbx" .. i, -1)
		Store.set("cby" .. i, -1)
	end
	UI.main.Position = UI.defaultWindowPosition()
	UI.chris.Position = UDim2.fromOffset(16, 64)
	for _, item in ipairs(UI.comboButtonList) do
		item.button.Position = UI.defaultButtonPosition(item.index)
	end
	UI.restorePos = nil
end

-- ---------------------------------------------------------------------------
-- Start-up
-- ---------------------------------------------------------------------------
local function unload()
	Store.save()
	Hitbox.restoreAll()
	Esp.clear()
	Target.clearHighlight()
	pcall(Stomp.setBlocked, false)
	Gfx.restoreAll()
	if Store.get("fpsCap") and setfpscap then pcall(setfpscap, 0) end
	local _, hum = Util.parts(LocalPlayer)
	if hum and Misc.shiftWasLocked then hum.AutoRotate = true end
	Janitor.clean()
	env.ChrisMobileMacroCleanup = nil
end
env.ChrisMobileMacroCleanup = unload

UI.build()
Pages.buildCombos()
Pages.buildSnowball()
Pages.buildCombat()
Pages.buildVisuals()
Pages.buildWhitelist()
Pages.buildPerformance()
Pages.buildUtilities()
Pages.buildSettings()
UI.buildComboButtons()
UI.showTab("Combos")
UI.applyBackground()
Crosshair.refresh()

-- Setting reactions
local function react(key, fn)
	Janitor.add(Store.sub(key, fn))
end
react("hitboxExtender", function(v) if not v then Hitbox.restoreAll() end end)
react("hitboxVisualizer", function()
	for root in pairs(Hitbox.vis) do Hitbox.destroyVis(root) end
end)
react("blockStompCutscene", function(v) Stomp.setBlocked(v) end)
react("showFps", function(v) UI.fpsLabel.Visible = v end)
react("fpsCap", Misc.applyFpsCap)
react("fpsCapValue", Misc.applyFpsCap)
react("theme", function(v) Theme.apply(v) end)
react("backgroundImage", UI.applyBackground)
react("backgroundImageId", UI.applyBackground)
react("backgroundTransparency", UI.applyBackground)
react("mobileButtons", function() UI.updateButtonVisibility() end)
react("comboButtonsShown", function() UI.updateButtonVisibility() end)
react("comboButtonScale", function() UI.applyButtonScale() end)
react("repositionMode", function(v) UI.setRepositioning(v) end)
for _, key in ipairs({ "crosshair", "crosshairStyle", "customCrosshairId", "crosshairSize", "crosshairX", "crosshairY" }) do
	react(key, Crosshair.refresh)
end
UI.fpsLabel.Visible = Store.get("showFps")
if Store.get("fpsCap") then Misc.applyFpsCap() end
if Store.get("blockStompCutscene") then Stomp.setBlocked(true) end

Gfx.init()
Misc.initAntiAfk()

for _, player in ipairs(Players:GetPlayers()) do Util.refreshFriend(player) end
Janitor.add(Players.PlayerAdded:Connect(Util.refreshFriend))
Janitor.add(Players.PlayerRemoving:Connect(function(player)
	Esp.remove(player)
	if Target.current == player then Target.current = nil; Target.clearHighlight() end
end))

-- Input
Janitor.add(UserInputService.InputBegan:Connect(function(input)
	if UI.keyCapture and input.UserInputType == Enum.UserInputType.Keyboard then
		UI.keyCapture(input)
		return
	end
	if UserInputService:GetFocusedTextBox() then return end
	local code = input.KeyCode
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if code.Name == Store.get("toggleKey") then UI.toggleVisible() end
		return
	end
	if string.find(input.UserInputType.Name, "Gamepad", 1, true) and code ~= Enum.KeyCode.Unknown then
		for i, combo in ipairs(Store.combos) do
			if combo.button ~= "None" and combo.button == code.Name then
				Macro.run(i)
				return
			end
		end
		if buttonCode(Store.get("shiftLockButton")) == code.Name then
			Store.set("shiftLock", not Store.get("shiftLock"))
		end
	end
end))

-- Per-frame work. Camera effects run in this order: aim lock, FOV, stretch.
RunService:BindToRenderStep("ChrisAim", Enum.RenderPriority.Camera.Value + 1, function()
	Target.step()
	UI.updateFovCircle()
end)
RunService:BindToRenderStep("ChrisFov", Enum.RenderPriority.Camera.Value + 2, CameraFx.fovStep)
RunService:BindToRenderStep("ChrisStretch", Enum.RenderPriority.Camera.Value + 3, CameraFx.stretchStep)
Janitor.add(function()
	for _, name in ipairs({ "ChrisAim", "ChrisFov", "ChrisStretch" }) do
		pcall(function() RunService:UnbindFromRenderStep(name) end)
	end
end)

local slowTimer = 0
Janitor.add(RunService.Heartbeat:Connect(function(dt)
	Misc.fpsStep(dt)
	Misc.shiftLockStep()
	Hitbox.animate()
	slowTimer += dt
	if slowTimer >= 0.2 then
		slowTimer = 0
		Hitbox.step()
		Stomp.step()
		Esp.step()
	end
end))

UI.notify("Loaded. Tap the C button or press " .. tostring(Store.get("toggleKey")) .. " to hide or show the menu.", true)
