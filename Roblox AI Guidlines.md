# AI Codebase Guide: Murim Ascent

**[DONT PUSH THIS PART TO GITHUB — this is just for me, not others.]**

This document is the absolute source of truth for the codebase of **Murim Ascent**. AI assistants must read, internalize, and strictly adhere to these rules before writing or modifying any code. Do not hallucinate systems, do not suggest standalone scripts, and do not write unoptimized code.

## 1. Project Identity & Scope
**Murim Ascent** is a Roblox game built with Rojo.
* **Rigs:** The game exclusively uses standard R6 rigs to guarantee identical hitbox fairness. Do not write code accommodating R15 or custom rigs.
* **Combat Identity:** This is a parry-based combat game in the vein of Deepwoken, Nethros, and Type Soul. Parry timing, stagger, and server-authoritative hit validation are core to the game and must be treated as first-class systems, not bolted onto a generic combat script.

## 2. Global Architectural Rules
* **Single-Entry Point:** The codebase uses strict `ClientBootstrap.luau` and `ServiceBootstrap.luau` initialization. Never write rogue `LocalScripts` or `Scripts` placed randomly in the Explorer.
* **Finite State Machines (FSM):** All stateful systems (combat, movement, interactions, etc.) are strictly governed by decoupled FSMs using `LemonSignal`.
* **Strict Pub/Sub Decoupling:** Cross-controller dependencies are forbidden. Controllers must subscribe to central state modules.
* **Data-Driven Design (Zero Magic Numbers):** Hardcoding numerical values (impulse vectors, durations, speeds, cooldowns) inside functional scripts is strictly prohibited. All stats, cooldowns, and metrics must be routed to centralized data modules (e.g., `MovementConstants.luau`, `CombatConstants.luau`).

## 3. The "Bouncer" Philosophy (Security & Anti-Exploit)
The client is a liar. Roblox physics and network replication default to a trust-the-client model, which must be aggressively overridden.
* **Client Prediction, Server Authority:** The client predicts visuals (movement, animations, effects) immediately for responsiveness, but the server must always validate the math, cooldowns, and state transitions.
* **Server-Side FSM Mirroring:** The server (e.g., `MovementValidationService`, `CombatValidationService`) must maintain a lightweight mirror of the player's FSM state. If an illegal state transition is requested, reject it and rubberband the player.
* **Server-Side Cooldowns:** Never trust client-side cooldowns or closures for limits (e.g., `lastDashTime`). Cooldowns must be tracked in server-side player profiles.
* **Sanity Raycasts:** For complex spatial states (wall-running, vaulting, climbing, etc.), the server must perform a lightweight validation raycast near the character's server-position to ensure the geometry actually exists before replicating the state.

## 4. Parry Combat Systems
Parry timing is the single most exploited and most game-defining system in this genre. It gets its own contract, separate from generic combat.

* **Parry Window Constants:** Parry windows must be defined as explicit values in `CombatConstants.luau` (e.g. `PARRY_WINDOW = 0.2`). No controller is permitted to compute or hardcode its own window locally, ever.
* **Server-Authoritative Parry Validation with Lag Compensation:** Parry legality must be checked against the attacker's timestamp via a dedicated `LagCompensationService`, not against the defender's local clock. Validating only on the defender's clock punishes high-ping players and gifts low-ping players an unintended auto-parry advantage.
* **Stagger / Posture State:** Combat runs a posture meter alongside HP. Failed parries and blocked hits build stagger; a stagger break triggers a guaranteed punish window. This is its own explicit FSM state (`Staggered`), mirrored server-side identically to every other combat state.
* **Feint State:** If attacks can be feinted, the FSM must have an explicit `Feinting` state. The server uses this to distinguish a legitimate cancelled attack from an exploited animation cancel — these are never the same code path.
* **Hitstop / Hitlag:** Freeze-frame on successful hits and parries is a data-driven value per attack type in `CombatConstants.luau`. Never implement hitstop as a hardcoded `wait()` or `task.wait()` call.
* **Directional / Positional Parries:** Back-attacks and blindsides bypass parry. The sanity raycast system must include facing-angle validation for these attacks, not just a geometry-existence check.

