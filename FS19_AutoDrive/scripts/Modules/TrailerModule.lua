ADTrailerModule = {}

function ADTrailerModule:new(vehicle)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.vehicle = vehicle
    ADTrailerModule.reset(o)
    return o
end

function ADTrailerModule:reset()
    self.isLoading = false
    self.isUnloading = false
    self.isUnloadingWithTrailer = nil
    self.isUnloadingWithFillUnit = nil
    self.bunkerStartFillLevel = nil
    self.unloadingToBunkerSilo = false
    self.bunkerTrigger = nil
    self.bunkerTrailer = nil
    self.startedLoadingAtTrigger = false
    self.trigger = nil
    self.isLoadingToFillUnitIndex = nil
    self.isLoadingToTrailer = nil
    self.foundSuitableTrigger = false
end

function ADTrailerModule:isActiveAtTrigger()
    return self.isLoading or self.isUnloading
end

function ADTrailerModule:isUnloadingToBunkerSilo()
    return self.unloadingToBunkerSilo
end

function ADTrailerModule:getBunkerSiloSpeed()
    local trailer = self.bunkerTrailer
    local trigger = self.bunkerTrigger
    local fillLevel =  AutoDrive.getFillLevelAndCapacityOf(trailer)

    if trailer ~= nil and trailer.getCurrentDischargeNode ~= nil and fillLevel ~= nil then
        local dischargeNode = trailer:getCurrentDischargeNode()
        if dischargeNode ~= nil and trigger ~= nil and trigger.bunkerSiloArea ~= nil then
            local dischargeSpeed = dischargeNode.emptySpeed
            local unloadTimeInMS = fillLevel / dischargeSpeed

            local dischargeNodeX, dischargeNodeY, dischargeNodeZ = getWorldTranslation(dischargeNode.node)
            local rx, _, rz = localDirectionToWorld(trailer.components[1].node, 0, 0, 1)
            local normalVector = {x = -rz, z = rx}
            
            --                                                                                  vecW
            local x1, z1 = trigger.bunkerSiloArea.sx, trigger.bunkerSiloArea.sz --              1 ---- 2
            --local x2, z2 = trigger.bunkerSiloArea.wx, trigger.bunkerSiloArea.wz--     vecH    | ---- |
            local x3, z3 = trigger.bunkerSiloArea.hx, trigger.bunkerSiloArea.hz --              | ---- |
            --local x4, z4 = x2 + (x3 - x1), z2 + (z3 - z1) --                                  3 ---- 4    4 = 2 + vecH

            local vecH = {x = (x3 - x1), z = (z3 - z1)}
            local vecHLength = MathUtil.vector2Length(vecH.x, vecH.z)
            
            local hitX, hitZ, insideBunker, positive = AutoDrive.segmentIntersects(x1, z1, x3, z3, dischargeNodeX, dischargeNodeZ, dischargeNodeX + 50 * normalVector.x, dischargeNodeZ + 50 * normalVector.z)
            
            --ADDrawingManager:addLineTask(dischargeNodeX, dischargeNodeY + 3, dischargeNodeZ , dischargeNodeX + 50 * normalVector.x,dischargeNodeY + 3, dischargeNodeZ + 50 * normalVector.z, 1, 0, 0)
            --ADDrawingManager:addLineTask(x1, dischargeNodeY + 3, z1 , x3, dischargeNodeY + 3, z3, 1, 0, 0)
            
            if hitX ~= 0 and hitZ ~= 0 then
                --ADDrawingManager:addLineTask(x1, dischargeNodeY + 5, z1 , hitX, dischargeNodeY + 5, hitZ, 0, 0, 1)
                local remainingDistance = vecHLength
                if insideBunker then
                    local drivenDistance = MathUtil.vector2Length(hitX - x1, hitZ - z1)
                    if not positive then
                        drivenDistance = MathUtil.vector2Length(hitX - x3, hitZ - z3)
                    end

                    remainingDistance = vecHLength - drivenDistance
                end

                local speed = ((math.max(1, remainingDistance - 3) / unloadTimeInMS) * 1000) * 3.6 * 1

                return speed
            end
        end
    end
    return 12
