-- Handles inventory drag gestures, slot feedback and drops using the game's equip rules.
--
-- Drag a weapon, throwable or charm from the Status & Inventory list and drop
-- it on one of the equip slots in the middle column. The vanilla
-- click -> Equip -> choose slot flow is untouched.
--
-- How it works (runtime only, nothing is written to game files):
--   * A post-hook on GameMenu_C:Tick polls each inventory entry's button.
--     UCommonButtonBase::IsPressed stays true while the mouse is held, even
--     after the cursor leaves the button, so press/move/release can be tracked
--     without overriding any input handlers.
--   * While dragging, a copy of the item icon follows the cursor and slots
--     that can't take the item are dimmed.
--   * FGeometry can't be passed through UE4SS, so the ghost is positioned
--     from GetMousePositionOnViewport (the menu's root canvas spans the
--     viewport) and the drop target is the slot Slate reports as hovered in
--     the frames after release. The press holds mouse capture, so hover is
--     stale until the cursor moves: the mod nudges the cursor by one pixel and
--     back, and temporarily makes the slots hit-testable.
--   * On release over a compatible slot the mod sets the menu's
--     ItemWe'reActioningOn and calls GameMenu_C:ToggleItemInSlot(SlotIndex),
--     the same function the vanilla slot buttons call, so equip/swap rules,
--     badges and stat refreshes are the game's own. Releasing outside the
--     button never fires its click, so no item menu pops up.
--   * Throwables still need a knife belt: without one the mod opens the
--     vanilla equip menu, which shows the game's own message.
--
local B = ...

local Config = {
    DragThreshold = 12, -- cursor travel (screen px) before a press becomes a drag
    GhostSize = 64, -- size of the icon in the fallback drag card
    CardOpacity = 1.0, -- drag card opacity
    SourceOpacity = 0.4, -- the list row you're dragging from, while dragging
    RejectOpacity = 0.55, -- drag card opacity while over a slot that can't take the item
    HoverLift = 1.03, -- scale of a slot that can take the item while hovered (1 = off)
    DimOpacity = 0.35, -- opacity of slots that can't take the dragged item
    Sounds = true, -- menu click on a drop, error sound on a rejected drop
    FlashFrames = 24, -- length of the slot flash after a drop (frames)
    Verbose = false, -- log each drag and drop decision to UE4SS.log
}

local SoundDrop = "/Game/Audio/AudioSource/MenuClick.MenuClick"
local SoundReject = "/Game/Audio/AudioSource/EnergyError_Cue.EnergyError_Cue"
local FlashTarget = { R = 1.6, G = 1.6, B = 1.3 } -- slot that received the item
local FlashBumped = { R = 1.7, G = 1.25, B = 0.7 } -- where a displaced item ended up
local FlashReject = { R = 1.6, G = 0.6, B = 0.6 }

local MenuClass = "/Game/UI/Menus/GameMenu.GameMenu_C"
local TickPath = MenuClass .. ":Tick"
local SlotNames = {
    "WeaponSlot_1",
    "WeaponSlot_2",
    "WeaponSlot_3",
    "DaggerSlot1",
    "DaggerSlot2",
    "DaggerSlot3",
    "AccessorySlot1",
    "AccessorySlot2",
    "AccessorySlot3",
}
-- ItemEquipSlotType values as read at runtime (verified in game):
-- 1 Accessory, 2 Dagger (throwables), 3 Weapon. The enumerator names in the
-- asset (NewEnumerator0/1/3) don't match these values.
local SlotCountField = { [1] = "AccessorySlotCount", [2] = "DaggerSlotCount", [3] = "WeaponSlotCount" }
local DaggerType = 2

local WarnedNoIsPressed = false

local Libs = {}
local Drag = nil -- { Menu, Entry, Item, Start, Active, Ghost, Dimmed, SavedNoHoverFocus }
local Pending = nil -- { Menu, Item, Frames }: released drag waiting for Slate to report the hovered slot
local PendingFrames = 20
local PostDrop = nil -- { Menu, Slot, Item, Before, Frames }: equip done, waiting to diff the slots
local Effects = {} -- active flashes
local ResolveDrop -- shared by the release and hover-probe paths

local function Log(Message)
    print("[BBM] Inventory: " .. tostring(Message) .. "\n")
end

local function Debug(Message)
    if Config.Verbose then
        Log(Message)
    end
end