## 5. Anti-Exploit: Parry-Specific
General cooldown and state validation (Section 3) is necessary but not sufficient for a parry game. These additions target exploits unique to timing-based combat.

* **Reaction-Time Heuristics:** The server should track and flag statistically inhuman parry consistency (e.g. sub-human reaction windows sustained across hundreds of attempts). This is the primary vector for auto-parry scripts in this genre and must be logged/flagged independently of normal state validation.
* **Input Rate Limiting on Parry RemoteEvents:** Parry input must be rate-limited at the RemoteEvent layer, separate from the FSM's own cooldown logic. This stops parry-spam and macro scripts that fire faster than any legitimate input device could.

## 6. Performance & Memory Management (Critical)
* **No Deprecated Timers:** Never use `tick()`. It is deprecated and subject to local timezone shifts. Use `os.clock()` exclusively for all cooldowns, timestamps, and benchmarking.
* **Throttle RunService Raycasts:** Do not execute dense raycasting blindly every single frame via `RenderStepped`. Implement delta-time accumulators to throttle physics queries (e.g., checking ~30 times a second).
* **Aggressive Memory Cleanup:** When a character dies or respawns, a new FSM is created. You *must* track and explicitly `:Disconnect()` all event listeners on `humanoid.Died` or cleanup phases to prevent catastrophic memory leaks.
* **Garbage Collection (GC) Defense:** Avoid rapid-fire anonymous functions inside `task.delay()`. Track active task threads using a registry (e.g., `activeTasks`) and explicitly call `task.cancel()` when states override each other to prevent GC spikes from input spam.

## 7. Lua/Luau Style & Syntax Guidelines
* **Strict Typing:** Use Luau strict typing (`--!strict`) where applicable to ensure type safety across the FSM.
* **Naming Conventions:**
    * `PascalCase`: Classes, Services, Controllers, Enums.
    * `camelCase`: Local variables, functions, constants.
    * `_prefix`: Private members within tables.
