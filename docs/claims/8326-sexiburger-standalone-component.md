# Claim: Sexiburger standalone component (Milestone 19)

- **Owner:** antigravity (`agent/antigravity/sexiburger`)
- **Prompt / plan:** `docs/claims/8326-sexiburger-standalone-component.md`
- **Scope:** Milestone 19 (Sexiburger god menu #677) S1 action registry seam (#701) + S2 menu shell (#702) + S3 covenant of six (#703) + S4 type-to-filter (#704)
- **Touches:** user/src/lib/action_registry.zig, user/src/lib/sexiburger.zig, user/src/sexiburger.zig, build.zig, image/apps.txt, tools/verify-live-sexiburger.sh, docs/claims/8326-sexiburger-standalone-component.md, docs/logs/agent-antigravity-sexiburger.md
- **Depends on:** —
- **Heartbeat:** 2026-09-02
- **Status:** ✅ agent/antigravity/sexiburger

## Notes

Implements the standalone Sexiburger component and action registry seam for Milestone 19 (umbrella issue #677):
- Action registry seam: pure value-type action and section registry with zero heap allocation.
- The Covenant of Six: strictly hard-caps top-level sections at 6 (System, Apps, Active app, Windows & tabs, Services, Power); rejects a 7th section with error message citing the covenant ("the tentacle count is load-bearing").
- Type-to-filter: abbreviation and prefix search across all registered commands.
- Standalone Sexiburger component: zero-pixel idle footprint until summoned, invariant 6-section geometry, mascot identity integration, keyboard & mouse interaction.
- Standalone userland app `user/src/sexiburger.zig` for testing and standalone execution.
- 100% unit tested with `zig test`.
