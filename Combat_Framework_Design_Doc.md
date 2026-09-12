# Murim Ascent — Combat Framework Design Doc

**Status: living document, day 1 of planning.** This captures everything locked in so far. Numbers marked "placeholder" are starting points for playtesting, not final balance.

---

## 1. Identity

Parry-based combat (Deepwoken / Nethros / Type Soul lineage), layered onto the existing R6, Rojo, FSM-driven movement framework. Attacks are a **hybrid**: weapon M1 combos as the base loop, unlockable Qi-gated skills layered on top.

## 2. Resources

| Resource | Gates | Notes |
|---|---|---|
| **Qi** | Skills (hotbar slots) | Per-skill cost, defined per skill in a data table |
| **Posture** | How much punishment your defense can absorb | Drains on Block, restored on successful Parry, slow passive regen |
| **Cooldowns** | Parry (after a whiff), Dash, skills | Server-tracked, never client-trusted (per Bouncer philosophy) |

**Posture regen (confirmed):**
- `PostureRegenRate` — slow trickle while not Blocking/Staggered/in Hitstun (placeholder ~3–4%/sec of max)
- `PostureRegenDelay` — grace period after taking posture damage before regen resumes (placeholder ~1.2–1.5s)
- `ParryPostureRelief` — flat/percentage posture restored on a successful parry (placeholder ~20–25% of max) — the mechanical reward for reading a hit instead of blocking it

## 3. Defense triangle

| Tool | Behavior | Cost of failure |
|---|---|---|
| **Parry** | Hard counter, tight forward window from press | Whiff → parry goes on cooldown, forced into Block-only until it expires |
| **Block** | Guaranteed mitigation | Drains posture per hit; posture break → Staggered |
| **Dodge** | Positional escape, i-frames | The answer to `Unparryable`-flagged attacks |

