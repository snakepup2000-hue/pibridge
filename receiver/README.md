# hqdac — the receiver `aplay` could not be

`aplay` is not a protocol peer. It fills its ALSA buffer before it starts, keeps
its own stdin buffer, and gives you no way to set or verify the fill depth. The
main README's own summary says so: in-flight latency under aplay "settles at
about one buffer depth plus whatever ssh holds, and the settlement point is not
fully under the Mac's control."

`hqdac` is a single static aarch64 binary that issues the PCM ioctls itself.
No alsa-lib, no shared-library dependency, no compiler on the Pi — the constraint
that ruled out building anything there. It is a drop-in for the aplay command
line pibridge already builds, so `--receiver=~/hqdac` is the whole integration.

```
Mac: pibridge/PiBridge ──ssh──▶ Pi: hqdac ──/dev/snd/pcmC0D0p──▶ FiiO K11 R2R
                          │      device buffer: exact, polled
                          └────── ring buffer: the latency budget
```

## Build and install

```bash
./build-static.sh                                    # Docker, linux/arm64, gcc -static
scp hqdac-aarch64 pi:~/hqdac && ssh pi 'chmod +x ~/hqdac'
```

Docker Desktop on Apple Silicon runs arm64 natively, so this is a native
compile in a container, not a cross-compile. The only header needed is the
kernel UAPI's `<sound/asound.h>` from `linux-libc-dev`.

Then, from the Mac:

```bash
./build/pibridge play track.flac --receiver='~/hqdac' --buffer-ms 8 --target-ms 6
./build/pibridge play track.flac --receiver='~/hqdac' --buffer-ms 20 --target-ms 15 --mode dsd
```

## What the two buffers mean

| buffer | flag | who owns it | what it does |
|---|---|---|---|
| device (DMA) | `--buffer-time` | the kernel/USB stack | measured with `DELAY`, reported every 250 ms |
| ring | `--target-time` | this program | latency budget and jitter absorption |

The ring's **capacity** is the target, not four times it: a sender at line rate
keeps it full, so its depth is what the listener hears as delay. Total in-flight
is `ring + device`, and both numbers are exact rather than inferred.

Two behaviours that matter, both learned the hard way here:

- **Prefill, then start.** A playback stream xruns the instant its buffer is
  empty, so `START` before any write is an immediate underrun. `hqdac` fills the
  device buffer first and then starts, explicitly — it also sets
  `start_threshold` to two buffers so the kernel never auto-starts behind its back.
- **Write the whole free space**, not a fixed chunk, so the device buffer spends
  its life near full instead of sawtoothing down toward an underrun.

## Measured on the K11, not estimated

All figures are the **device fill** (`SNDRV_PCM_IOCTL_DELAY`) sampled on the Pi
every 5–10 ms, not pibridge's own 80 ms poll — that poll aliases against a small
buffer and reports phantom minimums.

| test | result |
|---|---|
| device caps via `HW_REFINE` | formats `S16_LE S32_LE S24_3LE DSD_U32_BE`, rate `44100..384000`, channels `2..2`, period floor `125 µs`, buffer floor `41 µs` |
| 20 ms device buffer, PCM | min 19.00, mean 20.08, max 20.25 ms |
| 8 ms device + 4 ms ring, PCM | min 7.00, mean 8.18, max 8.75 ms, **0 zeros** |
| 4 ms device + 2 ms ring, PCM | min 3.00, mean 4.21, max 4.88 ms, **0 zeros** |
| 4 ms device + 2 ms ring, DSD256 | min 7.00, mean 8.19, max 8.88 ms, **0 zeros** |
| 185 s continuous at 4/2, sampled 1,848× | block means 4.13–4.21 ms — **no drift** |
| full 7-minute track at 4/2 | **0 underruns** |

Two findings worth stating because they were assumptions before:

- **4 ms is the hardware floor.** Requests for 2 ms and 3 ms produce exactly the
  same 3.00–4.88 ms result as 4 ms: the driver quantises to a 1536-frame buffer.
- **No drift correction is needed.** Over 185 s at the tightest buffer the mean
  fill stayed within 4.13–4.21 ms, so pibridge's experimental `--steer` loop
  stays off by default and is not required for long playback.

The device caps also independently confirm three claims that were previously only
asserted: the four accepted formats, the 384 kHz ceiling, and the 16-frame
(41 µs) buffer floor.

## Limits, stated plainly

- `plughw`/`default` are refused. There is no conversion layer, and silently
  accepting a mismatched format would hide exactly the fault this tool exists to
  expose.
- One instance only — the K11 has a single playback subdevice. A second one now
  fails **immediately** with `Device or resource busy` instead of hanging in a
  blocking `open()`.
- Requests below the hardware floors are clamped, not rejected: `--buffer-time=100
  --period-time=50` becomes period 48 frames / buffer 96 frames (0.25 ms).
- 4 ms is the smallest buffer the K11 will actually hold; 2 ms and 3 ms requests
  silently become 4 ms.
- `--stats` writes fill telemetry to stderr. pibridge swallows its child's
  stderr (it only counts `underrun` occurrences), so pass
  `--receiver='~/hqdac --stats'` when running the receiver by hand.

## How pibridge uses it

`--receiver=~/hqdac` is the whole integration, and it changes two defaults
automatically:

- **Pacing becomes `backpressure`.** The clock pacer was written against aplay
  (wait for aplay to fill, then drain it). Against hqdac it fought the receiver:
  measured, clock pacing left a 20 ms request at 5 ms of fill while backpressure
  held 20.08 ms. An explicit `--pace` still wins.
- **`--target-time` becomes half the buffer**, i.e. the ring depth.

The PiBridge app has a **Receiver** field in Settings (default `~/hqdac`), sends
`--receiver` and `--target-ms` on every play, and migrates the old 60 ms buffer
default to 8 ms once. `pibridge diag` reports the installed receiver and its
confirmed formats; a missing receiver is one clear error before any stream opens
rather than ssh exiting 127 mid-playback.

## Files

```
hqdac.c            the receiver, one translation unit
build-static.sh    Docker build -> hqdac-aarch64 (static, stripped, ~714 KB)
```
