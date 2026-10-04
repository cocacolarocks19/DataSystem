local RunService = game:GetService("RunService")

local DataSystem = {}
local Types = require(script.Types)

export type Signal<T> = Types.Signal<T>
export type ArrayProxy<T> = Types.ArrayProxy<T>
export type DataProxy<T> = Types.DataProxy<T>
export type Disconnectable = Types.Disconnectable

DataSystem.server = require(script.server)
DataSystem.client = require(script.client)

local function createProxy(getValueFn, setValueFn, subscribeFn)
	local proxy = {}
	local meta = {}

	-- Getter/Setter Call Syntax: data.Gold() or data.Gold(100) or data.Gold(function(c) return c + 1 end)
	meta.__call = function(_, newValue)
		if newValue ~= nil then
			local current = getValueFn()
			local resolved = typeof(newValue) == "function" and newValue(current) or newValue

			-- Sanity guard example: Prevent numbers from dropping below 0
			if typeof(resolved) == "number" and resolved < 0 then
				warn("[DataSystem] Attempted to set negative value, clamping to 0")
				resolved = 0
			end

			setValueFn(resolved)
			return resolved
		else
			return getValueFn()
		end
	end

	meta.__index = function(_, key)
		-- Signal Connection
		if key == "changed" then
			return {
				Connect = function(_, callback)
					return subscribeFn(callback)
				end,
			}
		-- Array Method: insert(item, pos?)
		elseif key == "insert" then
			return function(item, pos: number?)
				local current = getValueFn()
				if typeof(current) == "table" then
					local updated = table.clone(current)
					if pos then
						table.insert(updated, pos, item)
					else
						table.insert(updated, item)
					end
					setValueFn(updated)
				end
			end
		-- Array Method: remove(pos?)
		elseif key == "remove" then
			return function(pos: number?)
				local current = getValueFn()
				if typeof(current) == "table" then
					local updated = table.clone(current)
					local index = pos or #updated
					local removed = table.remove(updated, index)
					setValueFn(updated)
					return removed
				end
			end
		end

		-- Child Property Subscripting
		return createProxy(function()
			local current = getValueFn()
			return typeof(current) == "table" and current[key] or nil
		end, function(val)
			local current = getValueFn()
			if typeof(current) == "table" then
				local updated = table.clone(current)
				if typeof(val) == "function" then
					updated[key] = val(current[key])
				else
					updated[key] = val
				end
				setValueFn(updated)
			end
		end, function(callback)
			local lastVal = nil
			return subscribeFn(function(newTable)
				if typeof(newTable) == "table" then
					local childVal = newTable[key]
					-- Only fire listeners if the specific property changed
					if childVal ~= lastVal then
						lastVal = childVal
						callback(childVal)
					end
				end
			end)
		end)
	end

	return setmetatable(proxy, meta)
end

function DataSystem.CreateProxy(getValueFn, setValueFn, subscribeFn)
	return createProxy(getValueFn, setValueFn, subscribeFn)
end

return DataSystem
