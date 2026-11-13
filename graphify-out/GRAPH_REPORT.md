# Graph Report - OudLagoon  (2026-11-13)

## Corpus Check
- Corpus is ~13,462 words - fits in a single context window. You may not need a graph.

## Summary
- 179 nodes · 323 edges · 13 communities (10 shown, 3 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 3 edges (avg confidence: 0.85)
- Token cost: 40,517 input · 0 output

## Community Hubs (Navigation)
- Combat State Machine
- Debug & Progression Actions
- Combat Animation Client
- Server Combat Logic
- Combat Input & Test UI
- Player Data Persistence
- Framework & Remotes
- Character Stats
- Training Dummies
- Rojo Dev Workflow

## God Nodes (most connected - your core abstractions)
1. `GetRecord()` - 14 edges
2. `CombatStateService:Transition()` - 11 edges
3. `DeepCopy()` - 8 edges
4. `playSlot()` - 8 edges
5. `applyState()` - 8 edges
6. `DataService:LoadProfile()` - 7 edges
7. `enterBlock()` - 7 edges
8. `CombatStateService:ApplyDamage()` - 6 edges
9. `SaveByUserId()` - 6 edges
10. `GetDummies()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `getTrack()` --calls--> `CombatAnimationConfig.GetAnimationId()`  [INFERRED]
  src/StarterPlayer/StarterPlayerScripts/CombatAnimationController.client.lua → src/ReplicatedStorage/Shared/Config/CombatAnimationConfig.lua
- `hasAnimation()` --calls--> `CombatAnimationConfig.GetAnimationId()`  [INFERRED]
  src/StarterPlayer/StarterPlayerScripts/CombatAnimationController.client.lua → src/ReplicatedStorage/Shared/Config/CombatAnimationConfig.lua

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Rojo build-and-serve development workflow** — readme_rojo_build, readme_oudlagoon_rbxlx, readme_roblox_studio, readme_rojo_serve [EXTRACTED 1.00]

## Communities (13 total, 3 thin omitted)

### Community 0 - "Combat State Machine"
Cohesion: 0.11
Nodes (29): CanEnter(), CombatStateService:ApplyDamage(), CombatStateService:CanAttack(), CombatStateService:CanBlock(), CombatStateService:CanDodge(), CombatStateService:Delay(), CombatStateService:GetAttackId(), CombatStateService:GetAttackPhase() (+21 more)

### Community 1 - "Debug & Progression Actions"
Cohesion: 0.09
Nodes (13): Actions.DamageSelf(), Actions.RestoreAll(), GetHumanoid(), BuildPublicProfile(), OnCharacterAdded(), OnPlayerAdded(), PlayerService:Init(), PlayerService:PushProfile() (+5 more)

### Community 2 - "Combat Animation Client"
Cohesion: 0.25
Nodes (18): CombatAnimationConfig.GetAnimationId(), CombatAnimationConfig.IsAssigned(), applyState(), bindCharacter(), debugLog(), enterBlock(), getTrack(), getWeaponId() (+10 more)

### Community 3 - "Server Combat Logic"
Cohesion: 0.21
Nodes (14): CombatService:CalculateDamage(), CombatService.CheckReach(), CombatService:FindTargets(), CombatService:GetWeapon(), CombatService:HandleStateRequest(), CombatService:Init(), CombatService:PerformAttack(), CombatService:RunActiveWindow() (+6 more)

### Community 4 - "Combat Input & Test UI"
Cohesion: 0.17
Nodes (7): getHumanoid(), getWeaponConfig(), requestBlock(), tryAttack(), create(), makeBar(), makeLabel()

### Community 5 - "Player Data Persistence"
Cohesion: 0.30
Nodes (11): CreateDefaultData(), DataService:LoadProfile(), DataService:ReleaseProfile(), DataService:SaveProfile(), DeepCopy(), IsLockedByOtherServer(), KeyFor(), MergeDefaults() (+3 more)

### Community 6 - "Framework & Remotes"
Cohesion: 0.29
Nodes (7): GetOrCreate(), IsAllowed(), RemoteService:GetEvent(), RemoteService:GetFunction(), RemoteService:Init(), RemoteService:OnEvent(), RemoteService:OnFunction()

### Community 7 - "Character Stats"
Cohesion: 0.31
Nodes (6): CalculateMaxHealth(), CalculateMaxMana(), CalculateWalkSpeed(), CharacterService:ApplyStats(), CharacterService:RefreshAttributes(), CharacterService:UpdateDerivedStats()

### Community 8 - "Training Dummies"
Cohesion: 0.38
Nodes (9): CreateR6Model(), GetDummies(), GetOrCreateFolder(), GetSpawnCFrame(), TrainingDummyService:GetCount(), TrainingDummyService:Init(), TrainingDummyService:RemoveAll(), TrainingDummyService:RemoveLast() (+1 more)

### Community 9 - "Rojo Dev Workflow"
Cohesion: 0.47
Nodes (6): OudLagoon (Project README), OudLagoon.rbxlx place file, Roblox Studio, Rojo 7.7.1, rojo build (OudLagoon.rbxlx), rojo serve (live sync server)

## Knowledge Gaps
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Should `Combat State Machine` be split into smaller, more focused modules?**
  _Cohesion score 0.11428571428571428 - nodes in this community are weakly interconnected._
- **Should `Debug & Progression Actions` be split into smaller, more focused modules?**
  _Cohesion score 0.0855614973262032 - nodes in this community are weakly interconnected._