local function Valid(Object)
    if Object == nil then
        return false
    end
    local Ok, Result = pcall(function()
        return Object:IsValid()
    end)
    return Ok and Result == true
end

local function IsSameObject(A, B)
    if not Valid(A) or not Valid(B) then
        return false
    end
    return A:GetAddress() == B:GetAddress()
end

local function Lib(Path)
    local Cached = Libs[Path]
    if Valid(Cached) then
        return Cached
    end
    local Found = StaticFindObject(Path)
    if Valid(Found) then
        Libs[Path] = Found
        return Found
    end
    return nil
end

local function WidgetLayout()
    return Lib("/Script/UMG.Default__WidgetLayoutLibrary")
end

local function SlateLib()
    return Lib("/Script/UMG.Default__SlateBlueprintLibrary")
end

local function MouseAbsolute()
    local Pos = WidgetLayout():GetMousePositionOnPlatform()
    return { X = Pos.X, Y = Pos.Y }
end

local function MouseViewport(Menu)
    local Pos = WidgetLayout():GetMousePositionOnViewport(Menu)
    return { X = Pos.X, Y = Pos.Y }
end

local function ItemName(Item)
    if not Valid(Item) then
        return "?"
    end
    local Ok, Name = pcall(function()
        return Item:GetFName():ToString()
    end)
    return Ok and Name or "?"
end

-- ---------------------------------------------------------------------------
-- Equip rules

