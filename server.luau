local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)

local server = {}
local playerDataStore: DataStore? = nil
local sessionCache: { [Player]: { Data: table, IsLoaded: boolean } } = {}
local listeners: { [Player]: { (key: string, value: any) -> () } } = {}
local dataRemote: RemoteEvent

local function reconcile(target: table, template: table): table
	for key, defaultValue in pairs(template) do
		if target[key] == nil then
			if typeof(defaultValue) == "table" then
				target[key] = reconcile({}, defaultValue)
			else
				target[key] = defaultValue
			end
		elseif typeof(target[key]) == "table" and typeof(defaultValue) == "table" then
			reconcile(target[key], defaultValue)
		end
	end
	return target
end

local function sanitizeForDataStore(orig: any): any
	if typeof(orig) ~= "table" then
		return orig
	end

	local copy = {}
	for k, v in pairs(orig) do
		if typeof(v) == "function" then
			continue
		elseif typeof(v) == "table" then
			copy[k] = sanitizeForDataStore(v)
		else
			copy[k] = v
		end
	end
	return copy
end

local function retryAsync(action: () -> any): (boolean, any)
	local success, result
	for attempt = 1, Config.MaxRetries do
		success, result = pcall(action)
		if success then
			return true, result
		end
		task.wait(1)
	end
	return false, result
end

local function getRemote(): RemoteEvent
	local remote = ReplicatedStorage:FindFirstChild("DataSystemSync") :: RemoteEvent?
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "DataSystemSync"
		remote.Parent = ReplicatedStorage
	end
	return remote
end

function server.Configure(customConfig: table)
	for key, value in pairs(customConfig) do
		if typeof(value) == "table" and typeof(Config[key]) == "table" then
			for subKey, subValue in pairs(value) do
				Config[key][subKey] = subValue
			end
		else
			Config[key] = value
		end
	end
end

function server.Init(customConfig: table?)
	if customConfig then
		server.Configure(customConfig)
	end

	playerDataStore = DataStoreService:GetDataStore(Config.DataStoreName)
	dataRemote = getRemote()

	dataRemote.OnServerEvent:Connect(function(player, action)
		if action == "Fetch" then
			local session = sessionCache[player]
			if session and session.IsLoaded then
				dataRemote:FireClient(player, "InitSync", session.Data)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		server.SavePlayer(player)
		sessionCache[player] = nil
		listeners[player] = nil
	end)

	Players.PlayerAdded:Connect(function(player)
		server.LoadPlayer(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		if not sessionCache[player] then
			task.spawn(function()
				server.LoadPlayer(player)
			end)
		end
	end

	task.spawn(function()
		while true do
			task.wait(Config.AutoSaveInterval)
			for _, player in ipairs(Players:GetPlayers()) do
				if sessionCache[player] and sessionCache[player].IsLoaded then
					task.spawn(function()
						server.SavePlayer(player)
					end)
				end
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			task.wait(0.5)
			return
		end

		local threads = {}
		for _, player in ipairs(Players:GetPlayers()) do
			table.insert(
				threads,
				task.spawn(function()
					server.SavePlayer(player)
				end)
			)
		end

		local start = os.clock()
		while #threads > 0 and (os.clock() - start) < 10 do
			task.wait(0.1)
		end
	end)
end

function server.LoadPlayer(player: Player)
	if not playerDataStore then
		playerDataStore = DataStoreService:GetDataStore(Config.DataStoreName)
	end

	local key = "Player_" .. player.UserId
	local success, rawData = retryAsync(function()
		return playerDataStore:GetAsync(key)
	end)

	local loadedData = (success and rawData) and reconcile(rawData, Config.template)
		or sanitizeForDataStore(Config.template)

	sessionCache[player] = { Data = loadedData, IsLoaded = true }

	if dataRemote then
		dataRemote:FireClient(player, "InitSync", loadedData)
	end
end

function server.SavePlayer(player: Player)
	local session = sessionCache[player]
	if not session or not session.IsLoaded or not playerDataStore then
		return
	end

	local key = "Player_" .. player.UserId
	local dataToSave = sanitizeForDataStore(session.Data)

	local success, err = retryAsync(function()
		playerDataStore:SetAsync(key, dataToSave)
	end)

	if not success then
		warn("[DataSystem] Failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
end

function server.getProfile(player: Player)
	local init = script.Parent
	local DataSystem = require(init)

	return DataSystem.CreateProxy(function()
		local session = sessionCache[player]
		return session and session.Data or Config.template
	end, function(valOrTransform)
		local session = sessionCache[player]
		if not session or not session.IsLoaded then
			return
		end

		if typeof(valOrTransform) == "function" then
			session.Data = valOrTransform(session.Data)
		else
			session.Data = valOrTransform
		end

		-- Replicate to client
		if dataRemote then
			dataRemote:FireClient(player, "InitSync", session.Data)
		end

		-- FIX: Fire all server-side listeners subscribed to this player's session
		if listeners[player] then
			for _, callback in ipairs(listeners[player]) do
				task.spawn(callback, session.Data)
			end
		end
	end, function(callback)
		if not listeners[player] then
			listeners[player] = {}
		end
		table.insert(listeners[player], callback)
		return {
			Disconnect = function()
				local idx = table.find(listeners[player], callback)
				if idx then
					table.remove(listeners[player], idx)
				end
			end,
		}
	end)
end

-- Alias GetSession to getProfile for backwards compatibility
server.GetSession = server.getProfile

return setmetatable(server, {
	__call = function(_, player: Player)
		return server.getProfile(player)
	end,
	__index = function(t, key)
		-- Allows indexing a Player object directly: Data[player]
		if typeof(key) == "Instance" and key:IsA("Player") then
			return server.getProfile(key)
		end
		return rawget(t, key)
	end,
})
