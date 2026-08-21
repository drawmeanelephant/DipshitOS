# Claim: docs/logs/ cleanup — archive stale session logs, shorten UUID filenames

- **Owner:** opencode (`t3code/fix-issue-267-git-current`)
- **Prompt / plan:** GitHub issue #267 (repo hygiene)
- **Scope:** repo hygiene — `docs/logs/` layout only; no log entry content is rewritten or deleted (append-only rule holds)
- **Depends on:** —
- **Status:** ✅ done 2026-08-21

## Notes

`docs/logs/` had grown to ~146 session logs, 25 of them named after the
freebuff prompt text plus a UUID (80+ chars, e.g.
`freebuff-can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-…​.md`),
which makes directory listings hard to scan and burns context.

Changes (filenames only — every file's content is byte-identical):

1. **Archive**: every log whose last commit is older than 7 days
   (`≤ 2026-08-13`) moved from `docs/logs/` to `docs/archive/logs/`.
   Non-UUID files keep their names; UUID-style files are renamed during
   the move (see below).
2. **Rename**: remaining UUID-style logs renamed to
   `{agent}-{yyyymmdd}-{seq}.md` (issue #267's prescribed format).
3. **Indexes regenerated** with `tools/status/refresh-indexes.sh`; prose in
   `docs/logs/README.md` documents the naming convention and the archive;
   `docs/archive/README.md` covers `logs/`.

Old-name → new-name map (full history via `git log --follow`):

| old | new |
|-----|-----|
| `freebuff-grab-newest-files-from-github-and-pick-something-t-a3eb337e-4b37-4bae-8548-242c49be7456.md` | `archive/logs/freebuff-20260807-001.md` |
| `freebuff-let-s-get-the-latest-github-and-do-something-benef-e128807b-0418-4d4e-aebe-ba30b18c18c5.md` | `archive/logs/freebuff-20260807-002.md` |
| `freebuff-pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91.md` | `archive/logs/freebuff-20260807-003.md` |
| `freebuff-pull-the-latest-from-github-and-find-something-in--a639920e-ebe1-47a0-a380-54cece9b4c40.md` | `archive/logs/freebuff-20260807-004.md` |
| `freebuff-make-sure-git-is-current-first-18548850-6288-40ff-bca2-007971e567ac.md` | `archive/logs/freebuff-20260808-001.md` |
| `freebuff-make-sure-git-main-is-current-7f307de5-d3c0-4d90-966c-3a4221ad4d24.md` | `archive/logs/freebuff-20260808-002.md` |
| `freebuff-okay-we-ve-been-kind-of-freestyling-off-away-from--0584ad0f-9850-473f-8884-7c28b20acab7.md` | `archive/logs/freebuff-20260808-003.md` |
| `freebuff-pull-git-and-check-status-to-make-sure-everything--9934c25c-63ea-4cf3-b3fb-4b98fb81b9f4.md` | `archive/logs/freebuff-20260808-004.md` |
| `freebuff-pull-git-and-check-status-to-make-sure-everything--d4bf6a7f-c051-49b8-a1c4-bc479835e531.md` | `archive/logs/freebuff-20260808-005.md` |
| `freebuff-pull-latest-dipshitos-main-after-all-preceding-rel-1fe779b0-133e-4303-81f1-397087634352.md` | `archive/logs/freebuff-20260808-006.md` |
| `freebuff-pull-latest-dipshitos-main-ebe15999-a14a-4066-9551-00deb3d2323a.md` | `archive/logs/freebuff-20260808-007.md` |
| `freebuff-start-from-current-dipshitos-main-record-the-exact-af2bed0e-1f29-49ea-b233-bf528e5ce88e.md` | `archive/logs/freebuff-20260808-008.md` |
| `freebuff-start-from-the-latest-dipshitos-main-record-the-ex-b37e0c09-ea4e-44cd-a4dd-8576e651c7a2.md` | `archive/logs/freebuff-20260808-009.md` |
| `freebuff-you-are-working-in-the-dipshitos-repository-on-cur-264903eb-313e-440f-a0e4-224e3311933d.md` | `archive/logs/freebuff-20260808-010.md` |
| `freebuff-get-newest-github-files-and-let-s-get-some-shit-do-1e1cbf84-86fb-4605-a843-32fc0593fea0.md` | `archive/logs/freebuff-20260809-001.md` |
| `freebuff-grab-latest-git-and-check-out-status-and-let-s-get-15800f9b-d72c-4035-ac26-ae778c52b296.md` | `archive/logs/freebuff-20260809-002.md` |
| `freebuff-grab-most-current-git-and-let-s-continue-on-with-o-5886224b-69b6-4597-adc4-63698bac127e.md` | `archive/logs/freebuff-20260809-003.md` |
| `freebuff-grab-most-current-git-and-let-s-continue-on-with-o-bd839138-534f-40b1-97b3-220d1b1c9a61.md` | `archive/logs/freebuff-20260809-004.md` |
| `freebuff-grab-newest-git-and-check-status-if-there-s-any-im-b9d5c028-9379-48e0-8ddb-ebfbf45ef2df.md` | `archive/logs/freebuff-20260809-005.md` |
| `freebuff-grab-most-current-git-and-let-s-continue-on-with-o-6068d391-a734-4e7b-859d-b1e95f01f3f6.md` | `archive/logs/freebuff-20260811-001.md` |
| `freebuff-can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc.md` | `freebuff-20260814-001.md` |
| `freebuff-can-you-figure-out-why-the-text-is-getting-flipped-8600521b-d8d1-4667-a3e8-d2fa10b4ff03.md` | `freebuff-20260815-001.md` |
| `freebuff-hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a.md` | `freebuff-20260818-001.md` |
| `freebuff-new-worktree-who-dis-84637f8c-617d-4718-b605-bebdba7963d9.md` | `freebuff-20260818-002.md` |
| `freebuff-can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde.md` | `freebuff-20260820-001.md` |

Verification: `bash tools/status/refresh-indexes.sh`,
`bash tools/verify-coordination.sh`, `bash tools/status/test-coordination.sh`
— all green after the change; log contents verified byte-identical
(`git diff --stat` shows renames only, zero content lines changed).