local function GetEquipmentSlots(Menu)
    local List = {}
    for _, Name in ipairs(SlotNames) do
        local Slot = Menu[Name]
        if Valid(Slot) then
            List[#List + 1] = Slot
        end
    end
    return List
end

local function GetActiveSaveSlot(Menu)
    local GameInstance = Lib("/Script/Engine.Default__GameplayStatics"):GetGameInstance(Menu)
    if Valid(GameInstance) and Valid(GameInstance.ActiveSaveSlot) then
        return GameInstance.ActiveSaveSlot
    end
    return nil
end

local function SlotUnlocked(Menu, Slot)
    local Field = SlotCountField[Slot.SlotType]
    if Field == nil then
        return false
    end
    local Ok, Count = pcall(function()
        return Menu["Player Config"][Field]
    end)
    if Ok and type(Count) == "number" then
        return Slot.SlotIndex < Count
    end
    return true -- unknown: let the game's own function decide
end

local function CanEquipInSlot(Menu, Slot, Item)
    if not Valid(Slot) or not Valid(Item) then
        return false
    end
    if not Item.Equippable then
        return false
    end
    if Item.EquipSlot ~= Slot.SlotType then
        return false
    end
    if not Slot:IsVisible() then
        return false
    end
    return SlotUnlocked(Menu, Slot)
end

-- Slot ID the item currently occupies (save.EquippedItems: item -> ID), or nil.
local function CurrentSlotID(Item, Menu)
    local Save = GetActiveSaveSlot(Menu)
    if Save == nil then
        return nil
    end
    local Found = nil
    Save.EquippedItems:ForEach(function(Key, Value)
        if IsSameObject(Key:get(), Item) then
            Found = Value:get()
            return true
        end
    end)
    return Found
end

local function SlotID(Menu, Slot)
    local MathLib = Lib("/Game/Player/Assets/Blueprints/PlayerMathFunctions.Default__PlayerMathFunctions_C")
    if MathLib == nil then
        return nil
    end
    return MathLib:GetSlotIDFromSlotTypeAndIndex(Slot.SlotType, Slot.SlotIndex, Menu)
end

-- Mirrors GameMenu's check before it opens the equip menu for a throwable.
local function HasKnifeBelt(Menu, Item)
    local Utils = Lib("/Script/QueensDomain.Default__BlueprintUtils")
    if Utils ~= nil then
        local Ok, DontNeed = pcall(function()
            return Utils:GetDaggerStats(Item).bDontRequireBelt
        end)
        if Ok and DontNeed == true then
            return true
        end
    end
    local SaveUtils = Lib("/Script/QueensDomain.Default__FS_SaveGameUtils")
    if SaveUtils == nil then
        return nil
    end
    local Ok, Count = pcall(function()
        return SaveUtils:GetItemsWithTagCount(Menu, { TagName = FName("ItemTags.KnifeBelt") })
    end)
    if not Ok or type(Count) ~= "number" then
        return nil
    end
    return Count > 0
end

local function EquipDraggedItem(Menu, Slot, Item)
    local Name = ItemName(Item)
    if Item.EquipSlot == DaggerType then
        local Belt = HasKnifeBelt(Menu, Item)
        if Belt == false or Belt == nil then
            -- Let the vanilla flow decide; without a belt it shows the game's message.
            Debug(Name .. ": knife belt check " .. tostring(Belt) .. ", opening vanilla equip menu")
            Menu:OpenEquipItemMenu(Item)
            return "vanilla"
        end
    end

    local Okc, Current = pcall(CurrentSlotID, Item, Menu)
    local Okt, Target = pcall(SlotID, Menu, Slot)
    if Okc and Okt and Current ~= nil and Target ~= nil and Current == Target then
        Debug(Name .. " already in slot " .. tostring(Target) .. ", nothing to do")
        return "noop"
    end

    Menu["ItemWe'reActioningOn"] = Item
    Menu:ToggleItemInSlot(Slot.SlotIndex)
    Debug(
        string.format(
            "%s -> %s (slot id %s, was %s)",
            Name,
            Slot:GetFName():ToString(),
            tostring(Target),
            tostring(Current)
        )
    )
    return "equipped"
end

-- ---------------------------------------------------------------------------
-- Feedback: sounds and flashes

local SoundCache = {}

local function FindSound(Path)
    local Sound = SoundCache[Path]
    if Valid(Sound) then
        return Sound
    end
    Sound = StaticFindObject(Path)
    if not Valid(Sound) then
        pcall(function()
            LoadAsset(Path)
        end)
        Sound = StaticFindObject(Path)
    end
    if Valid(Sound) then
        SoundCache[Path] = Sound
        return Sound
    end
    return nil
end

local function PlaySound(Menu, Path)
    if not Config.Sounds then
        return
    end
    local Sound = FindSound(Path) or FindSound(SoundDrop)
    local Statics = Lib("/Script/Engine.Default__GameplayStatics")
    if Sound == nil or Statics == nil then
        return
    end
    -- The game is paused in the menu, so the sound must be flagged as UI.
    local Ok, Error = pcall(function()
        Statics:PlaySound2D(Menu, Sound, 1.0, 1.0, 0.0, nil, nil, true)
    end)
    if not Ok then
        Debug("PlaySound2D failed: " .. tostring(Error))
    end
end

local function SetTint(Widget, Scale, Color)
    Widget:SetRenderScale({ X = Scale, Y = Scale })
    Widget:SetColorAndOpacity({ R = Color.R, G = Color.G, B = Color.B, A = 1.0 })
end

local function FlashSlot(Widget, Color)
    if not Valid(Widget) then
        return
    end
    for _, Effect in ipairs(Effects) do
        if IsSameObject(Effect.Widget, Widget) then
            Effect.Color, Effect.Frames = Color, 0
            return
        end
    end
    Effects[#Effects + 1] = { Widget = Widget, Color = Color, Frames = 0 }
end

local function UpdateSlotFlashes()
    local Keep = {}
    for _, Effect in ipairs(Effects) do
        if Valid(Effect.Widget) then
            Effect.Frames = Effect.Frames + 1
            local T = 1 - Effect.Frames / Config.FlashFrames -- 1 -> 0
            if T <= 0 then
                pcall(SetTint, Effect.Widget, 1.0, { R = 1, G = 1, B = 1 })
            else
                local E = T * T
                local C = Effect.Color
                pcall(
                    SetTint,
                    Effect.Widget,
                    1 + 0.06 * E,
                    { R = 1 + (C.R - 1) * E, G = 1 + (C.G - 1) * E, B = 1 + (C.B - 1) * E }
                )
                Keep[#Keep + 1] = Effect
            end
        end
    end
    Effects = Keep
end

-- Slot ID -> item, from save.EquippedItemSlots.
local function SnapshotSlots(Menu)
    local Map = {}
    local Save = GetActiveSaveSlot(Menu)
    if Save == nil then
        return Map
    end
    Save.EquippedItemSlots:ForEach(function(Key, Value)
        local Item = Value:get()
        if Valid(Item) then
            Map[Key:get()] = Item
        end
    end)
    return Map
end

-- After a drop, flash the slot that received the item and wherever the item
-- it displaced went (another slot, or back to its inventory entry).
local function ShowDropResult(Menu, Slot, Item, Before)
    FlashSlot(Slot, FlashTarget)
    local Target = SlotID(Menu, Slot)
    local Bumped = Before[Target]
    if not Valid(Bumped) or IsSameObject(Bumped, Item) then
        return
    end
    local After = SnapshotSlots(Menu)
    for _, Other in ipairs(GetEquipmentSlots(Menu)) do
        local Ok, ID = pcall(SlotID, Menu, Other)
        if Ok and ID ~= nil and IsSameObject(After[ID], Bumped) then
            FlashSlot(Other, FlashBumped)
            Debug(ItemName(Bumped) .. " moved to " .. Other:GetFName():ToString())
            return
        end
    end
    Menu.InventoryEntries:ForEach(function(_, Element)
        local Entry = Element:get()
        if Valid(Entry) and IsSameObject(Entry.Item, Bumped) then
            FlashSlot(Entry, FlashBumped)
            Debug(ItemName(Bumped) .. " unequipped")
            return true
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Drag visuals

local function CreateMenuWidget(Menu, ClassPath)
    local Class = Lib(ClassPath)
    if Class == nil then
        error("class not found: " .. ClassPath)
    end
    local Widget = StaticConstructObject(Class, Menu.WidgetTree)
    if not Valid(Widget) then
        error("could not construct " .. ClassPath)
    end
    return Widget
end

-- Fallback card: plain UMG icon + name. Used only if cloning the row fails.
local function CreateSimpleGhost(Menu, Entry, Item)
    local Root = Menu.WidgetTree.RootWidget
    if not Valid(Root) then
        return nil
    end

    local Card = CreateMenuWidget(Menu, "/Script/UMG.Border")
    Card:SetBrushColor({ R = 0.03, G = 0.04, B = 0.03, A = 0.8 })
    Card:SetPadding({ Left = 6, Top = 4, Right = 16, Bottom = 4 })
    Card:SetVisibility(3) -- HitTestInvisible (covers the children too)
    Card:SetRenderOpacity(0.92)

    local Row = CreateMenuWidget(Menu, "/Script/UMG.HorizontalBox")
    Card:SetContent(Row)

    local IconBox = CreateMenuWidget(Menu, "/Script/UMG.SizeBox")
    IconBox:SetWidthOverride(Config.GhostSize)
    IconBox:SetHeightOverride(Config.GhostSize)
    local Icon = CreateMenuWidget(Menu, "/Script/UMG.Image")
    if Valid(Item.ItemIcon) then
        Icon:SetBrushFromTexture(Item.ItemIcon, false)
    end
    IconBox:SetContent(Icon)
    local IconSlot = Row:AddChildToHorizontalBox(IconBox)
    if Valid(IconSlot) then
        IconSlot:SetVerticalAlignment(2)
    end -- VAlign_Center

    local NameOk = pcall(function()
        local Label = CreateMenuWidget(Menu, "/Script/UMG.TextBlock")
        local Source = Entry.ItemDisplay.Itemname
        Label:SetFont(Source.Font)
        Label:SetText(Item.Name)
        Label:SetShadowOffset({ X = 2, Y = 2 })
        Label:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
        local LabelSlot = Row:AddChildToHorizontalBox(Label)
        if Valid(LabelSlot) then
            LabelSlot:SetVerticalAlignment(2)
            LabelSlot:SetPadding({ Left = 8, Top = 0, Right = 0, Bottom = 0 })
        end
    end)
    if not NameOk then
        Debug("drag card without name")
    end

    local Slot = Root:AddChildToCanvas(Card)
    if Valid(Slot) then
        Slot:SetAutoSize(true)
        Slot:SetAlignment({ X = 0, Y = 0.5 })
        Slot:SetZOrder(10000)
    end
    return Card
end

-- The drag card follows the usual drag-preview rules: the dragged thing is
-- solid (not see-through), sits on its own surface with a soft drop shadow so
-- it reads as lifted above the menu, and the row it came from fades to a
-- placeholder. The card is a copy of the game's own InventoryEntry_C row
-- (icon, name, count and "E" render as in the list) on the list panel's dark
-- olive, with a faint light edge like the menu's chiselled panels. The whole
-- card is HitTestInvisible, so it never takes hover or focus.
local Shadow = 6
local Edge = 1
local CardEdgeIdle = { R = 0.62, G = 0.68, B = 0.58, A = 0.4 }

local function CreateGhost(Menu, Entry, Item)
    local Root = Menu.WidgetTree.RootWidget
    local Factory = Lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not Valid(Root) or Factory == nil then
        error("no root canvas / WidgetBlueprintLibrary")
    end

    local Clone = Factory:Create(Menu, Entry:GetClass(), Menu:GetOwningPlayer())
    if not Valid(Clone) then
        error("could not create InventoryEntry copy")
    end
    Clone.Item = Item

    local Stack = CreateMenuWidget(Menu, "/Script/UMG.Overlay")
    Stack:SetVisibility(3) -- HitTestInvisible, covers every child

    local ShadowBox = CreateMenuWidget(Menu, "/Script/UMG.Border")
    ShadowBox:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.3 })
    local ShadowSlot = Stack:AddChildToOverlay(ShadowBox)
    ShadowSlot:SetHorizontalAlignment(0)
    ShadowSlot:SetVerticalAlignment(0)
    ShadowSlot:SetPadding({ Left = Shadow, Top = Shadow, Right = 0, Bottom = 0 })

    local Outline = CreateMenuWidget(Menu, "/Script/UMG.Border")
    Outline:SetBrushColor(CardEdgeIdle)
    Outline:SetPadding({ Left = Edge, Top = Edge, Right = Edge, Bottom = Edge })
    local OutlineSlot = Stack:AddChildToOverlay(Outline)
    OutlineSlot:SetHorizontalAlignment(0)
    OutlineSlot:SetVerticalAlignment(0)
    OutlineSlot:SetPadding({ Left = 0, Top = 0, Right = Shadow, Bottom = Shadow })

    local Surface = CreateMenuWidget(Menu, "/Script/UMG.Border")
    Surface:SetBrushColor({ R = 0.045, G = 0.052, B = 0.035, A = 0.85 })
    Surface:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    Outline:SetContent(Surface)
    Surface:SetContent(Clone)

    -- The row's canvas layout has no intrinsic width; size the card from the
    -- source row: its height, and icon + name + count width.
    local Height = 76
    local Width = 360
    pcall(function()
        local RowSize = Entry:GetDesiredSize()
        if RowSize.Y > 10 then
            Height = RowSize.Y
        end
        local NameSize = Entry.ItemDisplay.Itemname:GetDesiredSize()
        local CountSize = Entry.ItemDisplay.Count:GetDesiredSize()
        Width = math.max(220, 70 + NameSize.X + CountSize.X + 40)
    end)

    local Slot = Root:AddChildToCanvas(Stack)
    if Valid(Slot) then
        Slot:SetAutoSize(false)
        Slot:SetSize({ X = Width + Edge * 2 + Shadow, Y = Height + Edge * 2 + Shadow })
        Slot:SetAlignment({ X = 0, Y = 0.5 })
        Slot:SetZOrder(10000)
    end

    -- Match the list's (possibly column-mod-scaled) name font once built.
    pcall(function()
        Clone.ItemDisplay.Itemname:SetFont(Entry.ItemDisplay.Itemname.Font)
    end)
    Stack:SetRenderOpacity(Config.CardOpacity)
    return Stack, Outline
end

local function MoveGhost(Menu, Ghost)
    local Pos = MouseViewport(Menu)
    -- Cursor on the icon's centre (icon is the row's first 68 units).
    Ghost.Slot:SetPosition({ X = Pos.X - (Edge + 34), Y = Pos.Y + Shadow / 2 })
end

local function DimIncompatibleSlots(Menu, Item)
    local Dimmed = {}
    for _, Slot in ipairs(GetEquipmentSlots(Menu)) do
        local Accepted = CanEquipInSlot(Menu, Slot, Item)
        if not Accepted then
            Slot:SetRenderOpacity(Config.DimOpacity)
            Dimmed[#Dimmed + 1] = Slot
        end
    end
    return Dimmed
end

-- Slots may sit under HitTestInvisible widgets; open them up so Slate can
-- report hover after release. Returns what to restore.
local function MakeSlotsHitTestable(Menu)
    local Changed, Seen = {}, {}
    local function Set(Widget, To)
        local Address = Widget:GetAddress()
        if Seen[Address] then
            return
        end
        Seen[Address] = true
        Changed[#Changed + 1] = { Widget = Widget, Was = Widget:GetVisibility() }
        Widget:SetVisibility(To)
    end
    for _, Slot in ipairs(GetEquipmentSlots(Menu)) do
        local Vis = Slot:GetVisibility()
        if Vis == 3 or Vis == 4 then
            Set(Slot, 0)
        end -- (Self)HitTestInvisible -> Visible
        local Parent = Slot:GetParent()
        while Valid(Parent) do
            if Parent:GetVisibility() == 3 then
                Set(Parent, 4)
            end -- HitTestInvisible -> SelfHitTestInvisible
            Parent = Parent:GetParent()
        end
    end
    return Changed
end

local function RestoreHitTestVisibility(Changed)
    for _, Entry in ipairs(Changed or {}) do
        pcall(function()
            Entry.Widget:SetVisibility(Entry.Was)
        end)
    end
end

local function NudgeCursor(Menu, DX)
    local Pc = Menu:GetOwningPlayer()
    local Scale = WidgetLayout():GetViewportScale(Menu)
    local Pos = MouseViewport(Menu)
    Pc:SetMouseLocation(math.floor(Pos.X * Scale + 0.5) + DX, math.floor(Pos.Y * Scale + 0.5))
end

-- ---------------------------------------------------------------------------
-- Hover tracking during a drag
--
-- While the button is held it owns mouse capture, so Slate reports no hover
-- on the slots, and FGeometry can't be read back through UE4SS. Instead, each
-- slot gets an invisible probe: an instance of the game's UIAspectRatioBox_C
-- (a light widget with a Blueprint Tick) stretched over the slot. A hook on
-- that Tick receives the probe's real geometry, i.e. the slot's rectangle,
-- and tests the cursor against it there. If the probes don't report, drops
-- fall back to the after-release hover check.

local ProbeClass = "/Game/UI/Widgets/UIAspectRatioBox.UIAspectRatioBox_C"
local ProbeTickPath = ProbeClass .. ":Tick"
local Probes = {} -- address -> { Widget, Slot, Over, Frame }
local FrameCounter = 0
local ProbesWork = nil -- nil unknown, true/false once a probe has reported

local function AddProbes(Menu)
    local Class = Lib(ProbeClass)
    local Factory = Lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    if Class == nil or Factory == nil then
        return
    end
    for _, Slot in ipairs(GetEquipmentSlots(Menu)) do
        pcall(function()
            local Root = Slot.WidgetTree.RootWidget
            local Probe = Factory:Create(Menu, Class, Menu:GetOwningPlayer())
            Probe:SetVisibility(3) -- HitTestInvisible
            Probe:SetRenderOpacity(0.01) -- painted (so it ticks) but invisible
            local CanvasSlot = Root:AddChildToCanvas(Probe)
            CanvasSlot:SetAutoSize(false) -- adds nothing to the slot's desired size
            CanvasSlot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
            CanvasSlot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            Probes[Probe:GetAddress()] = { Widget = Probe, Slot = Slot, Over = false, Frame = -10 }
        end)
    end
end

local function RemoveProbes()
    for _, Probe in pairs(Probes) do
        pcall(function()
            Probe.Widget:RemoveFromParent()
        end)
    end
    Probes = {}
end

local function OnProbeTick(Context, Geometry)
    if next(Probes) == nil then
        return
    end
    local Self = Context:get()
    local Probe = Probes[Self:GetAddress()]
    if Probe == nil then
        return
    end
    local Ok, Over = pcall(function()
        local Geo = Geometry:get()
        if ProbesWork == nil then
            local Size = SlateLib():GetLocalSize(Geo)
            ProbesWork = Size.X > 1 and Size.Y > 1
            Log(
                "slot hover probes "
                    .. (ProbesWork and "working" or "report no geometry; using release fallback")
            )
        end
        return SlateLib():IsUnderLocation(Geo, MouseAbsolute()) == true
    end)
    if Ok then
        Probe.Over = Over
        Probe.Frame = FrameCounter
    elseif ProbesWork == nil then
        ProbesWork = false
        Log("slot hover probes failed (" .. tostring(Over) .. "); using release fallback")
    end
end

local function HoveredSlot()
    if ProbesWork ~= true then
        return nil
    end
    for _, Probe in pairs(Probes) do
        if Probe.Over and FrameCounter - Probe.Frame <= 2 and Valid(Probe.Slot) then
            return Probe.Slot
        end
    end
    return nil
end

-- Hover feedback without colour: a slot that takes the item lifts slightly;
-- over a slot that doesn't, the card turns partly see-through.
local function UpdateHoveredSlot(Menu, Slot)
    if IsSameObject(Drag.Hover, Slot) then
        return
    end
    if Valid(Drag.Hover) then
        pcall(function()
            Drag.Hover:SetRenderScale({ X = 1, Y = 1 })
        end)
    end
    Drag.Hover = Slot
    local CardOpacity = Config.CardOpacity
    if Valid(Slot) then
        if CanEquipInSlot(Menu, Slot, Drag.Item) then
            pcall(function()
                Slot:SetRenderScale({ X = Config.HoverLift, Y = Config.HoverLift })
            end)
        else
            CardOpacity = Config.RejectOpacity
        end
    end
    if Valid(Drag.Ghost) then
        pcall(function()
            Drag.Ghost:SetRenderOpacity(CardOpacity)
        end)
    end
end

local function EndDrag()
    if Drag == nil then
        return
    end
    local Current = Drag
    Drag = nil
    if Valid(Current.Entry) and Valid(Current.Entry.FS_Button) then
        pcall(function()
            Current.Entry.FS_Button["Don'tSetFocusWhenHovering"] = Current.SavedNoHoverFocus
        end)
    end
    if Current.Active and Valid(Current.Entry) then
        pcall(function()
            Current.Entry:SetRenderOpacity(1.0)
        end)
    end
    if Current.Ghost ~= nil then
        pcall(function()
            Current.Ghost:RemoveFromParent()
        end)
    end
    if Valid(Current.Hover) then
        pcall(function()
            Current.Hover:SetRenderScale({ X = 1, Y = 1 })
        end)
    end
    RemoveProbes()
    for _, Slot in ipairs(Current.Dimmed or {}) do
        pcall(function()
            Slot:SetRenderOpacity(1.0)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Per-frame tracking

local function PressedEntry(Menu)
    local Pressed = nil
    Menu.InventoryEntries:ForEach(function(_, Element)
        local Entry = Element:get()
        if Valid(Entry) and Valid(Entry.FS_Button) then
            local Ok, IsPressed = pcall(function()
                return Entry.FS_Button:IsPressed()
            end)
            if not Ok and not WarnedNoIsPressed then
                WarnedNoIsPressed = true
                Log("ERROR CommonButtonBase:IsPressed unavailable: " .. tostring(IsPressed))
            end
            if Ok and IsPressed then
                Pressed = Entry
                return true
            end
        end
    end)
    return Pressed
end

local function CursorDistance(A, B)
    local DX, DY = A.X - B.X, A.Y - B.Y
    return math.sqrt(DX * DX + DY * DY)
end

ResolveDrop = function(Menu, Slot, Item)
    if CanEquipInSlot(Menu, Slot, Item) then
        local Okb, Before = pcall(SnapshotSlots, Menu)
        local Result = EquipDraggedItem(Menu, Slot, Item)
        if Result == "equipped" then
            PlaySound(Menu, SoundDrop)
            PostDrop = { Menu = Menu, Slot = Slot, Item = Item, Before = Okb and Before or {}, Frames = 0 }
        elseif Result == "noop" then
            FlashSlot(Slot, FlashTarget)
        end
    else
        Debug(ItemName(Item) .. " can't go in " .. Slot:GetFName():ToString())
        PlaySound(Menu, SoundReject)
        FlashSlot(Slot, FlashReject)
    end
end

local function UpdateInventoryDrag(Context)
    local Menu = Context:get()
    if not Valid(Menu) then
        return
    end

    FrameCounter = FrameCounter + 1
    if #Effects > 0 then
        UpdateSlotFlashes()
    end

    if PostDrop ~= nil then
        if IsSameObject(PostDrop.Menu, Menu) then
            PostDrop.Frames = PostDrop.Frames + 1
            if PostDrop.Frames >= 2 then
                local Done = PostDrop
                PostDrop = nil
                local Ok, Error = pcall(ShowDropResult, Menu, Done.Slot, Done.Item, Done.Before)
                if not Ok then
                    Debug("drop feedback failed: " .. tostring(Error))
                end
            end
        elseif not Valid(PostDrop.Menu) then
            PostDrop = nil
        end
    end

    if Drag ~= nil and not IsSameObject(Drag.Menu, Menu) then
        if Valid(Drag.Menu) then
            return
        end -- a different menu instance is ticking
        EndDrag()
    end

    if Pending ~= nil then
        if not IsSameObject(Pending.Menu, Menu) then
            if Valid(Pending.Menu) then
                return
            end
            Pending = nil
            return
        end
        Pending.Frames = Pending.Frames + 1
        if Pending.Frames == 1 then
            pcall(NudgeCursor, Menu, 1)
        elseif Pending.Frames == 2 then
            pcall(NudgeCursor, Menu, -1)
        end
        for _, Slot in ipairs(GetEquipmentSlots(Menu)) do
            if Slot:IsHovered() then
                local Item = Pending.Item
                RestoreHitTestVisibility(Pending.Changed)
                Pending = nil
                ResolveDrop(Menu, Slot, Item)
                return
            end
        end
        if Pending.Frames >= PendingFrames then
            Debug(ItemName(Pending.Item) .. " released outside the equip slots")
            RestoreHitTestVisibility(Pending.Changed)
            Pending = nil
        end
        return
    end

    if Drag == nil then
        local Entry = PressedEntry(Menu)
        if Entry == nil then
            return
        end
        local Item = Entry.Item
        if not Valid(Item) or not Item.Equippable then
            return
        end
        local Ok, Saved = pcall(function()
            return Entry.FS_Button["Don'tSetFocusWhenHovering"]
        end)
        -- Hovering back over the pressed entry would move focus to it, and the
        -- focus change releases the press; suppress that for the drag.
        pcall(function()
            Entry.FS_Button["Don'tSetFocusWhenHovering"] = true
        end)
        Drag = {
            Menu = Menu,
            Entry = Entry,
            Item = Item,
            Start = MouseAbsolute(),
            Active = false,
            SavedNoHoverFocus = (Ok and Saved == true) or false,
        }
        return
    end

    local StillPressed = Valid(Drag.Entry) and Drag.Entry.FS_Button:IsPressed()
    if StillPressed then
        local Abs = MouseAbsolute()
        if not Drag.Active and CursorDistance(Abs, Drag.Start) >= Config.DragThreshold then
            Drag.Active = true
            Debug(
                string.format(
                    "drag start %s (EquipSlot=%s)",
                    ItemName(Drag.Item),
                    tostring(Drag.Item.EquipSlot)
                )
            )
            local Ok, Ghost, Outline = pcall(CreateGhost, Menu, Drag.Entry, Drag.Item)
            Drag.Outline = Ok and Outline or nil
            if not Ok then
                Log("row-copy drag card failed, using simple card: " .. tostring(Ghost))
                Ok, Ghost = pcall(CreateSimpleGhost, Menu, Drag.Entry, Drag.Item)
            end
            if Ok then
                Drag.Ghost = Ghost
            else
                Log("drag card failed: " .. tostring(Ghost))
            end
            Drag.Dimmed = DimIncompatibleSlots(Menu, Drag.Item)
            if ProbesWork ~= false then
                pcall(AddProbes, Menu)
            end
            pcall(function()
                Drag.Entry:SetRenderOpacity(Config.SourceOpacity)
            end)
        end
        if Drag.Active and Drag.Ghost ~= nil then
            MoveGhost(Menu, Drag.Ghost)
        end
        if Drag.Active then
            UpdateHoveredSlot(Menu, HoveredSlot())
        end
        return
    end

    -- Released: the press owned the mouse capture, so hover is stale until
    -- Slate refreshes it; resolve the target over the next few frames.
    local Finished = Drag
    local Target = Finished.Active and HoveredSlot() or nil
    local ProbesReported = ProbesWork == true
    EndDrag()
    if Finished.Active and ProbesReported then
        if Target ~= nil then
            ResolveDrop(Menu, Target, Finished.Item)
        else
            Debug(ItemName(Finished.Item) .. " released outside the equip slots")
        end
        return
    end
    if Finished.Active then
        local Ok, Changed = pcall(MakeSlotsHitTestable, Menu)
        if not Ok then
            Log("could not open slots for hit testing: " .. tostring(Changed))
            Changed = nil
        end
        Pending = { Menu = Menu, Item = Finished.Item, Frames = 0, Changed = Changed }
    end
end

local function UpdateInventoryDragSafely(Context)
    local Ok, Error = pcall(UpdateInventoryDrag, Context)
    if not Ok then
        B.warn("drag tick", Error)
        pcall(EndDrag)
        if Pending ~= nil then
            RestoreHitTestVisibility(Pending.Changed)
        end
        Pending = nil
        PostDrop = nil
    end
end

B.hook(TickPath, UpdateInventoryDragSafely)
B.hook(ProbeTickPath, OnProbeTick)
table.insert(B.reset, function()
    Drag, Pending, PostDrop, Libs, Effects, Probes, SoundCache = nil, nil, nil, {}, {}, {}, {}
    ProbesWork = nil
end)

Log("loaded")
