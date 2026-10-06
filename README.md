# Deadlock on Mac

Run Valve's **Deadlock** on Apple Silicon Macs at 60+ FPS. No Windows machine, no dual boot, no Parallels.

Full story of how this was figured out: [0ximu.dev/blog/deadlock-on-mac](https://0ximu.dev/blog/deadlock-on-mac)

## What you need

- Apple Silicon Mac (M1 or newer; the more GPU cores the better)
- macOS 14 Sonoma or newer
- ~80 GB free disk space (an external APFS SSD works great)
- A Steam account with Deadlock access

## Install (no terminal skills needed)

1. Download [`Install Deadlock.command`](https://github.com/0ximu/deadlock-on-mac/releases/latest) from the latest release.
2. In Finder, **right-click the file and choose "Open"** (a plain double-click gets blocked by macOS because the file is not notarized). Confirm the dialog.
3. A Terminal window opens and does everything: downloads the CrossOver trial engine from CodeWeavers, builds a self-contained `Deadlock.app` in your `~/Applications`, installs Windows Steam inside it, and launches Steam.
4. If you use a firewall app (LuLu, Little Snitch): **allow `wine` and `wine-preloader`** when asked, or Steam cannot go online.
5. Log into Steam (the QR code + Steam mobile app is the most reliable way), install Deadlock from your library, press Play.

Want it on an external drive? Run instead:

```sh
curl -fsSL https://0ximu.dev/deadlock-mac-setup.sh | zsh -s -- /Volumes/YourDrive/Deadlock.app
```

## After install

- Launch by opening `Deadlock.app`. It cleans up stale wine processes on every start and keeps launch logs in `Deadlock.app/Contents/SharedSupport/Logs`.
- The first session stutters while shaders compile. That is normal and goes away.
- Start at 1440p / Medium settings. M-Max chips handle High at 60+.
- Debug overlay (Apple's Metal HUD): `DEADLOCK_HUD=1 open ~/Applications/Deadlock.app`

## How it works

Three translation layers, all local:

| Layer | Job |
|-------|-----|
| wine 10/11 (CrossOver 26+ build) | Windows syscalls → macOS. Older wine (9.x, standalone GPTK) can no longer run the 2026 Steam client. |
| D3DMetal (Apple Game Porting Toolkit, ships inside CrossOver) | DirectX 11 → Metal |
| Rosetta 2 | x86-64 → ARM |

The launcher exports `CX_ROOT`, `CX_GRAPHICS_BACKEND=d3dmetal` and the `libd3dshared` path. Without those, CrossOver's `cxcompatdb.so` silently skips the D3DMetal redirect and you get wine's fallback renderer at ~10 FPS. That trap alone justified this repo.

## Performance checklist

Low FPS or stutter? Run these checks before touching game settings - they were the actual killers on my machine, and none of them show an error anywhere.

**1. Verify D3DMetal is really rendering** (the 10 FPS trap). While the game runs:

```sh
lsof -p $(pgrep -f deadlock.exe) | grep -oiE 'D3DMetal|wined3d|dxvk' | sort -u
```

If this prints `wined3d` and no `D3DMetal`, you are on wine's slow fallback renderer - that alone is the difference between 10 and 60+ FPS. It happens silently when the D3DMetal environment (`CX_ROOT` and friends) does not reach the game. Launch through `Deadlock.app`, not a bare `wine` call; on other setups (Sikarugir, hand-rolled wrappers) check their engine actually engages D3DMetal.

**2. Hunt orphaned wine processes.** Crashed or half-killed sessions leave wine processes that show **0% in `ps` and Activity Monitor** (decayed averages) while spinning half a core each, forever:

```sh
sudo powermetrics -n 1 -i 3000 --samplers tasks | head -25
```

Anything named `wine-preloader` burning hundreds of ms/s that is not your current session is a zombie - kill it. I found fourteen of them eating ~7 cores; FPS tripled on the spot. The launcher in this repo sweeps them on every start, but other setups do not.

**3. Know your teamfight stutter.** On fanless machines (MacBook Air) sustained teamfight load means thermal throttling, and in the first few sessions every ability effect you see for the first time compiles a Metal pipeline mid-fight. The shader part genuinely goes away with hours played; the thermal part improves with an FPS cap (60) and lower resolution. Also check nothing else is eating cores while you play - a background compile job stutters the game exactly like a bad config does.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Download failed: http error 0`, Steam "needs to be online" | Firewall silently blocked wine. Allow `wine` + `wine-preloader`. |
| `steamwebhelper is not responding` or `Transport Error (0x3008)` | Wine build too old for current Steam. Re-run the installer to get a current CrossOver engine. |
| Game renders fine but ~10 FPS, GPU half idle | wined3d fallback. Verify with `lsof -p $(pgrep -f deadlock.exe) \| grep -oiE 'D3DMetal\|wined3d'` - if no D3DMetal, the launcher env is not reaching the game; launch via `Deadlock.app`, not a bare `wine` call. |
| Works from Terminal, "unable to write to its folder" from Finder | App Translocation. The generated launcher uses absolute paths to avoid it; do not move the app without re-running `xattr -cr` + `codesign -f -s -` on it. |
| Random stutter, everything looks idle in `ps` | Orphaned wine processes or background builds. `sudo powermetrics -n 1 -i 3000 --samplers tasks \| head -30` shows the truth; the launcher sweeps orphans on start. |
| Steam login freezes at the 2FA step | Use the QR code with the Steam mobile app instead. |
| Opening Deadlock's Settings freezes the game | Older wrappers lack the macOS microphone permission description. See the repair below. |

### Repair Settings freezing on older installs

Opening Settings can trigger microphone access for voice chat, even when game audio is muted. On an affected CrossOver wine build, a wrapper missing `NSMicrophoneUsageDescription` was observed waiting indefinitely for the macOS microphone permission request to finish. New installs include this declaration.

For an existing installation, quit Deadlock and Steam completely, then run the following in Terminal. Change `APP` if you installed elsewhere or renamed the app:

```sh
APP="$HOME/Applications/Deadlock.app"
plutil -replace NSMicrophoneUsageDescription -string "Deadlock uses the microphone for in-game voice chat." "$APP/Contents/Info.plist" &&
  codesign --force --sign - "$APP" &&
  codesign --verify --verbose=2 "$APP"
```

Reopen the app from Finder and try Settings again. macOS may ask for microphone access; allow it if you want voice chat. This updates the wrapper's permission description and signature while preserving your installed games and settings.

## Fine print

- The installer downloads the **CrossOver trial** from CodeWeavers' own servers and builds everything locally; nothing proprietary is redistributed here. The trial's 14-day limit applies to the CrossOver app, which this setup never runs - the extracted wine engine is open source (LGPL) and has no expiry. If this setup sticks, [buy a CrossOver license](https://www.codeweavers.com/store) anyway: CodeWeavers fund a huge share of wine development, and the license nudge is about supporting the people who made this possible, not about anything breaking.
- Deadlock uses user-mode VAC today and wine players are not being banned, but Valve does not support this setup. A future anti-cheat change could break it. You accept that risk.
- Not affiliated with Valve, CodeWeavers, or Apple.

## License

MIT for the scripts in this repo.