end

function ADTrailerModule:update(dt)
    self:updateStates()
    if self.trailerCount == 0 then
        return
    end

    if self.vehicle.ad.stateModule:getCurrentMode():shouldUnloadAtTrigger() then
        self:updateUnload(dt)
    elseif self.vehicle.ad.stateModule:getCurrentMode():shouldLoadOnTrigger() then
        self:updateLoad(dt)
    end
    self:handleTrailerCovers()
    
    self.lastFillLevel = self.fillLevel
end

function ADTrailerModule:handleTrailerCovers()
    local inTriggerProximity = ADTriggerManager.checkForTriggerProximity(self.vehicle, self.vehicle.ad.drivePathModule.distanceToTarget)

    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, inTriggerProximity)
end

function ADTrailerModule:updateStates()
    self.trailers, self.trailerCount = AutoDrive.getTrailersOf(self.vehicle, false)
    self.fillLevel, self.leftCapacity = AutoDrive.getFillLevelAndCapacityOfAll(self.trailers)
    if self.lastFillLevel == nil then
        self.lastFillLevel = self.fillLevel
    end

    --Check for already unloading trailers (e.g. when AD is started while unloading)
    if self.vehicle.ad.stateModule:getCurrentMode():shouldUnloadAtTrigger() then
        for _, trailer in pairs(self.trailers) do
            if trailer.getDischargeState ~= nil then
                local dischargeState = trailer:getDischargeState()
                if dischargeState ~= Dischargeable.DISCHARGE_STATE_OFF then
                    self.isUnloading = true
                    self.isUnloadingWithTrailer = trailer
                    self.isUnloadingWithFillUnit = trailer:getCurrentDischargeNode().fillUnitIndex
                end
            end
        end
    end
end

function ADTrailerModule:updateLoad(dt)
    self:stopUnloading()
    if not self.isLoading then
        local loadPairs = AutoDrive.getTriggerAndTrailerPairs(self.vehicle, dt)
        for _, pair in pairs(loadPairs) do
            --print("Try loading at trigger now - " .. _)
            self:tryLoadingAtTrigger(pair.trailer, pair.trigger, pair.fillUnitIndex)
            self.foundSuitableTrigger = true
        end
    else
        --Monitor load process
        local _, _, fillUnitFull = AutoDrive.getIsFilled(self.vehicle, self.isLoadingToTrailer, self.isLoadingToFillUnitIndex)
        if self.trigger == nil or (not self.trigger.isLoading) then
            if fillUnitFull or AutoDrive.getSetting("continueOnEmptySilo") then
                --print("ADTrailerModule:updateLoad() - fillUnitFull ")
                self.isLoading = false
            --elseif self.trigger ~= nil and self.isLoadingToTrailer ~= nil and self.isLoadingToFillUnitIndex ~= nil then
                --print("ADTrailerModule:updateLoad() - tryLoadingAtTrigger ")
                --self:tryLoadingAtTrigger(self.isLoadingToTrailer,self.trigger, self.isLoadingToFillUnitIndex)
            end
        end
    end
end

function ADTrailerModule:stopLoading()
    self.isLoading = false
end

function ADTrailerModule:stopUnloading()
    self.isUnloading = false
    self.unloadingToBunkerSilo = false
    for _, trailer in pairs(self.trailers) do
        if trailer.setDischargeState ~= nil then
            trailer:setDischargeState(Dischargeable.DISCHARGE_STATE_OFF)
        end
    end
end

