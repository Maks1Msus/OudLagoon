-- Ordinary world pickup, available independently of DebugService.
return {
    Enabled = true,
    StandName = "SwordStand",
    -- Set Position = Vector3.new(x, y, z) to choose a location on your map.
    -- Otherwise the stand appears beside the first SpawnLocation.
    Position = nil,
    SpawnOffset = Vector3.new(8, 0, 0),
    FallbackPosition = Vector3.new(8, 0, 0),
    MaxActivationDistance = 8,
    HoldDuration = 0.2,
    RequestCooldown = 0.5,
}
