# RSS.ELF — the VirelaiOS terminal RSS/Atom reader

A keyboard-driven RSS 2.0 / RSS 1.0 / Atom reader for the **VirelaiOS guest**,
written in Go with a Bubble Tea model (`charm.land/bubbletea/v2 v2.0.9`).

This is a guest application, not a Mac application. It is built for
`GOOS=virelai GOARCH=arm64` and runs inside the guest OS as a static EL0 binary
hosted by the tabbed desktop. There is no macOS build and no Linux build.

## Target

| | |
|---|---|
| Guest OS | VirelaiOS (from-scratch AArch64; no libc, no POSIX) |
| Go target | `GOOS=virelai GOARCH=arm64`, `CGO_ENABLED=0`, static, `-ldflags "-s -w"` |
| Toolchain | the repo's `GOOS=virelai` fork, materialised at `../go-virelai` by `bash tools/go/apply.sh` |
| Presentation | a `tabapp` window bound to `/dev/tty` (the ADR 0020 seam); the kernel paints the tty grid into the window |
| Input | HID keys delivered to the focused window and read as raw tty bytes |

Bubble Tea's own host `Program` loop cannot run on this guest (no POSIX tty, no
signals). The reader therefore owns its loop — the pattern M72c proved with
`CHARMHELLO.ELF` (`user/go/charmhello/main.go`): decode tty bytes into
`tea.KeyPressMsg`, call `Update`, paint `View()` back into the tty, and service
the window lifecycle from the event queue. Charm's POSIX plumbing is replaced by
two compiler overlays (`tools/go/overlay/charm/termios_virelai.go`,
`signals_virelai.go`), never by an in-tree vendor copy.

## Storage (in the guest)

The guest sees the macOS host share at `/host`. The reader keeps three flat
files there:

| Path | Contents |
|---|---|
| `/host/RSS.OPML` | subscriptions, OPML 2.0 (interoperable import/export) |
| `/host/RSS.STATE` | read/unread state and the last-opened feed |
| `/host/RSS.CACHE` | bounded last-known article cache (≤ 200 articles) |

Every write goes through `vi.WriteFileSafe` (temp file → sync → rename), so a
process killed mid-write cannot leave a half-written file. This is also why the
reader can still show articles when a refresh fails: the cache is the fallback.

## Keys

| Key | Action |
|---|---|
| ↑ / ↓ | move in the current list (clamped; no wrap) |
| Enter | open the selected feed / read the selected article |
| Esc or ← | go back one level |
| `a` | add a feed by URL (typing mode; Enter commits, Esc cancels) |
| `d` | delete the selected subscription |
| `r` | refresh the selected feed |
| `i` | re-read `RSS.OPML` from disk |
| `m` | toggle read/unread on the selected article |
| `o` | open the article link in `WEB.ELF`. The URL is written to `/host/RSS.LINK` and the browser is exec'd with `@/host/RSS.LINK`, because an exec argument is capped at 31 bytes. The full link is always echoed to the console. |
| PgUp / PgDn | page in the reader |
| `q` or Ctrl-C | quit (state is saved) |

## Build

```bash
bash tools/go/build-rss.sh
```

Produces `.build/go/RSS.ELF` for `GOOS=virelai GOARCH=arm64`. The script fails
loudly if the recipe names a non-guest GOOS or if the produced ELF is not
`EM_AARCH64`.

Host-side logic tests (no guest needed — `vi` degrades to `-ENOSYS` on the host):

```bash
cd user/go && go test ./rss/...
```

## Deploy into the guest

The disk image is boot-only; applications live in the **host share** attached
with the runner flag `--cvc-file <host-dir>` and are exec'd **by name**.

1. Copy `.build/go/RSS.ELF` into the shared host directory (the same directory
   the runner passes as `--cvc-file`, alongside `APPS.TXT`).
2. In the guest console (or `GOSH`), run:

   ```
   exec RSS.ELF
   ```

The binary opens its own tab window; no image edit, no catalog change, and no
kernel change is required.

## Runtime requirements

- The guest's network must be up (`net dhcp`, or a static IP + ARP entry) for
  feeds to be fetched. TTL is irrelevant to reading cached articles.
- Nothing else: no config files, no CA bundle, no data directory creation.

## Known limitations

- **HTTPS to the public internet cannot validate.** The guest's TLS client
  (`virelai/tls`) validates against a trust store pinned to a **single** root —
  the AutoClaw test root in `user/go/tls/trust_root_gen.go`
  (`vendoredRootVersion = "virelai-gate-roots-2026-09-14"`). The reader therefore
  fully supports **plain HTTP** feeds and HTTPS feeds served under that pinned
  root, and it **fails closed and says so** (`TLS verification failed (guest
  trust store)`) for anything else. To follow real public HTTPS feeds you must
  add a public CA bundle to the vendored root set — a change to the guest's TLS
  trust surface, deliberately out of scope here. HTTPS is never downgraded to
  cleartext.
- A single feed body is capped at 256 KiB (`vi.MaxFileBytes`), and the article
  cache at 200 entries; both are deliberate bounds.
- No enclosure/podcast playback, no images, no JavaScript-rendered or
  authenticated feeds.
- Refresh is manual (`r`) by design: there is no background polling loop.
- The HTTP client sends `Host` with a non-default port, decodes
  `Transfer-Encoding: chunked`, and follows a short redirect chain. An https
  URL is never followed onto cleartext. It does not decompress gzip.

## Third-party notices

The modules linked into `RSS.ELF` and their licences are listed in
`THIRD-PARTY.txt`. Their sources are not vendored in this repository.

## Rollback

To undo this work, remove these four paths and nothing else:

- `<shared host dir>/RSS.ELF` (the app binary)
- `<shared host dir>/RSS.OPML` (subscriptions)
- `<shared host dir>/RSS.STATE` (read state)
- `<shared host dir>/RSS.CACHE` (article cache)

No kernel, bootloader, disk image, catalog (`image/apps.txt`), settings, or
other guest configuration is touched by this app, so removing those files
returns the guest to exactly its prior behaviour. The in-repo source
(`user/go/rss/`), the build script (`tools/go/build-rss.sh`) and the gate spec
(`tools/gate/specs/go-rss.spec`) are ordinary repository files and can be
reverted with git.