function ADTrailerModule:updateUnload(dt)
    self:stopLoading()
    AutoDrive.setAugerPipeOpen(self.trailers,  AutoDrive.getDistanceToUnloadPosition(self.vehicle) <= AutoDrive.getSetting("maxTriggerDistance"))

    if not self.isUnloading then
        -- Check if we can unload at some trigger
        for _, trailer in pairs(self.trailers) do
            local unloadTrigger = self:lookForPossibleUnloadTrigger(trailer)
            if trailer.unloadDelayTimer == nil then
                trailer.unloadDelayTimer = AutoDriveTON:new()
            end
            trailer.unloadDelayTimer:timer(unloadTrigger ~= nil, 250, dt)
            if unloadTrigger ~= nil and trailer.unloadDelayTimer:done() then
                self:startUnloadingIntoTrigger(trailer, unloadTrigger)
                return
            end
        end
    else
        --print("Monitor unloading")
        local _, _, fillUnitEmpty = AutoDrive.getIsEmpty(self.vehicle, self.isUnloadingWithTrailer, self.isUnloadingWithFillUnit)

        if self:areAllTrailersClosed(dt) and (fillUnitEmpty or AutoDrive.getSetting("distributeToFolder", self.vehicle)) then
            self.isUnloading = false
            self.unloadingToBunkerSilo = false
        end
    end
end

function ADTrailerModule:tryLoadingAtTrigger(trailer, trigger, fillUnitIndex)
    local fillUnits = trailer:getFillUnits()

    local i = fillUnitIndex
    if trailer:getFillUnitFillLevelPercentage(i) <= AutoDrive.getSetting("unloadFillLevel", self.vehicle) * 0.999 and (not trigger.isLoading) then
        local trailerIsInRange = AutoDrive.trailerIsInTriggerList(trailer, trigger, i)
        if trigger:getIsActivatable(trailer) and trailerIsInRange then --and not self.isLoading then
            if #fillUnits > 1 then
                --print("startLoadingCorrectFillTypeAtTrigger now - " .. i)
                self:startLoadingCorrectFillTypeAtTrigger(trailer, trigger, i)
            else
                --print("startLoadingAtTrigger now - " .. i .. " fillType: " .. self.vehicle.ad.stateModule:getFillType())
                self:startLoadingAtTrigger(trigger, self.vehicle.ad.stateModule:getFillType(), i, trailer)
            end
            self.isLoading = self.isLoading or trigger.isLoading
        end
    end
end

function ADTrailerModule:startLoadingCorrectFillTypeAtTrigger(trailer, trigger, fillUnitIndex)
    if not AutoDrive.fillTypesMatch(self.vehicle, trigger, trailer) then
        local storedFillType = self.vehicle.ad.stateModule:getFillType()
        local toCheck = {13, 43, 44}

        for _, fillType in pairs(toCheck) do
            self.vehicle.ad.stateModule:setFillType(fillType)
            if AutoDrive.fillTypesMatch(self.vehicle, trigger, trailer, nil, fillUnitIndex) then
                self:startLoadingAtTrigger(trigger, fillType, fillUnitIndex, trailer)
                self.vehicle.ad.stateModule:setFillType(storedFillType)
                return
            end
        end

        self.vehicle.ad.stateModule:setFillType(storedFillType)
    else
        self:startLoadingAtTrigger(trigger, self.vehicle.ad.stateModule:getFillType(), fillUnitIndex, trailer)
    end
end

function ADTrailerModule:startLoadingAtTrigger(trigger, fillType, fillUnitIndex, trailer)
    --print("Start loading at trigger with fillType: " .. fillType .. " and fillUnit: " .. fillUnitIndex)
    trigger.autoStart = true
    trigger.selectedFillType = fillType
    trigger:onFillTypeSelection(fillType)
    trigger.selectedFillType = fillType
    g_effectManager:setFillType(trigger.effects, trigger.selectedFillType)
    trigger.autoStart = false
    trigger.stoppedTimer:timer(false, 300)

    self.isLoading = true
    self.startedLoadingAtTrigger = true
    self.trigger = trigger
    self.isLoadingToFillUnitIndex = fillUnitIndex
    self.isLoadingToTrailer = trailer
end

