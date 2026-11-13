-- VendorMark
-- Alt+Left-Click an item in your bags to mark/unmark it for vendoring.
-- At a merchant, click "Sell Marked + Junk" on the bag window to sell
-- everything you've marked plus everything Blizzard already flags as junk.

local ADDON_NAME = ...
local VM = CreateFrame("Frame")

local SELLS_PER_TICK = 6      -- items sold per batch
local TICK_DELAY     = 0.25   -- seconds between batches (avoids "object is busy")
local ICON_TEXTURE   = "Interface\\Buttons\\UI-GroupLoot-Coin-Up"

local merchantOpen = false
local selling = false

local function Print(msg)
    print("|cffffd200VendorMark:|r " .. msg)
end

local function IsMarked(itemID)
    return itemID and VendorMarkDB and VendorMarkDB.items[itemID] or false
end

---------------------------------------------------------------------------
-- Bag button overlays
---------------------------------------------------------------------------

local hookedButtons = {}

local function GetButtonItemID(button)
    local bag, slot = button:GetBagID(), button:GetID()
    if not bag or not slot then return nil end
    return C_Container.GetContainerItemID(bag, slot)
end

local function UpdateButtonOverlay(button)
    local overlay = button.VendorMarkIcon
    if not overlay then return end
    overlay:SetShown(IsMarked(GetButtonItemID(button)))
end

local function ToggleMark(button)
    local bag, slot = button:GetBagID(), button:GetID()
    local info = bag and slot and C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID then return end
    local itemID = info.itemID
    local name = info.hyperlink or C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
    if VendorMarkDB.items[itemID] then
        VendorMarkDB.items[itemID] = nil
        Print("Unmarked " .. name)
    else
        -- Use the bag slot's own "no value" flag: it's what the vendor itself
        -- checks, and unlike item info it's always available for bag items.
        if info.hasNoValue then
            Print(name .. " has no vendor value; it can't be sold.")
            return
        end
        VendorMarkDB.items[itemID] = true
        Print("Marked " .. name .. " for vendoring")
    end
    VM:RefreshAll()
end

local function HookButton(button)
    if hookedButtons[button] then return end
    hookedButtons[button] = true

    local icon = button:CreateTexture(nil, "OVERLAY", nil, 7)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetSize(16, 16)
    icon:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 2)
    icon:Hide()
    button.VendorMarkIcon = icon

    button:HookScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" and IsAltKeyDown()
            and not IsShiftKeyDown() and not IsControlKeyDown() then
            ToggleMark(self)
        end
    end)
end

local function UpdateContainerFrame(frame)
    if not frame or not frame.EnumerateValidItems then return end
    for _, button in frame:EnumerateValidItems() do
        HookButton(button)
        UpdateButtonOverlay(button)
    end
end

function VM:RefreshAll()
    if not ContainerFrameUtil_EnumerateContainerFrames then return end
    for _, frame in ContainerFrameUtil_EnumerateContainerFrames() do
        if frame:IsShown() then
            UpdateContainerFrame(frame)
        end
    end
end

local function HookContainerFrames()
    if not ContainerFrameUtil_EnumerateContainerFrames then return end
    for _, frame in ContainerFrameUtil_EnumerateContainerFrames() do
        if frame.UpdateItems then
            hooksecurefunc(frame, "UpdateItems", UpdateContainerFrame)
        end
        frame:HookScript("OnShow", UpdateContainerFrame)
    end
end

---------------------------------------------------------------------------
-- Tooltip line
---------------------------------------------------------------------------

local function HookTooltip()
    if not (TooltipDataProcessor and Enum.TooltipDataType) then return end
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if data and IsMarked(data.id) then
            tooltip:AddLine("Marked for vendor (Alt+Click to unmark)", 1, 0.82, 0)
        end
    end)
end

---------------------------------------------------------------------------
-- Selling
---------------------------------------------------------------------------

local function HasBuiltInJunkSell()
    return C_MerchantFrame and C_MerchantFrame.SellAllJunkItems ~= nil
end

