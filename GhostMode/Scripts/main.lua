-- ghost visibility / yuexr
local VERSION = '0.2.1'
local modes = {body=false, terraintool=false, backpack=false}
local changed, queued, activePawn = {}, false, nil
local watched, classes = {}, {}
local componentCache, fieldCache = {}, {}
local refresh, ensureBlueprintHook
local function log(text) print('[Ghost Visibility ' .. VERSION .. '] ' .. text .. '\n') end
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result
end
local function key(object) return tostring(object:GetAddress()) end
local function each(array, callback)
    if array == nil then return end
    local hasIterator, iterator = pcall(function() return array.ForEach end)
    if hasIterator and iterator ~= nil then
        array:ForEach(function(_, element) callback(element:get()) end)
    elseif type(array) == 'table' then
        -- unreal arrays aren't always numbered the same way
        for index, object in pairs(array) do
            if type(index) == 'number' then callback(object) end
        end
    else
        error('Unsupported Unreal array: ' .. type(array))
    end
end
local function class(path)
    if valid(classes[path]) then return classes[path] end
    local result = StaticFindObject(path)
    assert(valid(result), 'Required class unavailable: ' .. path)
    classes[path] = result
    return result
end
local function components(actor, kind, callback)
    local id = key(actor)
    local found = componentCache[id]
    if not found then
        found = {}
        componentCache[id] = found
        local actorComponent = class('/Script/Engine.ActorComponent')
        local sceneComponent = class('/Script/Engine.SceneComponent')
        local function collect(component)
            if not valid(component) or not component:IsA(actorComponent) or found[key(component)] then return end
            local owner = component:GetOwner()
            if not valid(owner) or key(owner) ~= id then return end
            found[key(component)] = component
            if component:IsA(sceneComponent) then each(component.AttachChildren, collect) end
        end
        -- start with the actor's own components
        each(actor.BlueprintCreatedComponents, collect)
        each(actor.InstanceComponents, collect)
        -- some parts, like the hose mesh, only show up in these fields
        local actorClass = actor:GetClass()
        local names = fieldCache[key(actorClass)]
        if not names then
            names = {}
            fieldCache[key(actorClass)] = names
            local seen = {}
            while valid(actorClass) do
                actorClass:ForEachProperty(function(property)
                    if property:IsA(PropertyTypes.ObjectProperty) then
                        local name = property:GetFName():ToString()
                        if not seen[name] then names[#names+1], seen[name] = name, true end
                    end
                end)
                actorClass = actorClass:GetSuperStruct()
            end
        end
        for _, name in ipairs(names) do collect(actor[name]) end
    end
    for _, component in pairs(found) do
        if component:IsA(kind) then callback(component) end
    end
end
local function player()
    local kind = class('/Game/Character/DesignAstro.DesignAstro_C')
    local pawn
    for _, controller in ipairs(FindAllOf('AstroPlayerController') or {}) do
        if valid(controller) and controller:IsLocalPlayerController() then
            local candidate = controller.Pawn
            if valid(candidate) and candidate:IsA(kind) then
                assert(not pawn, 'Multiple local astronauts found.')
                pawn = candidate
            end
        end
    end
    assert(pawn, 'Load a save and control your astronaut; exit the vehicle.')
    return pawn
end
local function restoreAll()
    local errors = {}
    for id, entry in pairs(changed) do
        if not valid(entry.component) then changed[id] = nil
        else
            local ok, why = pcall(function() entry.component:SetHiddenInGame(entry.hidden, false) end)
            if ok then changed[id] = nil else errors[#errors+1] = tostring(why) end
        end
    end
    assert(#errors == 0, table.concat(errors, '; '))
end
local function reset()
    modes = {body=false, terraintool=false, backpack=false}
    activePawn, watched = nil, {}
    local ok, why = pcall(restoreAll)
    if not ok then log('Visibility restore failed: ' .. tostring(why)) end
end

local function gather(pawn)
    componentCache = {}
    local primitive = class('/Script/Engine.PrimitiveComponent')
    local fx = class('/Script/Engine.FXSystemComponent')
    local desired, equipment = {}, {}
    local backpack, tool = pawn:GetBackpack(), pawn:GetDeformTool()
    -- raised and open aren't always the same thing
    local backpackExpanded = valid(backpack) and (backpack.IsRaised or backpack:GetOpen())
    local hose = valid(backpack) and backpack.HoseConnection or nil
    local function add(component)
        if valid(component) then desired[key(component)] = component end
    end
    -- keep the backpack, tool and hose separate
    local function tree(root, excluded, secondExcluded)
        local result = {}
        local function visit(actor)
            if not valid(actor) or key(actor) == key(pawn)
                or (valid(excluded) and key(actor) == key(excluded))
                or (valid(secondExcluded) and key(actor) == key(secondExcluded)) or result[key(actor)] then return end
            result[key(actor)] = actor
            local attached = {}
            actor:GetAttachedActors(attached, true)
            each(attached, visit)
            local children = {}
            actor:GetAllChildActors(children, false)
            each(children, visit)
            -- bars, printer, catalogs, etc.
            components(actor, class('/Script/Engine.ChildActorComponent'), function(component)
                visit(component.ChildActor)
            end)
        end
        visit(root)
        for id in pairs(result) do equipment[id] = true end
        return result
    end
    local backpacks, tools = tree(backpack, tool, hose), tree(tool, backpack)
    for id, actor in pairs(tree(hose, backpack, tool)) do tools[id] = actor end
    local openPanels = {}
    local function merge(target, actor, excluded, secondExcluded)
        for id, child in pairs(tree(actor, excluded, secondExcluded)) do target[id] = child end
    end
    if valid(backpack) then
        -- include these even if they aren't attached the usual way
        for _, field in ipairs({'CatalogActor','CatalogCreativeActor','MissionLogActor','CreativeDrone'}) do
            merge(backpacks, backpack[field], tool, hose)
        end
        for _, field in ipairs({'OxygenBarOverlay','PowerBarOverlay','missionLog','catalogCreative',
            'Catalog','Power Bar','Oxygen Bar','Printer Head','Creative Drone Slot'}) do
            local component = backpack[field]
            if valid(component) then merge(backpacks, component.ChildActor, tool, hose) end
        end
        for _, panel in ipairs({
            {actor='CatalogActor', crackable='CatalogCrackable'},
            {actor='CatalogCreativeActor', crackable='CatalogCrackableCreative'},
            {actor='MissionLogActor', crackable='MissionLogCrackable'}
        }) do
            local actor, crackable = backpack[panel.actor], backpack[panel.crackable]
            if valid(actor) and not valid(crackable) then
                crackable = actor.CrackableActorComponent
            end
            if valid(actor) and valid(crackable) and crackable:GetCracked() then
                merge(openPanels, actor, tool, hose)
            end
        end
    end
    watched = {[key(pawn)]=true}
    for id in pairs(equipment) do watched[id] = true end
    -- don't silently skip the main mesh
    local function gear(actors, mesh, label, slotSources, slotRefs)
        assert(valid(mesh), label .. ' render mesh unavailable.')
        add(mesh)
        local pending = {}
        for _, actor in pairs(actors) do pending[#pending+1] = actor end
        local scheduled = {}
        for id in pairs(actors) do scheduled[id] = true end
        local function enqueue(item)
            if valid(item) and not equipment[key(item)] and not scheduled[key(item)] then
                actors[key(item)], equipment[key(item)], watched[key(item)] = item, true, true
                scheduled[key(item)] = true
                pending[#pending+1] = item
            end
        end
        local function slotsContents(slots)
            if not valid(slots) then return end
            local owner = slots:GetOwner()
            if valid(owner) then watched[key(owner)] = true end
            each(slots.Slots, function(slot) each(slot.SlottedItems, enqueue) end)
        end
        -- shoulder items live on the character
        for _, slots in pairs(slotSources or {}) do slotsContents(slots) end
        for _, refs in pairs(slotRefs or {}) do
            each(refs, function(ref)
                if valid(ref.Component) then
                    each(ref.Component:GetSlotItems(ref), enqueue)
                    local owner = ref.Component:GetOwner()
                    if valid(owner) then watched[key(owner)] = true end
                end
            end)
        end
        local index = 1
        while index <= #pending do
            local actor = pending[index]
            index = index + 1
            components(actor, primitive, add)
            if actor:IsA(class('/Script/Astro.PhysicalItem')) then
                add(actor.StaticMeshComponent)
                slotsContents(actor.SlotsComponent)
            end
            -- also check the actual slots
            components(actor, class('/Script/Astro.SlotsComponent'), slotsContents)
            local attached = {}
            actor:GetAttachedActors(attached, true)
            each(attached, enqueue)
            components(actor, class('/Script/Engine.ChildActorComponent'), function(component)
                enqueue(component.ChildActor)
            end)
        end
    end
    if modes.backpack and not backpackExpanded then
        assert(valid(backpack), 'Backpack unavailable.')
        gear(backpacks, backpack.backpack_mk2, 'Backpack', {pawn.Slots, backpack.Slots}, {backpack.AuxSlots})
    end
    if modes.terraintool then
        assert(valid(tool), 'Terrain tool unavailable.')
        gear(tools, tool['Deform Mesh'], 'Terrain tool', {tool.SlotsComponent},
            {tool['Aug Slots'], {tool['Resource Slot']}})
    end
    -- let opened catalogs show
    if modes.backpack then
        for id, actor in pairs(openPanels) do
            watched[id] = true
            components(actor, primitive, function(component) desired[key(component)] = nil end)
        end
    end
    if modes.body then
        assert(valid(pawn.MeshComponent) and valid(pawn.SkeletalMesh), 'Body meshes unavailable.')
        local function bodyEffect(component)
            if not valid(component) or not component:IsA(fx) then return end
            -- don't hide tool/backpack effects with the body
            local cursor, seen = component, {}
            while valid(cursor) and not seen[key(cursor)] do
                seen[key(cursor)] = true
                local owner = cursor:GetOwner()
                if valid(owner) and equipment[key(owner)] then return end
                cursor = cursor:GetAttachParent()
            end
            add(component)
        end
        for _, field in ipairs({'MeshComponent', 'SkeletalMesh', 'Hat', 'Mask'}) do
            local mesh = pawn[field]
            if valid(mesh) then
                assert(key(mesh:GetOwner()) == key(pawn), 'Unexpected body mesh owner.')
                add(mesh)
                local descendants = {}
                mesh:GetChildrenComponents(true, descendants)
                each(descendants, bodyEffect)
            end
        end
        -- includes effects attached directly to the character
        components(pawn, fx, bodyEffect)
    end
    return desired
end

local function synchronize(pawn)
    local desired = gather(pawn)
    -- show anything we no longer need to hide
    for id, entry in pairs(changed) do
        if not valid(entry.component) then changed[id] = nil
        elseif not desired[id] then
            entry.component:SetHiddenInGame(entry.hidden, false)
            changed[id] = nil
        end
    end
    for id, component in pairs(desired) do
        if not changed[id] then
            local hidden = component.bHiddenInGame
            assert(type(hidden) == 'boolean', 'Visibility flag unavailable.')
            changed[id] = {component=component, hidden=hidden}
        end
        -- only change this component
        if not component.bHiddenInGame then component:SetHiddenInGame(true, false) end
    end
end

local function command(_, parameters, output)
    local category, action
    if #parameters == 1 then category, action = 'all', parameters[1]:lower()
    elseif #parameters == 2 then category, action = parameters[1]:lower(), parameters[2]:lower() end
    if action == 'hide' then action = 'on' elseif action == 'show' then action = 'off' end
    if (category ~= 'all' and modes[category] == nil) or (action ~= 'on' and action ~= 'off') then
        output:Log('Usage: ghost [body|terraintool|backpack] on/off (hide/show). Case-insensitive.\n')
        return true
    end
    local ok, why = pcall(function()
        local pawn
        if action == 'on' then pawn = player(); activePawn = pawn; ensureBlueprintHook() end
        if category == 'all' then
            for name in pairs(modes) do modes[name] = action == 'on' end
        else modes[category] = action == 'on' end
        if modes.body or modes.terraintool or modes.backpack then synchronize(pawn or (valid(activePawn) and activePawn) or player())
        else restoreAll() end
    end)
    if not ok then reset() end
    output:Log((ok and ('Ghost ' .. category .. ' ' .. action .. '.')
        or ('Ghost Visibility failed; modes reset to off: ' .. tostring(why))) .. '\n')
    return true
end
-- ue4ss needs each spelling registered for mixed-case commands
local function registerCases(word, prefix, index)
    if index > #word then RegisterConsoleCommandHandler(prefix, command); return end
    local letter = word:sub(index,index)
    registerCases(word, prefix .. letter, index+1)
    registerCases(word, prefix .. letter:upper(), index+1)
end
registerCases('ghost', '', 1)

-- start visible when a save loads
RegisterLoadMapPostHook(reset)
RegisterHook('/Script/Astro.AstroGameState:HandleOnGameplayStartedEvent', function() end,
    reset)

-- one refresh per event burst, no polling
refresh = function()
    if queued or not valid(activePawn) or (not modes.body and not modes.terraintool and not modes.backpack) then return end
    queued = true
    ExecuteWithDelay(1, function()
        ExecuteInGameThread(function()
            queued = false
            if not modes.body and not modes.terraintool and not modes.backpack then return end
            local ok, why = pcall(function()
                if valid(activePawn) then ensureBlueprintHook(); synchronize(activePawn) else reset() end
            end)
            if not ok then log('Refresh failed: ' .. tostring(why)); reset() end
        end)
    end)
end
local function relevant(context, owner)
    if not valid(activePawn) or (not modes.body and not modes.terraintool and not modes.backpack) then return end
    local object = context:get()
    if owner and valid(object) then object = object:GetOwner() end
    if valid(object) and watched[key(object)] then refresh() end
end
local function hook(path, owner)
    RegisterHook(path, function() end, function(context) relevant(context, owner) end)
end
hook('/Script/Astro.AstroCharacter:AttachEffectsToCustomizationMesh', false)
hook('/Script/Astro.AstroCharacter:ToggleDeformTool', false)
hook('/Script/Astro.SlotsComponent:EmplaceSlotItem', true)
hook('/Script/Astro.SlotsComponent:ReleaseItem', true)
hook('/Script/Astro.SlotsComponent:ReleaseItemWithEjectionImpulse', true)
hook('/Script/Engine.Actor:OnRep_AttachmentReplication', false)
hook('/Script/Astro.AstroCharacter:ReapplySavedCharacterCustomization', false)
hook('/Script/Engine.ChildActorComponent:OnRep_ChildActor', true)
hook('/Script/Engine.ChildActorComponent:TryCallOnChildLoadedEvent', true)
hook('/Script/Astro.CrackableActorComponent:SetCracked', true)
hook('/Script/Astro.CrackableActorComponent:OnRep_CrackedAndExaminable', true)
hook('/Script/Astro.Backpack:OnItemInSlotChanged', false)
hook('/Script/Astro.Backpack:OnRep_Catalog', false)
hook('/Script/Astro.Backpack:OnRep_MissionLog', false)
hook('/Script/Astro.Backpack:OnRep_CreativeDrone', false)
hook('/Script/Astro.Backpack:SetOpen', false)
hook('/Script/Astro.Backpack:ToggleOpen', false)
hook('/Script/Astro.Backpack:OnBackpackAttachedDisplayCrackedChanged', false)
local blueprintHooked = {}
ensureBlueprintHook = function()
    local paths = {
        '/Game/Character/DesignAstro.DesignAstro_C:ApplyCharacterCustomization',
        '/Game/Items/BackpackRail.BackpackRail_C:Backpack Cracked',
        '/Game/Items/BackpackRail.BackpackRail_C:Backpack Closed'
    }
    for _, owner in ipairs({
        '/Game/ControlPanels/Missions/MissionsControlPanel_Backpack.MissionsControlPanel_Backpack_C',
        '/Game/Items/Catalog/BackpackCatalog.BackpackCatalog_C'
    }) do
        for index=0,1 do
            paths[#paths+1] = owner .. ':BndEvt__CrackableActorComponent_K2Node_ComponentBoundEvent_'
                .. index .. '_OnCrackedStateChanged__DelegateSignature'
        end
    end
    for _, path in ipairs(paths) do
        if not blueprintHooked[path] and valid(StaticFindObject(path)) then
            -- native calls can skip the other hooks, so catch these too
            RegisterHook(path, function(context) relevant(context, false) end)
            blueprintHooked[path] = true
        end
    end
end
log('Loaded. ghost on/off; body / terraintool / backpack on/off. All modes start off.')
