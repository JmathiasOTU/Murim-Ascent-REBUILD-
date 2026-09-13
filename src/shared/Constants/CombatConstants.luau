--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatState = require(ReplicatedStorage.Shared.Enums.CombatState)

-- Skeleton only -- the full value table (weapon/skill hit data, cooldowns, hitstop, etc.) is a
-- content pass deferred until after the framework itself is built (see Combat_Framework_Design_Doc
-- Section 11). These four are the only values the design doc has actually confirmed so far.
local CombatConstants = table.freeze({
	PARRY_WINDOW = 0.2,

	PostureRegenRate = 0.035, -- fraction of max posture regenerated per second while not Blocking/Staggered/in Hitstun
	PostureRegenDelay = 1.35, -- seconds after taking posture damage before regen resumes
	ParryPostureRelief = 0.225, -- fraction of max posture restored on a successful parry

	-- Block and Parry share one hold key: pressing it opens a PARRY_WINDOW-long parry attempt;
	-- if nothing gets parried before the window ends (or the key is released first) it's a whiff,
	-- and if the key is still held at that point it drops straight into Blocking instead of Idle --
	-- stays Blocking for as long as the key is held. Not specified in the design doc, picked to
	-- avoid every key movement already owns (W/Q/C/LeftControl/Space, MouseButton1 for M1,
	-- MouseButton2 for RollCancel).
	GuardKey = Enum.KeyCode.F,

	-- Placeholder -- Section 3 names this mechanic ("Whiff -> parry goes on cooldown, forced into
	-- Block-only until it expires") but gives no number (unlike PARRY_WINDOW's confirmed 0.2).
	ParryWhiffCooldown = 1.5,

	CriticalAttackKey = Enum.KeyCode.R,

	-- How long Feinting lasts before returning to Idle -- not specified in the design doc (Section 4
	-- only names the mechanic), placeholder in the same spirit as ParryWhiffCooldown above.
	FeintRecoveryTime = 0.3,

	-- Weapon-agnostic opener (Section 4): sprinting + the M1 input triggers this instead of the combo
	-- chain. Shaped like a per-weapon CriticalAttack sub-table (WeaponTypes.CriticalAttackData) even
	-- though the design doc names these as flat RunningAttack* fields, since every consumer already
	-- expects that shape and it's the same data either way.
	RunningAttack = table.freeze({
		Windup = 0.2,
		Active = 0.12,
		Recovery = 0.3,
		DashDistance = 8,
		DashDuration = 0.15,
		Damage = 10,
		PostureDamage = 12,
		Knockback = 12,
		Cooldown = 4,
		HitstopDuration = 0.08,
		Unparryable = false,
	}),

	-- Movement abilities a dedicated controller owns (DashController/SlideController) must not fire
	-- while combat owns the FSM (Section 4: "cannot break into Dash or Sprint mid-attack") -- most
	-- concretely, Running/Critical Attack's own forward burst and a player-triggered Dash would
	-- otherwise fight over the same rootPart's LinearVelocity constraint. CastingSkill included for
	-- when skills (roadmap step 7) exist, even though nothing sets that state yet.
	CombatLockedStates = table.freeze({
		[CombatState.Attacking] = true,
		[CombatState.Feinting] = true,
		[CombatState.CastingSkill] = true,
	}),

	-- TEMP: no weapon-equip system yet (design doc Section 13) -- every player is assumed to have
	-- this weapon equipped. Single source of truth for AttackController/CombatAnimationController/
	-- CombatValidationService so the three can't drift out of sync; delete once equipping exists.
	PlaceholderEquippedWeaponId = "Fist",
})

return CombatConstants