local function CollectMarkedSlots(includeGrays)
    local slots = {}
    local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, lastBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local wanted = info and (IsMarked(info.itemID)
                or (includeGrays and info.quality == Enum.ItemQuality.Poor))
            if wanted and not info.hasNoValue and not info.isLocked then
                slots[#slots + 1] = { bag = bag, slot = slot, itemID = info.itemID }
            end
        end
    end
    return slots
end

local function SellJunk()
    if HasBuiltInJunkSell() then
        if not C_MerchantFrame.IsSellAllJunkEnabled or C_MerchantFrame.IsSellAllJunkEnabled() then
            C_MerchantFrame.SellAllJunkItems()
        end
    end
end

local function SellMarked(queue, index, sold)
    if not merchantOpen then
        selling = false
        Print("Merchant closed; stopped selling.")
        return
    end
    local count = 0
    while index <= #queue and count < SELLS_PER_TICK do
        local entry = queue[index]
        -- Re-check the slot still holds the same item before selling it.
        if C_Container.GetContainerItemID(entry.bag, entry.slot) == entry.itemID then
            C_Container.UseContainerItem(entry.bag, entry.slot)
            sold = sold + 1
        end
        index = index + 1
        count = count + 1
    end
    if index <= #queue then
        C_Timer.After(TICK_DELAY, function() SellMarked(queue, index, sold) end)
    else
        selling = false
        if sold > 0 then
            Print(("Sold %d item stack(s)."):format(sold))
        end
    end
end

function VM:SellAll()
    if not merchantOpen then
        Print("You need to be talking to a merchant.")
        return
    end
    if selling then return end
    selling = true

    SellJunk()

    -- If the client has no built-in junk seller, sell gray items ourselves.
    local queue = CollectMarkedSlots(not HasBuiltInJunkSell())
    if #queue == 0 then
        selling = false
        return
    end
    -- Short delay so the junk sale doesn't collide with ours.
    C_Timer.After(TICK_DELAY, function() SellMarked(queue, 1, 0) end)
end

---------------------------------------------------------------------------
-- Sell button (shown on the bag window while a merchant is open)
---------------------------------------------------------------------------

local sellButton

local function AnchorSellButton()
    if not sellButton then return end
    sellButton:ClearAllPoints()
    local combined = ContainerFrameCombinedBags
    local backpack = ContainerFrame1
    if combined and combined:IsShown() then
        sellButton:SetParent(combined)
        sellButton:SetPoint("TOPRIGHT", combined, "BOTTOMRIGHT", -4, -2)
    elseif backpack and backpack:IsShown() then
        sellButton:SetParent(backpack)
        sellButton:SetPoint("TOPRIGHT", backpack, "BOTTOMRIGHT", -4, -2)
    else
        sellButton:SetParent(MerchantFrame)
        sellButton:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", 0, -2)
    end
    sellButton:SetFrameStrata("HIGH")
    sellButton:SetShown(merchantOpen)
end

local function CreateSellButton()
    sellButton = CreateFrame("Button", "VendorMarkSellButton", UIParent, "UIPanelButtonTemplate")
    sellButton:SetSize(150, 22)
    sellButton:SetClampedToScreen(true) -- stay visible if the bags sit at the screen's bottom edge
    sellButton:SetText("Sell Marked + Junk")
    sellButton:SetScript("OnClick", function() VM:SellAll() end)
    sellButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("VendorMark")
        local n = #CollectMarkedSlots()
        GameTooltip:AddLine(("Sells all gray junk plus %d marked stack(s)."):format(n), 1, 1, 1, true)
        GameTooltip:AddLine("Alt+Click bag items to mark/unmark.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    sellButton:SetScript("OnLeave", GameTooltip_Hide)
    sellButton:Hide()

    for _, frame in ipairs({ ContainerFrameCombinedBags, ContainerFrame1 }) do
        if frame then
            frame:HookScript("OnShow", AnchorSellButton)
            frame:HookScript("OnHide", AnchorSellButton)
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_VENDORMARK1 = "/vendormark"
SLASH_VENDORMARK2 = "/vm"
SlashCmdList.VENDORMARK = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "list" then
        local any = false
        for itemID in pairs(VendorMarkDB.items) do
            local _, link = C_Item.GetItemInfo(itemID)
            Print(link or ("item " .. itemID))
            any = true
        end
        if not any then Print("No items marked.") end
    elseif msg == "clear" then
        wipe(VendorMarkDB.items)
        VM:RefreshAll()
        Print("Cleared all marks.")
    elseif msg == "sell" then
        VM:SellAll()
    else
        Print("Alt+Left-Click a bag item to mark/unmark it.")
        Print("/vm list - show marked items")
        Print("/vm clear - remove all marks")
        Print("/vm sell - sell marked items + junk (at a merchant)")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

VM:RegisterEvent("ADDON_LOADED")
VM:RegisterEvent("MERCHANT_SHOW")
VM:RegisterEvent("MERCHANT_CLOSED")
VM:RegisterEvent("BAG_UPDATE_DELAYED")

VM:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        VendorMarkDB = VendorMarkDB or {}
        VendorMarkDB.items = VendorMarkDB.items or {}
        HookContainerFrames()
        HookTooltip()
        CreateSellButton()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        AnchorSellButton()
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        selling = false
        AnchorSellButton()
    elseif event == "BAG_UPDATE_DELAYED" then
        self:RefreshAll()
    end
end)
