# Log — Architecture & UI contract (ADR 0011)

## Context

- **Goal:** Author and land ADR 0011 ([`docs/decisions/0011-desktop-platform-and-gui-apps.md`](../decisions/0011-desktop-platform-and-gui-apps.md)) establishing the normative architecture for userland GUI applications on DipshitOS.
- **Claim:** [`docs/claims/0664-a0-architecture-ui-contract.md`](../claims/0664-a0-architecture-ui-contract.md)

## Entries

### 2026-08-15: Authored and accepted ADR 0011 (claim 0664)

- Authored `docs/decisions/0011-desktop-platform-and-gui-apps.md` detailing:
  - D1: Window-local coordinate spaces and kernel translation
  - D2: Event loop dispatch, event draining, and dirty-batch frame present discipline
  - D3: Zero-allocation micro-widget state models (`Button`, `Label`, `TextInput`, `ListView`)
  - D4: 8×8 bitmap text typography and standard HIG dark-theme palette tokens
  - D5: Desktop environment and launcher lifecycle
- Updated `docs/march-m11.md` card A0 status to ✅ done.