function ADTrailerModule:lookForPossibleUnloadTrigger(trailer)
    AutoDrive.findAndSetBestTipPoint(self.vehicle, trailer)

    if trailer.getCurrentDischargeNode == nil or self.fillLevel == 0 then
        return nil
    end

    for _, trigger in pairs(ADTriggerManager.getUnloadTriggers()) do
        if trigger.bunkerSiloArea == nil then
            if trailer:getCanDischargeToObject(trailer:getCurrentDischargeNode()) and trailer.setDischargeState ~= nil then
                if (trailer:getDischargeState() == Dischargeable.DISCHARGE_STATE_OFF and trailer.spec_pipe == nil) or (trailer.spec_pipe ~= nil and trailer.spec_pipe.currentState >= 2) then
                    return trigger
                end
            end
        else
            if AutoDrive.isTrailerInBunkerSiloArea(trailer, trigger) then
                return trigger
            end
        end
    end
end

function ADTrailerModule:startUnloadingIntoTrigger(trailer, trigger)
    if trigger.bunkerSiloArea == nil then
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_VEHICLEINFO, "Start unloading - fillUnitIndex: " .. trailer:getCurrentDischargeNode().fillUnitIndex)
        trailer:setDischargeState(Dischargeable.DISCHARGE_STATE_OBJECT)
        self.isUnloading = true
        self.isUnloadingWithTrailer = trailer
        self.isUnloadingWithFillUnit = trailer:getCurrentDischargeNode().fillUnitIndex
    else
        AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_VEHICLEINFO, "Start unloading into bunkersilo - fillUnitIndex: " .. trailer:getCurrentDischargeNode().fillUnitIndex)
        trailer:setDischargeState(Dischargeable.DISCHARGE_STATE_GROUND)
        if self.unloadingToBunkerSilo == false then
            self.bunkerStartFillLevel = self.fillLevel
        end 
        self.isUnloading = true
        self.unloadingToBunkerSilo = true
        self.bunkerTrigger = trigger
        self.bunkerTrailer = trailer
        self.isUnloadingWithTrailer = trailer
        self.isUnloadingWithFillUnit = trailer:getCurrentDischargeNode().fillUnitIndex
    end
end

function ADTrailerModule:areAllTrailersClosed(dt)
    local allClosed = true
    for _, trailer in pairs(self.trailers) do
        local tipState = Trailer.TIPSTATE_CLOSED
        if trailer.getTipState ~= nil then
            tipState = trailer:getTipState()
        end
        local dischargeState = Dischargeable.DISCHARGE_STATE_OFF
        if trailer.getDischargeState ~= nil then
            dischargeState = trailer:getDischargeState()
        end
        if trailer.noDischargeTimer == nil then
            trailer.noDischargeTimer = AutoDriveTON:new()
        end
        --print("Tipstate: " .. tipState .. " dischargeState: " .. dischargeState)
        local senseUnloading = false
        if self.fillLevel ~= nil then
            if self.lastFillLevel == nil or self.lastFillLevel > self.fillLevel or (self.unloadingToBunkerSilo and self.fillLevel > 0) then
                senseUnloading = true
            end
        end
        --print("Tipstate: " .. tipState .. " dischargeState: " .. dischargeState .. " senseUnloading: " .. AutoDrive.boolToString(senseUnloading) .. " lastFillLevel: " .. self.lastFillLevel .. " current: " .. self.fillLevel)
        senseUnloading = senseUnloading or tipState == Trailer.TIPSATE_OPENING or tipState == Trailer.TIPSTATE_CLOSING


        if not trailer.noDischargeTimer:timer((not senseUnloading) or (tipState == Trailer.TIPSTATE_CLOSED and dischargeState == Dischargeable.DISCHARGE_STATE_OFF), 500, dt) then
            allClosed = false
        end
    end

    return allClosed
end

function ADTrailerModule:wasAtSuitableTrigger()
    return self.foundSuitableTrigger
end