* **Formatting:** No semicolons. Indent with tabs. Maximum line length of 100 columns.
* **Iteration:** Do not mix list and dictionary keys. Use `ipairs` for sequential arrays, `pairs` for dictionaries.
* **Yielding & Errors:** Never yield the main thread. Wrap in `task.spawn`, `task.defer`, or use Promises. Use `pcall` for functions that can throw, or prefer returning `success, result`.
* **Comments:** No comments. Code must be self-documenting through clear naming and structure. If a line is genuinely non-obvious (a math trick, an engine quirk, a workaround), a single short comment is permitted — one line, no more than a few words. Never write comments that restate what the code already says, never write block comments, and never write comments explaining function purpose (that's what the function name is for).

## 8. GUI & Persistence
* **GUI Creation:** Never create `ScreenGui`s or GUI elements via code. Every GUI is hand-built in Studio; scripts only `WaitForChild` into existing GUI instances to control logic.
* **Data Saving:** All player data must be session-locked on join. Wipes and critical data operations must be atomic, fail-safe operations to prevent data loss, combat-logging, or exploit-driven evasion.

## 9. No Band-Aid Validation
* **No "Band-Aid" Validation (Strict Root-Cause Resolution):** Never artificially pad, inflate, or hardcode arbitrary tolerances into server-side checks (e.g., adding flat values to distance, speed, or time validations) to paper over network latency or desync. This lazy anti-pattern creates over-permissive validation and introduces massive exploit vulnerabilities. Synchronization and latency issues must always be solved at the mathematical root cause — using precise lag compensation, velocity projection, or strict data-driven margins — never by relaxing the server's rules.
* **Empirically-Justified Physics Margins Are Not Band-Aids:** This rule targets tolerances added with no underlying justification — a padding value increased repeatedly until complaints stopped, with no measured cause behind it. It does not prohibit a tolerance that accounts for a measured, deterministic engine interaction (e.g., a documented transient from Humanoid's ground controller combining with residual velocity after a dash-cancel). When adding any numeric tolerance, document the measured behavior that justifies its exact value in a comment. If you cannot point to a specific measured cause, it is the band-aid this section warns against.

## 10. Remote Communication Rules
Section 5 already requires rate-limiting for parry specifically. These rules generalize and complete that requirement.

* **Type-Validate Every Remote Argument, No Exceptions:** Every remote handler validates argument types before use. A malformed or malicious argument type must never reach game logic.
* **RemoteEvents Only — Never RemoteFunctions:** A client that never responds to a RemoteFunction call hangs the server thread waiting on it, the same category of hazard Section 7's yielding rule exists to prevent. No combat or movement interaction in this game requires a synchronous client response.
* **Rate-Limit Every Player-Initiated Combat/Movement Remote, Not Just Parry:** A hard cap on accepted-events-per-second, independent of and in addition to any game-logic cooldown (`DashCooldown`, `ParryWhiffCooldown`, etc.). A cooldown only fires under specific game-state conditions (e.g. a miss); a remote-layer rate limit catches macro/script abuse regardless of whether the spammed action would otherwise be legal.

## 11. Physics & Networking Ownership
* **Server-Authoritative Physics Objects Must Never Be Subject to Automatic Network Ownership:** Roblox automatically assigns network ownership of unanchored physics-simulated parts to a nearby client for performance reasons. For a hitbox proxy, projectile, or any other part whose position the server treats as ground truth, this can let a client influence its trajectory before the server's own check runs. Every such part must either be `Anchored` and moved by script (position/CFrame set directly, no physics simulation), or have its network ownership explicitly set to the server (`SetNetworkOwner(nil)`) and never left to automatic assignment.

## 12. Player State Representation
* **HP, Posture, and Qi Are Custom Data Profile Values — Never `Humanoid.Health`:** `Humanoid.Health` should be held at a fixed high value (or its regen disabled) purely as a rig-compatibility shell; it is never read as the authoritative health source and never drives game logic.
* **`Humanoid.Died` Is Not the Defeat Trigger:** The custom HP-reaches-zero check in the relevant validation/registration service drives the `Defeated` FSM state directly. `Humanoid.Died` firing from an unrelated cause (a scripting error, an out-of-bounds kill volume) must not be treated as equivalent to a combat defeat.

## 13. Data Persistence Practices
Section 8 requires data operations to be "atomic, fail-safe." These are the concrete practices that deliver that guarantee on Roblox.

* **Use `UpdateAsync`, Never a Read-Then-Write Pair:** A separate `GetAsync` followed by `SetAsync` is a race condition waiting to happen across concurrent sessions or server restarts; `UpdateAsync`'s transform-function pattern is the only safe primitive for this.
* **Retry With Exponential Backoff on DataStore Failure**, with a capped attempt count — never a single fire-and-forget call for anything session-critical.
* **`game:BindToClose()` Must Attempt a Final Save Before Shutdown**, with a reasonable timeout, so a server restart or shutdown doesn't silently drop the last few minutes of a session — directly relevant to the anti-combat-log design, which depends on a session's outcome being settled before its data is finalized.

## 14. World Streaming
* **`StreamingEnabled` Is a Deliberate Decision, Not a Default:** Server-side hit detection is unaffected — the server always has the full world and every character loaded regardless of client streaming radius. The risk is entirely client-side: if `StreamingEnabled` is on, a distant player's character (and their hitbox parts) may not have streamed into an attacker's client yet, which can desync client-side prediction/animation feedback even though the server resolves the hit correctly underneath. Decide explicitly whether `StreamingEnabled` is on for this game — and if it is, document the minimum streaming radius relative to realistic combat engagement range — rather than leaving it as an unconsidered default.