**Parry window model (confirmed):** press-driven forward window, not a before/after buffer. Pressing Parry opens a fixed-length active window (`PARRY_WINDOW`, placeholder `0.2`, matching the master doc's own example); server checks incoming attacks' lag-compensated timestamps against it via `LagCompensationService`. No spam-reset — whiffing costs you the cooldown.

**Parry and Block share one hold key (corrected from an earlier draft that gave them separate keys):** pressing it opens a `PARRY_WINDOW`-long parry attempt; if nothing gets parried before the window ends (or the key is released first), that's a whiff — if the key is still held at that point, it drops straight into `Blocking` instead of `Idle`, and stays there for as long as the key is held. A fresh press while still on the whiff cooldown skips the parry attempt entirely and goes straight to `Blocking` — this is the actual mechanism behind "forced into Block-only until it expires," now that the two tools share an input. `Blocking` and `Parrying` remain two distinct FSM states (Section 5) — only the key/remote is shared, not the state.

**Dodge is not its own input or FSM state — it's the existing ground Dash**, reclassified rather than duplicated (corrected from an earlier draft that gave Dodge its own dedicated key and `Dodging` combat state). The design doc's original reasoning already leaned this way (Section 9: "Dash is untouched — it's short, cooldown-gated, and load-bearing for combat itself"). Mechanically it still lives entirely in the movement layer (`DashController`, `movementFSM`, `MovementValidationService` — see Section 7's Controller/Service split), since it needs ground-validation/velocity machinery combat systems don't have; what changed is that combat's hit resolution (`HitRegistrationService`) now also asks "is this player currently mid-dash" and negates a hit the same way it would for the old dedicated `Dodging` state. Roll-cancelling out of a dash early (Section 8's `RollCancelGraceMultiplier`) is a natural candidate to extend this to later, but isn't wired up yet — only the base dash currently grants it.

**Unparryable attacks:** a `Unparryable = true` flag per attack in `CombatConstants`, not a separate grab system (deferred — see Section 8).

## 4. Attack system

- **M1 combo:** linear chain, M1 → M1 → M1 → M1, 4th hit is a knockback finisher. Per-hit data (damage / hitstun / knockback / posture damage) lives in `CombatConstants`, indexed by combo position — not identical across all 4 hits.
- **Skills:** activated from hotbar slots (Section 4's Skills subsection), each with its own Qi cost + cooldown, defined per-skill in a data table.
- **Feinting:** core mixup mechanic. Cancels the windup of **either** an Attacking combo **or** a Casting Skill, to bait a parry. One `Feinting` state, reachable from both.
- **Movement during attacks:** partial drift/steer allowed mid-swing; cannot break into Dash or Sprint mid-attack (enforced via the cross-FSM lock — see Section 7).
- **Facing:** stays camera-relative, same as current movement. No target-lock system. Directional/back-attack parry checks still work off whatever direction the defender happens to be facing at the moment of impact — doesn't require lock-on to function.
- **Weapon equip:** one weapon/style equipped at a time, chosen before a fight — no mid-fight weapon switching.

### Running attack (weapon-agnostic)

A universal opener, same for every weapon: sprint + attack input triggers a forward dash-burst into a kick, instead of starting the M1 chain.

- **Trigger:** player is in the `Running` movement state (sprinting + moving) and presses the same attack input — no new keybind.
- **Weapon-agnostic:** one shared animation/hit-data set, not per-weapon.
- **FSM:** no new state — a variant *within* `Attacking`, distinguished by an attack identifier (`"RunningAttack"` vs `"M1_1"`–`"M1_4"`) used for animation lookup and `CombatConstants` data lookup, same mechanism combo index already uses.
- **Movement:** short forward `LinearVelocity` burst during the windup, same physical technique as `DashController`'s dash but its own separately-tuned distance/duration — the attack's own kinematic effect, not a player-triggered Dash. Still respects "no breaking into Dash/Sprint mid-swing."
- **Cooldown:** its own dedicated `RunningAttackCooldown`, separate from both the M1 chain and Dash's cooldown.
- **Server validation:** mirrors the Dash pattern — client requests, server checks the player was actually sprinting+moving (a light `CombatValidationService` → `MovementValidationService` query — a fine direct call, since the Pub/Sub rule targets client Controllers, not server Services) plus cooldown, before applying.
- **Default assumption (flag if wrong):** standalone hit — lands, recovers, returns to `Idle`, doesn't auto-chain into the M1 combo. Easy to change later if it should flow into M1s instead.
- **Parryable:** yes, no `Unparryable` flag by default.

Placeholder constants: `RunningAttackWindupTime`, `RunningAttackActiveTime`, `RunningAttackRecoveryTime`, `RunningAttackDashDistance`, `RunningAttackDashDuration`, `RunningAttackDamage`, `RunningAttackPostureDamage`, `RunningAttackKnockback`, `RunningAttackCooldown`.

### Weapon roster (v1)

Light / medium / heavy triad, plus Fist — 4 weapons for launch, up from the original 2–3, since Fist is now mandatory as the unarmed fallback (Section 13) rather than optional. Launch-scoped only — the full roster is expected to keep growing well past these 4, which is exactly why `WeaponDefinitions` is a per-weapon-file aggregator rather than one flat table (Section 7).

| Weapon | Archetype | Combo shape | Identity |
|---|---|---|---|
| **Dagger** | Light | Standard M1×4, same linear shape as Jian | Fast, low per-hit damage/posture damage, sustained pressure — more openings but each one small |
| **Fist** (unarmed) | Fist (own category) | Standard M1×4, same linear shape as Jian | Fast, low per-hit damage, sustained pressure — but its own category for stat-synergy purposes (Section 8), not grouped under Light. No weapon model (Section 13); hitbox lives on the R6 arm parts directly |
| **Jian** (straightsword) | Medium | Standard M1×4 | Baseline reference weapon — `AttackSpeedMultiplier = 1.0`, everything else tunes relative to it |
| **Greatsword** | Heavy | Standard M1×4, heavy tuning | Slow, high damage/posture damage/knockback — forces parry-or-dodge since blocking drains posture fast |

**Corrected: no weapon in the current roster is dual-wielded.** An earlier draft gave Dagger (and, by copying it, Fist) a 5-step alternating-hand combo with two simultaneous hitboxes and a `Hand` field on `ComboData`. None of that reflects the actual design — every weapon here, Dagger and Fist included, uses the same single-hitbox linear `ComboSteps = {"M1_1", "M1_2", "M1_3", "M1_4"}` shape Jian's baseline already establishes. `ComboStepData` carries no `Hand` field. Dagger and Fist share their fast/light identity (low per-hit damage, sustained pressure) with each other, not a structural combo mechanic — only their own `ComboData` numbers and `AttackSpeedMultiplier` differ from Jian's baseline. If a genuinely dual-wielded weapon ever gets designed, it gets this treatment freshly at that point, not inherited from Dagger's old placeholder.

**Fist's only structural difference from the other three:** no weapon model (Section 13) — its hitbox Attachment lives permanently on the R6 arm parts rather than on a cloned/welded model, since there's nothing to equip visually. `Category = "Fist"`, not `"Light"` — a separate stat-synergy axis (Section 8), and the World Building doc treats them distinctly: Male gets "Heavy weapon + Fist synergy" specifically, separate from Female's "Light weapon synergy," so collapsing Fist into Light would have lost that distinction.

**Greatsword — heavy tuning notes:**
- Same 4-step shape as Jian structurally — every `ComboData` value skews harder instead: lower `AttackSpeedMultiplier`, higher `Damage`/`PostureDamage`/`Knockback`.
- Good candidate for `IsStaggerPunish = true` on its finisher (hit 4) — a big two-handed swing landing on an already-staggered opponent as a launcher.

**Jian — the baseline:** standard shape, `AttackSpeedMultiplier = 1.0`. Existing M1×4 numbers from Section 4 apply here as the reference point.

### Critical attacks

Own dedicated input (`CriticalAttackKey`, currently `R`), separate from M1, skills, and the running attack. Weapon-specific — animation, movement, and numbers all vary per weapon, unlike the running attack's shared moveset.

- **Trigger:** usable from `Idle` like any attack entry point. Enters `Attacking` via its own attack identifier (`"Critical"`), same mechanism as combo steps and the running attack — no new FSM state needed.
- **Per-weapon data:** each `WeaponDefinitions` entry gets a `CriticalAttack` sub-table: `Windup`, `Active`, `Recovery`, `DashDistance`/`DashDuration` (0 for a stationary crit), `Damage`, `PostureDamage` (notably higher than any normal hit — the guardbreak number), `Knockback`, `Cooldown`, `Unparryable` (false by default — crits are still parryable/dodgeable, they're specifically dangerous *against Block*).
- **Guardbreak mechanic:** interacts with posture the same way a normal blocked hit does — just a much bigger number. When a crit connects through Block: `EffectivePostureDamage = CriticalAttack.PostureDamage * attacker.PostureDamageDealtMultiplier * defender.PostureDamageTakenMultiplier`, subtracted from current posture same as any blocked hit. Exceeds remaining posture → guard breaks, defender goes `Staggered`. Doesn't → defender stays `Blocking`, just with a much bigger dent than usual. A parried crit is hard-countered as normal; a dodged crit simply misses; an unguarded/raw crit just deals heavy damage + normal `Hitstun` — no posture interaction, since posture is specifically the Block-related resource.
- **Modifier multipliers:** replaces the earlier flat `GuardbreakResistance` placeholder — see Section 8 for the full player-modifier system these come from (gender, body type, temperament, traits, and hidden physiques all stack into them).
- **Weapon crit concepts (flavor, adjust freely):**
  - **Fist:** spin into a forward kick — short `DashDistance`, fast windup. Reassigned here from Dagger now that Fist is a real weapon — this was the original illustrative idea and a kick fits unarmed combat better than a bladed weapon thematically.
  - **Dagger:** a quick double-thrust lunge with a brief repositioning step afterward — short forward `DashDistance`, very fast windup, no kick (doesn't fit a bladed weapon the way it does Fist).
  - **Jian:** sheathe, then a quick-draw unsheathe slash with a short forward step — brief `DashDistance`, snappy `Active` window.
  - **Greatsword:** stands still, big overhead swing in place — `DashDistance = 0`, longest `Windup`/`Recovery` of the three, but the largest `PostureDamage` number.

### Skills / techniques (Qi-gated, hotbar items)

Genuinely open — expect heavy iteration here. This is a flexible skeleton to react to and adjust, not a locked design.

**Hotbar model (Deepwoken-style, revised from the earlier fixed-slot version):** skills are owned items, same as weapons — not tied to fixed slot ranges. A player places any owned skill (or weapon) into any hotbar slot; pressing that slot's key does the context-appropriate thing — equips the weapon there (Section 13's rules apply), or fires the skill there (Qi cost/cooldown/`CastingSkill` rules apply). Weapons and skills share one hotbar system, not two separate ones with their own key ranges.

Two distinct moments, not one: **arranging the hotbar** (deciding what occupies which slot) is a loadout action, gated the same way weapon-swapping already is — out of combat, not tagged. **Pressing an already-configured slot** during a fight is just normal input, no special gating beyond whatever the item itself already requires.

**Generic `SkillDefinitions` shape** — same philosophy as everything else, data-driven, one shared pipeline:

```
SkillDefinitions = {
  [SkillId] = {
    DisplayName = "...",
    QiCost = ...,
    Cooldown = ...,
    TargetingType = "Melee" | "Projectile" | "SelfBuff" | "AreaOfEffect",
    Windup = ..., Active = ..., Recovery = ...,
    Damage = ..., PostureDamage = ..., Knockback = ...,
    Unparryable = false, -- per-skill override; some techniques might genuinely want this true
    RequiredWeaponCategory = nil, -- optional: "Light" | "Medium" | "Heavy" | "Fist" | nil. If set, the skill fails to activate unless a weapon of that category is equipped — checked at cast time, independent of which hotbar slot it's sitting in.
  }
}
```

The shape above is illustrative — on disk, `SkillDefinitions` is an aggregator over one file per skill (`Constants/Skills/<SkillId>.luau`), same as `WeaponDefinitions`/`Constants/Weapons/`. See Section 7's "Weapon/skill data organization."

- **Melee-type skills** reuse the exact same server-authoritative hitbox pipeline as normal attacks (Section 6) — just another entry in `CastingSkill`, identified by skill id instead of combo index. No new systems needed.
- **Area-of-effect skills** also reuse that pipeline, just centered on a fixed point/radius instead of a weapon-attached hitbox.
- **Projectile skills** are the one genuinely new piece — a server-controlled Part that travels over multiple frames (not an instant check), needing its own lightweight `ProjectileService`: spawn on cast, step it forward each Heartbeat (or via `AssemblyLinearVelocity`), raycast/overlap-check per step to avoid tunneling at speed, despawn on hit or max range/lifetime.
- **Self-buff skills** don't need a hitbox at all — a temporary modifier for `BuffDuration`, which can piggyback on the `CombatModifierProfile` concept from Section 8 once that exists (a temporary layer stacked on top of the permanent gender/body/temperament layers), or just a standalone timed flag for now.

**FSM notes:** `CastingSkill` follows the same rules as `Attacking` — partial movement drift allowed, no breaking into Dash/Sprint mid-cast, interruptible into `Hitstun`/`Staggered`, cancelable into `Feinting` (already established). Feinting a skill refunds a **partial** percentage of its Qi cost (placeholder `FeintQiRefundPercentage`, e.g. 50%) rather than the full cost or nothing — canceling isn't free, but it isn't as punishing as eating the full cost for an attack that never landed.

**Status effects (DOT — burn, poison, etc.):** orthogonal to `TargetingType`, not its own category. A flame palm strike is still a `Melee` hit that happens to also apply Burn; a poison dart is a `Projectile` that applies Poison. Composing two independent fields avoids a combinatorial mess of `"MeleeBurn"`/`"ProjectilePoison"`/etc. variants.

```
SkillDefinitions[SkillId] = {
  ...,
  StatusEffect = { -- nil for most skills
    Type = "Burn" | "Poison" | "Bleed" | ...,
    DamagePerTick = ...,
    TickInterval = ...,
    Duration = ...,
    Stacks = true/false, -- re-applying refreshes duration, or stacks damage?
  },
}
```

Needs one small new piece of server infrastructure: a `StatusEffectService` that owns ticking active effects per player (apply on hit, tick on interval, expire on duration), independent of whichever skill/weapon caused it — `HitRegistrationService` just hands off "apply this effect" when a hit carrying one connects. Whether a status effect still applies through a successful Block is left as a per-skill flag (`AppliesOnBlock`, default `false`) rather than a global rule — arguable either way for something elemental, so keep it tweakable. **Different effect types coexist** — Burn and Poison can both be active on the same player simultaneously, each ticking independently. The existing `Stacks` field governs same-type reapplication only (does a second Burn refresh duration or stack damage); it was never meant to gate different types against each other.

**Multi-beat skills (e.g. Plum Blossom Thrust):** some techniques are a sequence of hits inside one cast, not one hit. Generalizes the same ordered-list pattern `ComboSteps` already uses, just nested inside a single skill instead of driven by separate player inputs:

```
SkillDefinitions[SkillId] = {
  DisplayName = "Plum Blossom Thrust",
  QiCost = ..., Cooldown = ...,
  TargetingType = "Melee",
  Interruptible = true, -- a successful Parry or Dodge on any beat cancels the rest. Block doesn't interrupt — it's absorption, not a hard counter — so blocked beats still drain posture and the sequence continues.
  Beats = {
    { Type = "Thrust", TimeOffset = 0.00, Damage = ..., PostureDamage = ..., Knockback = 0 },
    { Type = "Thrust", TimeOffset = 0.15, Damage = ..., PostureDamage = ..., Knockback = 0 },
    { Type = "Thrust", TimeOffset = 0.30, Damage = ..., PostureDamage = ..., Knockback = 0 },
    { Type = "Kick", TimeOffset = 0.50, Damage = ..., PostureDamage = ..., Knockback = <large>, IsGuardbreakBeat = true },
  },
  Recovery = ...,
}
```

`HitRegistrationService` schedules N hitbox-check windows within one cast instead of the usual one, same server-authoritative overlap check each time. Early beats default to zero/minimal knockback (keeps the target in range for the next beat) — knockback lives on the finishing beat, same pattern as an M1×4 finisher. `IsGuardbreakBeat` reuses the exact Critical Attack guardbreak formula from Section 4 (Section 8's `PostureDamageDealtMultiplier`/`PostureDamageTakenMultiplier`) — no new math, it's a mini-crit riding on one beat.

**Skill acquisition — three pools, describing how a skill is obtained, not which hotbar slot it belongs in (slots are now free-form — see the hotbar model above):**
- **Universal/baseline** — fixed pool, everyone has access.
- **Clan/sect-granted** — tied to the Families/Clans system (Section 11). Weapon-independent, same as Universal.
- **Weapon-mastery-unlocked** — obtained through a specific weapon, but usable from any hotbar slot once owned. If it genuinely only makes sense with that weapon in hand, that's expressed via `RequiredWeaponCategory` on the skill itself, not by restricting which slot it can occupy.

The earlier open question about a clan technique not translating to Fist is resolved by the same field — if a technique doesn't make sense unarmed, `RequiredWeaponCategory` on that skill just excludes Fist, rather than needing per-weapon-category animation variants for every clan skill.

### Aerial attacks

Same trigger pattern as the running attack: M1 becomes context-sensitive again, this time off the movement layer's `Falling` state rather than `Running`.

- **Trigger:** requires `movementFSM:GetState() == Falling` specifically — not `Jumping`. Restricting to the descent (not the ascent) forces a real commitment window an opponent can see and react to, rather than an instant near-zero-telegraph poke off a jump press. Own `AerialAttackCooldown`.
- **Ownership tier:** per weapon **category** (Light/Medium/Heavy/Fist), not fully universal like the running attack and not per-individual-weapon like criticals — a new middle tier, keyed off the same `Category` field `WeaponDefinitions` already needs for Section 8's synergy checks. Fist gets its own entry here too, not a reuse of Light's.

```
AerialAttackDefinitions = {
  [Category] = { -- "Light" | "Medium" | "Heavy" | "Fist"
    Windup = ..., Active = ..., Recovery = ...,
    DiveSpeed = ..., -- downward velocity applied during the dive
    Damage = ..., PostureDamage = ..., Knockback = ...,
    Cooldown = ...,
    Unparryable = false,
  }
}
```

- **Landing interaction:** a successful hit sets a short-lived server-side flag — same pattern as `MovementValidationService`'s existing `dashSpeedExemptUntil` — that `AirborneController._onLanded` checks before assessing fall speed. Flag set → skip `LightLanding`/`HeavyLanding` entirely, go straight to a clean recovery. Flag not set (missed) → normal fall-speed landing assessment applies, and since `DiveSpeed` adds to how fast they were already falling, a whiff is genuinely risky, not just a wasted cooldown.

## 5. Combat FSM states

Reuses the existing generic `FiniteStateMachine<State>` module directly — `combatFSM = FiniteStateMachine.new(CombatState.Idle)`, same pattern as `movementFSM`.

| State | Entered from | Notes |
|---|---|---|
| `Idle` | — | Combat-neutral hub state |
| `Attacking` | Idle (M1) | 4-hit linear combo, combo index tracked as data not sub-states |
| `Feinting` | Attacking or CastingSkill | Cancels windup, baits a parry |
| `CastingSkill` | Idle (hotbar slot press) | Qi-gated skill execution |
| `Parrying` | Idle (guard key pressed) | Short-lived, `PARRY_WINDOW` duration. Shares its key with Blocking (Section 3) — a whiff drops into `Blocking` instead of `Idle` if the key is still held |
| `Blocking` | Idle (guard key held), or Parrying (whiff/success while key still held) | Held state, exits on key release or posture break |
| `Hitstun` | Any (took a non-posture-breaking hit) | Short, generic reaction, no guaranteed punish |
| `Staggered` | Any (posture broke) | Distinct animation, longer lockout, guaranteed punish window. Optional launcher via `IsStaggerPunish` flag on the follow-up hit |
| `Defeated` | Any (HP reaches 0) | Overrides every other state immediately, including mid-vent. See notes below. |

No `Dodging` state — that's the ground Dash (movement layer), not a combat FSM state (Section 3).

All states return to `Idle` when their action ends, except Parrying → Blocking when the guard key is still held, Blocking → Staggered on posture break, and any state → Defeated on HP reaching 0.

**`Defeated`, added late but needed before Phase 2 testing:** damage was designed extensively but nothing previously stopped HP from going negative while combat continued normally. `HitRegistrationService` checks HP after applying damage and transitions to `Defeated` unconditionally — it interrupts *anything*, including `Staggered` mid-vent, since death should always override. Ragdoll on entry (R6: break the Motor6Ds and replace with `BallSocketConstraint`s between limbs, or `Humanoid:ChangeState(Enum.HumanoidStateType.Ragdoll)` if that state's enabled). Locks out all combat/movement input. What actually happens afterward — respawn, loot, penalties — stays explicitly deferred (Section 11); this only defines the state existing so the framework has *somewhere* to go at 0 HP, not what follows it.

## 6. Hit detection

**Server-authoritative hitbox parts**, not raycasts or client-reported hits:
- Weapon model carries a real hitbox Part/Attachment.
- Client plays the swing animation immediately (prediction, feel).
- Server independently runs an `OverlapParams`/`GetPartsInPart` query on that hitbox during the attack's active-frame window (start/end times data-driven per attack in `CombatConstants`, same throttling pattern `SlideController` already uses).
- Server decides whether a hit landed — client can't just fire a remote claiming a hit.

### Lag compensation

Originally scoped to parry legality only (Section 3). Expanded to cover hit *landing* for every attack type, melee and projectile alike — almost every hit-check above reads a target's live position, which is exactly what the master doc's own fairness argument (don't punish high-ping players by validating only on one side's clock) warns against.

**History buffer:** `LagCompensationService` keeps a per-player ring buffer, sampled every server Heartbeat, retained for a clamped max window (`MaxRewindWindow`, placeholder ~200ms). Each sample records position/orientation **and** a lightweight `IsInvulnerable` boolean (true while the ground Dash's i-frames are active — Section 3's "Dodge is the ground Dash," not a dedicated `Dodging` state) — not just where the player was, but whether they were hittable at all.

**Reconstruction, without desyncing anyone visually:** a pooled, invisible, non-colliding "hurtbox proxy" part per player — repositioned to the rewound CFrame for the query, then parked for reuse. Pooled, not created/destroyed per hit, per the master doc's GC-defense rule.

**Resolution flow, used by every attack type (M1, criticals, melee/AOE skills, aerial, running attack, and projectiles):**
1. Compute the attacker's effective time: `serverTime - attackerMeasuredLatency`, clamped to `MaxRewindWindow`. Never derived from a client-reported timestamp — same Bouncer principle as everything else server-authoritative in this doc.
2. Look up (interpolating between buffered samples) each potential victim's position **and** `IsInvulnerable` flag at that effective time.
3. If `IsInvulnerable` was true at that moment, the hit is negated outright — a geometrically-overlapping swing during a historical dodge still misses, exactly as it should have looked from the attacker's own screen.
4. Otherwise, run the normal `OverlapParams` check against the rewound proxy position instead of the target's live CFrame.

**Projectiles:** same lookup, applied per-step as the projectile travels rather than once — `ProjectileService` checks each potential victim's rewound position/invulnerability at the projectile's current effective time on every step, not just at spawn. Keeps a fast dagger throw and a slow-arcing skill both fair to the thrower without either side gaining an unintended advantage from travel time.

**The clamp matters both ways:** `MaxRewindWindow` protects defenders from an extreme-ping attacker rewinding an unreasonable amount (the classic "shot around a corner" problem) while staying generous enough to cover normal play.

### Hitstop / hitlag

Required by the master doc (Section 4) but missing from every attack type designed so far — folding it in now rather than discovering it's missing mid-implementation.

**Data-driven per attack, not hardcoded:** every attack/skill/crit/aerial-attack's data table gets a `HitstopDuration` field (placeholder small values, e.g. 0.05–0.12s scaled to impact weight — a Greatsword hit should feel heavier/longer than a Dagger jab). Lives alongside `Damage`/`PostureDamage`/`Knockback` in the same data tables already established — no new data structure, just one more field.

**Mechanism:** on a hit landing (not a miss, not a parried-away swing), both attacker and victim get a synchronized brief freeze. Server-side, this means delaying the next phase transition (the attack's own Recovery, and the victim's `Hitstun`/`Staggered` entry) by `HitstopDuration` — not just a cosmetic pause while underlying timers keep ticking, since that would let hitstop unfairly shorten an attacker's recovery or unpredictably lengthen a punish window. Client-side, both characters' `AnimationTrack.Speed` briefly drops to near-zero for the same duration, for the actual felt impact.

**Scheduling:** `task.delay` keyed to `os.clock()`, tracked in the same `activeTasks` registry pattern the master doc already mandates for GC defense — never a raw `wait()`/`task.wait()`, and never left unregistered if a later state change needs to cancel it early (e.g., the victim reaching `Defeated` mid-hitstop shouldn't leave an orphaned hitstop-recovery thread running).

### Reaction-time heuristics (detection only, not enforcement)

Required by the master doc (Section 5) but missing from the design — a genuinely different concern from `LagCompensationService`: that system validates whether a *specific* parry was legal given network timing; this system watches *patterns* across many parries to flag statistically inhuman consistency, independent of whether any individual parry was itself legal.

**What it tracks:** for every parry attempt (success or whiff), record the reaction time — the gap between the attack's swing becoming readable (windup start) and the parry press — into a rolling per-player buffer (e.g. last 100 attempts). Periodically compute mean and variance across the buffer.

**What it flags:** two signals together, not either alone — reaction times sustained below the practical human floor (~150–200ms), *and* suspiciously low variance (real humans have natural timing jitter even at high skill; inhuman-consistent timing is the actual tell, not raw speed by itself).

**Detection, not blocking:** never rejects a parry or interferes with `LagCompensationService`'s real-time legality check — only logs/flags a player for human review. Auto-banning on a statistical heuristic risks false-positiving genuinely skilled players; the master doc's own phrasing ("flag") supports this being a review signal, not automatic enforcement.

**Where it lives:** a lightweight addition alongside `CombatValidationService`'s existing parry-handling path — doesn't need its own Service given the narrow scope, but must be a clearly separated code path from the real-time parry-legality check, per the master doc's explicit instruction that these are "never the same code path."

## 7. System architecture

Mirrors the movement layer's Controller/Service/Constants split.

**Client Controllers:**
- `AttackController` — M1 input, combo chaining, feint input
- `GuardController` — the shared Block/Parry hold-key (Section 3): opens a `Parrying` window on press, drops into a held `Blocking` state (same pattern as `_isSprintKeyHeld`) on whiff-while-still-held or on a fresh press during the whiff cooldown, exits to `Idle` on release
- `SkillController` — hotbar slot input, client-side Qi/cooldown prediction
- `CombatAnimationController` — mirrors `AnimationController`'s exact shape

No dedicated Dodge controller — that input is `DashController` (movement layer). No dedicated Parry-only or Block-only controller either, now that the two share one key/state machine.

**Server Services:**
- `CombatValidationService` — FSM mirror + transition legality (role of `MovementValidationService`)
- `HitRegistrationService` — owns server-side hitbox overlap checks, applies damage/posture/stagger, resolves critical-attack guardbreak math against `GuardbreakResistance`. Also queries `MovementValidationService` for "is this player currently dashing" (Section 3) to resolve dodge-negation, injected from `ServiceBootstrap` since the two Services have no existing require relationship
- `LagCompensationService` — dedicated, rewinds attacker-effective time for both parry legality and hit-landing validation across every attack type including projectiles (per master doc; expanded scope detailed in Section 6)
- `SkillValidationService` — Qi cost + cooldown validation

**Cross-FSM rule:** `DashController`/`SlideController` check `combatFSM:GetState()` against a lock table before allowing a dash/sprint mid-swing — same pattern as checking `movementFSM`'s `LockedMovementStates`. `AirborneController` needs the same treatment on landing: `_onLanded` currently fires `LightLanding`/`HeavyLanding` unconditionally off fall speed, which could stomp an active combat state if the player lands mid-attack (a latent gap that already existed for Dash off a ledge, not something new). It should check `combatFSM`'s locked states first and skip the landing transition when combat already owns the state, letting the attack's own Recovery phase return to `Idle` instead — with the one exception under Aerial attacks (Section 4), where a successful hit explicitly requests a clean landing rather than just deferring to combat. Both FSMs are central shared modules, so none of this violates the Strict Pub/Sub Decoupling rule (controllers reference shared state modules, not each other).

**Standing rule, not a per-feature patch: any combat action that moves the player via server-applied velocity or CFrame changes must register a brief exemption with `MovementValidationService`**, the same mechanism `dashSpeedExemptUntil` already provides for Dash. This covers the Running Attack's forward burst, Critical Attack's dash-in, Aerial Attack's dive, Flash Step Vent's teleport, and anything added later — without it, `_validatePlayer`'s anti-speed-hack check sees an "impossible" position jump and rubberbands the player, silently breaking the ability the first time it's used. Implement this as one shared utility (e.g. `RequestSpeedExemption(player, duration)`) that any service can call, rather than reimplementing the exemption per-ability — so it's automatic for abilities not yet designed too.

**Remotes needed (draft):** `RequestAttack` (covers both the M1 chain and the running attack — server distinguishes by movement state), `RequestCriticalAttack`, `RequestFeint`, `RequestGuard(bool)` (covers both Block and Parry, per Section 3's shared key — no separate `RequestParry`/`RequestBlock`), `RequestSkill(skillId)` — same `Request*` naming convention as the movement remotes. No `RequestDodge` — that's `RequestDash`, already a movement remote.

**RemoteEvent-level rate limiting, distinct from game-logic cooldowns:** `ParryWhiffCooldown` only triggers on a *miss* — a macro firing successful parries back-to-back never whiffs, so it never touches that cooldown at all. The master doc's rate-limiting requirement (Section 5) needs a hard cap at the remote itself (minimum time between accepted `RequestGuard` events per player, rejecting anything faster regardless of whether the parry would've been legal), independent of and in addition to `ParryWhiffCooldown`. Applies to every combat remote above, not just guard — the same class of protection (a macro firing legal-looking `RequestAttack` calls faster than human input) applies equally elsewhere.

**Folder organization:** as Movement, Qinggong, and Combat controllers all grow, they should live in their own subfolders under `Controllers/` and `Animation/` (`Controllers/Combat/AttackController`, etc.) rather than one flat list — Rojo's directory `$path` mapping reflects nested folders into Studio automatically, no project config changes needed. A `Core/` folder holds genuinely cross-cutting pieces (camera, footstep/VFX/sound feedback) that will eventually serve more than one domain — not a catch-all for anything uncategorized.

**Weapon/skill data organization — aggregator over per-item files, not one flat table:** the weapon roster (and, once built, the skill roster) is expected to grow well past a handful of entries over the game's life, not stay capped at the v1 launch set — a single `WeaponDefinitions.luau`/`SkillDefinitions.luau` table literal would turn into a merge-conflict magnet and a scroll-fest the moment more than a couple of people are touching it. Instead:
- Each weapon lives in its own file under `Constants/Weapons/<WeaponId>.luau` (e.g. `Weapons/Jian.luau`), returning just that one `WeaponDefinition`. Skills follow the identical pattern once `SkillDefinitions` gets built: `Constants/Skills/<SkillId>.luau`.
- `WeaponDefinitions.luau` (`SkillDefinitions.luau`) itself becomes a thin aggregator — `require`s each per-item file and freezes them into the `{ [Id] = Definition }` table every consumer (`AttackController`, `HitRegistrationService`, `SkillValidationService`, etc.) already expects. Its own public shape and require path don't change, so nothing downstream needs to know the split happened.
- Shared type shapes (`ComboStepData`, `WeaponDefinition`, etc.) live in a sibling types-only module (`Weapons/WeaponTypes.luau`, `Skills/SkillTypes.luau`) that both the aggregator and every per-item file require — putting the types on the aggregator itself instead would force a require cycle (per-item file → aggregator for the type → per-item file for the data).
- Adding a weapon or skill is then a new file plus one line in the aggregator, not an edit to an ever-growing shared file — keeps diffs and merge conflicts scoped to the one item actually being touched.

## 8. Player combat modifiers

Pulled from the "Murim Ascent World Building" doc — gender, body type, temperament, traits, and hidden physiques all stack. This generalizes and replaces the single flat placeholder from Section 4: the real system needs modifier hooks on both sides of several interactions, not just guardbreak.

**Confirmed modifier axes (stack multiplicatively across independent layers — gender × body type × temperament × traits × hidden physique):**

| Modifier | Affects | Source examples |
|---|---|---|
| `PostureDamageDealtMultiplier` | Posture damage an attacker's hits (M1s, criticals, aerials) deal to a blocking defender | Male +, Female −, Heavy/Stocky ++, Lean/Lithe −, Violent temperament + |
| `PostureDamageTakenMultiplier` | Posture damage a defender takes while Blocking | Female takes more (Frail Guard), Heavy/Stocky takes less (Iron Foundation), Extreme Yin takes drastically more |
| `ParryPosturePunish` (+ multiplier) | Posture damage inflicted on the attacker when their attack gets parried — the actual mechanism behind the guaranteed punish window in Section 5 | Arrogant temperament, Parry Punisher trait, Extreme Yang body |
| `ParryPostureRelief` (existing, Section 2) | Posture restored to the defender on a successful parry | unchanged |
| `WhiffRecoveryMultiplier` | Recovery duration after a missed M1, sometimes scoped to a specific weapon category (e.g. only heavy weapons) | Lean body (heavy-weapon-only penalty), Heavy Handed trait, Wild temperament |
| `FeintWindowMultiplier` | How forgiving the FSM timing window is when canceling an M1/skill into Feinting | Feint Prodigy trait, Lean body, Heavy/Stocky body (tighter with light weapons specifically), Extreme Yin (massively forgiving) |
| `ParryWhiffCooldownMultiplier` | Length of the forced-block cooldown after whiffing a parry (Section 3) | Male heavier, Cautious/Calm Under Pressure lighter, Extreme Yang dangerously long |
| `RollCancelGraceMultiplier` | i-frame grace window on the movement layer's roll-cancel — ties directly into `RollCancelMaxCharges`/`RollCancelChargeCooldown` in the existing `MovementConstants` | Phantom Footwork trait, Heavy/Stocky nerf, Cautious buff |
| `CriticalAttackCooldownMultiplier` | Recharge rate of the weapon's Critical Attack cooldown | Critical Insight trait, Enlightened temperament (nerf) |
| `QiRegenMultiplier` | Passive Qi regen rate | Cultivation Genius trait, Enlightened temperament |

**Architecture implication:** every player needs a `CombatModifierProfile` — computed once (spawn, or whenever gender/build/trait selection changes) by multiplying together all active modifier sources, then cached as a flat table of final multipliers server-side. `HitRegistrationService`, `CombatValidationService`, and `MovementValidationService` should all read from this one profile rather than each independently re-deriving gender/body/temperament logic — keeps the spirit of the existing decoupling rules even though these are services, and means a new trait or hidden physique later only touches profile computation, not every consuming service.

**Weapon category + synergy:** the doc references Light/Medium/Heavy/Fist weapon categories with build-specific synergy or incompatibility (Female + Light synergy, Male + Heavy weapon + Fist synergy specifically, Lean body's Heavy Weapon Ineptitude, etc.). `WeaponDefinitions` needs a `Category` field so profile computation can check build-vs-equipped-weapon synergy and adjust `WhiffRecoveryMultiplier`/`FeintWindowMultiplier` accordingly. Dagger = Light, Fist = Fist (its own category, not grouped with Light — the source doc treats Male's Fist bonus separately from Female's Light bonus), Jian = Medium, Greatsword = Heavy.

**Resolved:** M1×4 stands as the baseline (Section 4) — the World Building doc's "5-hit M1 combo" line was unintended phrasing on that end, not a design change. Worth tweaking the wording in the Google Doc itself when convenient, but nothing here needs to change.

## 9. Anti-combat-log (combat tagging)

Not tied to permadeath (explicitly out of scope for now) — this is about preventing disconnect-to-evade regardless of what the eventual defeat penalty ends up being, per the master doc's "combat-logging or exploit-driven evasion" rule.

**Combat tag:** whenever damage is exchanged with another player *or* an NPC/mob, the player gets tagged with a `CombatTagUntil` timestamp (placeholder ~8–10s from the last hit, refreshed on every subsequent hit — PvP and PvE both tag). Lives alongside the other per-player fields in the existing combat record.

**On disconnect while tagged:** Roblox doesn't auto-destroy a character just because the `Player` object leaves — the model can be deliberately left in `Workspace`. A tagged player who disconnects mid-fight leaves their character behind: frozen (no more input, obviously), but the body stays put with HP/posture state preserved, still fully hittable for the remainder of the tag window. Whoever they were fighting gets to actually land the finishing blow instead of watching them vanish. Only after the tag window expires (or they're defeated) does the server clean up and finalize the data save — satisfies the master doc's "atomic, fail-safe" data rule too, since nothing saves mid-resolution.

**Untagged disconnects** (no recent combat) clean up immediately, no penalty — this only fires for someone actually trying to dodge a live fight.

**Free side effect:** `CombatTagUntil` is also exactly the "in combat" condition Section 8's `QiRegenMultiplier` needs — the World Building doc specifies Qi regenerates "while resting or out of combat." Same flag gates both systems instead of building "in combat" detection twice.

**Movement restrictions while tagged:** the same flag doubles as an anti-kiting gate, not just an anti-combat-log one.
- **Sprint is barred outright** while `now() < CombatTagUntil`: `MovementValidationService._onRequestSprint` rejects the request (and force-cancels an in-progress sprint the instant a tag lands), `MovementController._setSprintKeyHeld` mirrors the check client-side for responsive feel. Two free consequences: `SlideController` can only enter `Sliding` from `Running`, so this blocks Sliding too without a separate rule; the running attack (Section 4) becomes unavailable for the same reason. Dash is untouched — it's short, cooldown-gated, and load-bearing for combat itself, not a sustained escape tool the way Sprint is.
- **Qinggong (wall-running, etc.) should cost more Qi while tagged, not be barred** — unlike Sprint, it likely has legitimate in-fight uses (repositioning, aerial dodges), so a hard bar would punish normal combat play, not just fleeing. Can't be designed concretely yet since Qinggong doesn't exist (Section 11), but registered here as a firm requirement for that future session: a `CombatTagQinggongCostMultiplier` (or similar) applied whenever `CombatTagUntil` is active.

## 10. Stagger recovery: Flash Step Vent + immunity

Deepwoken-style mash-to-vent would work, but it's a generic APM check unrelated to anything specific to this game. A burst escape action fits better — and it reuses infrastructure that already exists twice over.

**Flash Step Vent:** vent input while `Staggered` triggers an instant short-distance teleport (steerable by held movement input, defaults to a backstep if none held — same default `DashController` already uses for its own no-input case), i-frames for the duration, brief invisibility, and a cosmetic after-image VFX at the origin point. Ends `Staggered` immediately rather than shortening it — the player leaves the fight for a beat instead of recovering faster in place.

- **I-frames reuse existing infrastructure:** sets the same `IsInvulnerable` flag the lag-compensation buffer (Section 6) already tracks for `Dodging` — no new invulnerability system needed, just another state that flips the same bit.
- **Cost — dual-gated, not a single cooldown:** a flat `FlashStepVentQiCost` per use, plus a charge-based gate (`FlashStepVentMaxCharges` / `FlashStepVentChargeRegenCooldown`) that literally reuses the existing `RegenCharges` utility, mirroring `RollCancelMaxCharges`/`RollCancelChargeCooldown` exactly. Same pattern, same shared file, no new logic to write. Even with Qi to spare, no charges means no vent.
- **`MinStaggerDurationBeforeVent`:** a short mandatory delay before the vent option becomes available at all. Guarantees the attacker who successfully guardbroke someone always gets *some* punish — venting cuts short the rest of it, it doesn't erase the guardbreak's value outright. Without this, a resource-ready defender could no-sell every guardbreak instantly, which defeats the reason to build posture damage in the first place.
- Scoped to `Staggered` only, not `Hitstun` — Hitstun is already short with no guaranteed punish, nothing worth spending Qi/charges to escape.

**The actual structural fix for infinite chain-stagger — two rules, both required, independent of venting:**
1. **`Staggered` doesn't refresh from further hits.** Landing another guardbreak-capable hit on an already-`Staggered` target still deals its damage, but doesn't extend or re-trigger the Staggered timer. Without this rule, a chained attacker could keep the window open indefinitely regardless of the vent mechanic.
2. **`PostStaggerImmunityWindow`** — a brief window after Staggered actually ends (full duration or vented short) during which the target can't be re-Staggered (normal Hitstun/damage still applies, just not guard-broken again). The real backstop: no matter how fast or well-timed a follow-up is, there's a hard limit on consecutive stagger-lock.

## 11. Deferred / open for now

- **Grabs:** just the `Unparryable` flag for this pass. No dedicated grab FSM state or forced-sequence system yet.
- **Damage/posture numbers, skill roster:** not yet defined — content pass, not framework pass.
- **`CombatModifierProfile` architecture and values:** modifier axes are identified (Section 8), but how they're actually computed/stacked/cached (the `CombatModifierProfile` system itself), plus real per-gender/body/temperament/trait numbers, are both intentionally deferred — core combat systems (skills, aerial attacks) come first, stats layer in after.
- **Qinggong / parkour movement system:** wall-running, double jumps, ledge-vaulting, tree-jumping, and the Qinggong meter that gates them are referenced throughout the World Building doc but don't exist in the current movement codebase yet. Sizable addition to the movement layer, not combat — separate future session. Carries one firm requirement from Section 9 already: Qinggong actions must cost more while combat-tagged.
- **Hyper-armor:** heavy finishers becoming interrupt-immune partway through their animation (Heavy/Stocky body buff). Not yet modeled — would need a `GrantsHyperArmor` + start-time flag on qualifying attacks.
- **Elemental affinity (yin/yang), Families/Clans, hidden physiques:** flavor/progression systems referenced in the World Building doc, explicitly marked TBD there too.
- **Permadeath and defeat consequences:** explicitly out of scope. Combat-tagging (Section 9) is designed to be independent of whatever defeat penalty eventually gets designed.


- **`CombatConstants.luau` full value table:** placeholders listed above need playtesting before finalizing.

## 12. Implementation roadmap

Grounded combat only — aerial attacks get their own framework pass later, excluded here on purpose. Core idea: prove the riskiest architecture on one weapon with no defense at all, then widen, rather than building every system in parallel.

1. **Scaffolding:** folder reorg (Section 7), `CombatState` enum (mirrors `MovementState.luau`), `combatFSM = FiniteStateMachine.new(CombatState.Idle)`, `CombatConstants.luau` skeleton, `WeaponDefinitions.luau` with Jian only.
2. **Single-weapon M1 loop, no defense:** `AttackController` (M1 only, Jian's `ComboSteps`), `HitRegistrationService` (basic `OverlapParams`, live positions, no lag comp yet), `CombatValidationService` (FSM mirror only), `CombatAnimationController`. Deliberately incomplete — proves client-predicted/server-authoritative hit detection in isolation first.
3. **Defense triangle (using live timestamps initially, not full lag comp — get the mechanic right before making it network-fair):** `GuardController`/`RequestGuard` for the merged Block+Parry hold-key (Section 3), plus wiring `HitRegistrationService` to recognize an active ground Dash as the Dodge leg — no separate Dodge input/state to build, since it's the existing `DashController`.
4. **Round out the reference weapon:** Running Attack, Critical Attack, Feinting — still Jian only.
5. **Generalize to Dagger and Greatsword:** the real test of whether "data, not code" held up. New code paths needed here (rather than just new `WeaponDefinitions` entries) means the abstraction needs fixing before a fourth weapon ever exists.
6. **Full lag compensation:** retrofit history buffer + invulnerability tracking onto the working pipeline. Build/test in isolation first using Studio's simulated-latency tooling before it's tangled up with three weapons' worth of hit checks.
7. **Skills:** one simple melee skill, then multi-beat (Plum Blossom), projectile last (genuinely new infrastructure — `ProjectileService`).
8. **Posture systems:** `Staggered`, guardbreak math (placeholder `1.0` multipliers until Section 8 has real values), Flash Step Vent.
9. **Combat tagging + sprint-barring.**

**Performance, tied to what actually gets built:** the GC-defense discipline the master doc already mandates for movement extends to every new combat system — pool hurtbox proxies and projectile parts (never spawn-and-destroy per hit), bound the lag-comp ring buffer to a fixed size, throttle hit-detection ticks the same way `MovementValidationService`'s `ValidationTickRate` already does, route new animation sets through the existing `AssetPreloader` rather than loading them ad hoc.

**Testing practice from step 2 onward:** every phase gets tested with 2+ real players before moving to the next — combat feel doesn't show up solo. A temporary dev-only hitbox visualization (bright, semi-transparent part during active frames) turns timing/range guesswork into something visible. Treat each new system as something to actively try to break — replay remotes, fire requests out of legal order, simulate high latency — before calling it done.

## 13. Weapon equipping

Hotbar-based, fully custom (no native Roblox Tools) — weapons and skills share one hotbar system (Section 4), which Tools have no concept of, and Fist's bare-hands case (nothing to equip visually at all) doesn't fit a Tool-based model either.

- **Trigger:** shares the same unified hotbar as skills (Section 4) — a weapon is just another item type that can occupy any slot. Pressing that slot's key equips it, subject to the rules below. No separate key range needed now that weapons and skills share one hotbar rather than two systems with their own bindings.
- **Server-authoritative, gated by `CombatTagUntil`:** `RequestEquipWeapon(weaponId)` — server checks ownership (a real dependency on an inventory/economy system this framework doesn't design), checks the player isn't combat-tagged, then updates `EquippedWeaponId` and replicates the change to other clients. Client predicts the swap instantly; a server rejection (e.g., tagged) reverts it.
- **Out-of-combat-only means no combo state to reset** — by the time a swap is legal, `combatFSM` is already back at `Idle`. Free consequence of the gating, not extra logic.
- **Attachment: Motor6D welds onto R6 arm parts.** R6's single-part-per-limb simplicity helps here — a weapon model welds directly onto `Right Arm` (or `Left Arm` for an offhand piece) via its own baked-in attachment offset. Equip clones the model from a `ReplicatedStorage` library and welds it in; unequip destroys the clone and removes the weld.
- **This is the same asset Section 6 already assumes exists** — the weapon model welded on equip is exactly the one carrying the server-authoritative hitbox Attachment used during attacks. Equipping isn't a separate asset pipeline, just *when* that model gets attached to the character.
- **Fist needs no model** — bare hands, nothing to clone or weld. Its hitbox Attachment lives permanently on the R6 arm parts themselves rather than being swapped in.
- **Fist is now a fully designed 4th weapon, not a stub:** its own category (Section 8), same linear M1×4 combat shape as the other three weapons (Section 4's weapon roster), with its own critical attack (the spin-kick, reassigned from Dagger). No longer just a fallback placeholder — it's a real weapon that also happens to be the mandatory default when nothing else is equipped.

