local ReplicatedStorage = game:GetService("ReplicatedStorage")

local client = {}
local localData = {}
local listeners = {}

local function getRemote(): RemoteEvent?
	return ReplicatedStorage:WaitForChild("DataSystemSync", 10) :: RemoteEvent?
end

function client.Init()
	local remote = getRemote()
	if not remote then
		return
	end

	remote.OnClientEvent:Connect(function(action, data)
		if action == "InitSync" then
			localData = data
			for _, callback in ipairs(listeners) do
				task.spawn(callback, localData)
			end
		end
	end)

	remote:FireServer("Fetch")
end

function client.GetProxy()
	local init = script.Parent
	local DataSystem = require(init)

	return DataSystem.CreateProxy(function()
		return localData
	end, function()
		warn("[DataSystem] Client cannot directly mutate player data.")
	end, function(callback)
		table.insert(listeners, callback)
		return {
			Disconnect = function()
				local idx = table.find(listeners, callback)
				if idx then
					table.remove(listeners, idx)
				end
			end,
		}
	end)
end

return setmetatable(client, {
	__index = function(t, key)
		if rawget(t, key) then
			return rawget(t, key)
		end
		return client.GetProxy()[key]
	end,
})
