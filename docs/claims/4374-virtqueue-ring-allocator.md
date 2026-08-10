# Claim: custom-virtio virtqueue ring allocator + multi-queue transport

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** claim 0828 "Next steps" item 1 — turn the boot-time
  exchange API into a real transport: a free-list descriptor allocator over
  the avail ring that recycles descriptors across many concurrent in-flight
  elements, and a second queue (queue 1) driven alongside queue 0.
- **Scope:** `kernel/src/virtio_custom.zig` (queue size 2 → 32, per-queue
  desc/avail/used rings, `alloc_chain`/`free_chain` free-list allocator,
  handle-based `submit`/`wait` matching used-ring `id`s, two armed queues);
  `host/vm-runner/Sources/VMRunner/main.swift` (queue count 1 → 2; the
  delegate already drains any queue by index); `kernel/src/main.zig` spike
  orchestration (concurrent in-flight batches + descriptor-recycle proof);
  `tools/verify-custom-virtio.sh` + `build.zig` spike-virtio gate greps.
  Polled console paths and all existing gates untouched.
- **Depends on:** claim 0828 (the exchange API + used-ring IRQ on the same
  branch), claim 5844 (the host spike device).
- **Status:** ✅ done 2026-08-10 on `agent/buffy/macos27-custom-virtio-spike`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/macos27-custom-virtio-spike' 'virtqueue-ring-allocator'`
= `4374`.

The old API was one exchange in flight at a time on queue 0 (queue size 2,
ring invariant `outstanding < queue size`). The new driver:

- Grows each split ring to size 32 (power of two, Virtio 1.3 §4.1.4.3) and
  arms **two queues** (queue_select 0 and 1), each with its own
  desc/avail/used tables, `queue_notify_off`, and free list.
- Allocates descriptor chains from a per-ring free list
  (`alloc_chain`/`free_chain`); `submit` returns the head descriptor index
  as the element handle, `wait` scans the used ring and matches on the
  used entry's `id` (the head index) so out-of-order completion is handled.
- Proves recycling: two batches of four concurrent in-flight elements are
  submitted, waited on, and freed; the second batch's allocated head
  indices must equal the first's (`cvspike: q0 recycle=1`).

VZ's delegate drains every available element per notification
(`while let element = queue.nextElement()`), so many in-flight elements on
either queue work unchanged. The gate asserts the concurrency + recycle
reports and that queue 1's kicks reach the delegate (`guest notified queue
1`).

## Result — four concurrent in-flight exchanges + deterministic recycling (class B, real VZ boot)

One boot runs two batches of **four elements in flight simultaneously** on
queue 0 (submitted back-to-back, no waits between), all echoed, then the
chains are freed and re-allocated:

```
cvspike: q0 xchg=1 n=0x10 echo=ok
cvspike: q0 xchg=2 n=0x10 echo=ok
cvspike: q0 xchg=3 n=0x10 echo=ok
cvspike: q0 xchg=4 n=0x10 echo=ok
cvspike: q0 heads=0x0,0x2,0x4,0x6 recycle=1
```

`recycle=1` means batch 2's `alloc_chain` returned the **exact same head
indices** (0,2,4,6) as batch 1 — the free-list LIFO (initialized reversed
so low indices pop first) recycles deterministically. The host side shows
the framework coalescing the burst into multiple notifications, each
followed by a full drain (`dequeued 16 byte(s) … echoed 16 byte(s) …
returned element`), and queue 1 is armed + kicked alongside queue 0
(`guest notified queue 1 (size 32)`), which claim 4837 then exercises.

Host side evidence: the delegate prints the queue index per notification
and the per-element read/write/return lines; the guest prints
`cvspike: q0 xchg=… n=0x10 echo=ok` for each in-flight exchange and the
recycle line. Class B live gate `tools/verify-custom-virtio.sh`.

## Root cause found along the way: anonymous slice arrays fold into .rodata with baked pointers

With all buffers BSS-allocated and cache-cleaned, `nextElement()` still
returned nil on every kick. A guest diagnostic showed the first
**read** descriptor carrying `d0.addr=0xc37f0` — an image-relative
address — while the reply descriptor in the same chain carried the correct
absolute `0x7e560940`. The difference: the payload slice was passed inside
an **anonymous array literal** (`&.{payload[0..]}`). Zig const-folds such
literals into .rodata, and the flat kernel loader does not relocate, so
the baked slice held the link-time pointer (the claim-0015 vtable /
cv_log_lines bug class). The fix builds the scatter array in BSS at
runtime (`cv_scatter`), so every element's address is PC-relative-correct;
with that, the device dequeued every element on the first retry.
