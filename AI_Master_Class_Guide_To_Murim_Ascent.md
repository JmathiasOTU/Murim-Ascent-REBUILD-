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
