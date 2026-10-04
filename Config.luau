local Config = {
	DataStoreName = "PlayerData_v1",
	AutoSaveInterval = 300,
	AutoSaveStagger = 1,
	MaxRetries = 3,
	SessionLockTimeout = 660,
	RejoinCooldown = 5,
	-- Migrations[1] upgrades data from Version 1 to Version 2.
	-- Set template._Metadata.Version to 2 when that schema ships.
	Migrations = {},
	template = {
		_Metadata = {
			Version = 1,
			LastSaveTime = 0,
		},
	},
}

return Config
