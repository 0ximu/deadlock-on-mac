#!/bin/zsh
# deadlock-mac-setup.sh - run Valve's Deadlock on Apple Silicon Macs.
#
#   curl -fsSL https://0ximu.dev/deadlock-mac-setup.sh | zsh
#
# What it does:
#   1. Downloads the CrossOver trial from CodeWeavers' own servers and
#      extracts its wine engine (wine 10/11 + Apple's D3DMetal). Older wine
#      builds (9.x and the standalone Game Porting Toolkit) can no longer run
#      the 2026 Steam client - this is the only engine line that works.
#   2. Builds a self-contained Deadlock.app: wine engine + its own wine
#      prefix + a launcher that sets the exact environment D3DMetal needs.
#   3. Installs Windows Steam into the prefix and opens it. You log in,
#      install Deadlock from your library, hit Play.
#
# Honesty corner:
#   - CrossOver is CodeWeavers' product; this uses their freely downloadable
#     trial build. If this setup earns a place in your life, buy a license -
#     they are the reason wine works this well on macOS at all.
#   - Deadlock uses user-mode VAC today and people play under wine without
#     bans, but Valve does not support this. A future anti-cheat change can
#     break it. You accept that risk.
#   - Not affiliated with Valve, CodeWeavers, or Apple.
#
# Requirements: Apple Silicon, macOS 14+, ~80 GB free, a Steam account that
# owns/has access to Deadlock.

set -euo pipefail

say()  { print -P "%F{green}[deadlock-setup]%f $1"; }
warn() { print -P "%F{yellow}[deadlock-setup]%f $1"; }
die()  { print -P "%F{red}[deadlock-setup]%f $1"; exit 1; }

# ---------- sanity checks ----------
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon only (this Mac reports $(uname -m))."
OSMAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( OSMAJOR >= 14 )) || die "macOS 14 (Sonoma) or newer required."

TARGET="${1:-$HOME/Applications/Deadlock.app}"
TARGET="${TARGET:A}"
[[ -e "$TARGET" ]] && die "$TARGET already exists. Delete it or pass a different path: ... | zsh -s -- /path/Deadlock.app"

TARGET_DIR="${TARGET:h}"
mkdir -p "$TARGET_DIR"
FREE_GB=$(df -g "$TARGET_DIR" | awk 'NR==2 {print $4}')
(( FREE_GB >= 80 )) || warn "Only ${FREE_GB} GB free at $TARGET_DIR. Deadlock needs ~50 GB plus updates - consider an external APFS drive (pass its path as the first argument)."

WORK=$(mktemp -d /tmp/deadlock-setup.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------- fetch CrossOver trial ----------
CX_ZIP="$WORK/crossover.zip"
CX_VERSIONS=(${CROSSOVER_VERSION:-} 27.0.1 27.0.0 26.1.2 26.1.1 26.1.0 26.0.0)
CX_URL=""
for v in $CX_VERSIONS; do
  [[ -z "$v" ]] && continue
  url="https://media.codeweavers.com/pub/crossover/cxmac/demo/crossover-$v.zip"
  if curl -sfI "$url" >/dev/null 2>&1; then CX_URL="$url"; CX_VER="$v"; break; fi
done
[[ -n "$CX_URL" ]] || die "Could not find a downloadable CrossOver trial build. Set CROSSOVER_VERSION=<version> and retry."

say "Downloading CrossOver $CX_VER trial (~400 MB) from CodeWeavers..."
curl -fL --progress-bar -o "$CX_ZIP" "$CX_URL"

say "Extracting wine engine..."
unzip -q "$CX_ZIP" -d "$WORK/cx"
CX_ROOT_SRC="$WORK/cx/CrossOver.app/Contents/SharedSupport/CrossOver"
[[ -d "$CX_ROOT_SRC" ]] || die "Unexpected CrossOver layout - report this at 0ximu.dev."

# ---------- build the app bundle ----------
say "Building $TARGET ..."
SS="$TARGET/Contents/SharedSupport"
mkdir -p "$TARGET/Contents/MacOS" "$SS/Logs" "$SS/cxhome"
cp -Rp "$CX_ROOT_SRC" "$SS/wine"
# CrossOver's bin/wine is a bottle-manager perl script; the raw loader is
# wineloader. Swap them so plain WINEPREFIX invocation works.
mv "$SS/wine/bin/wine" "$SS/wine/bin/wine.cxscript"
ln "$SS/wine/bin/wineloader" "$SS/wine/bin/wine"

cat > "$TARGET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>deadlock-launch</string>
  <key>CFBundleIdentifier</key><string>dev.0ximu.deadlock-wrapper</string>
  <key>CFBundleName</key><string>Deadlock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Deadlock uses the microphone for in-game voice chat.</string>
</dict>
</plist>
PLIST

# Launcher. TARGET path is baked in on purpose: macOS App Translocation can
# run bundle scripts from a read-only copy, which breaks relative paths.
cat > "$TARGET/Contents/MacOS/deadlock-launch" <<LAUNCH
#!/bin/zsh
SS="$SS"

LOGDIR="\$SS/Logs"; mkdir -p "\$LOGDIR"
LOG="\$LOGDIR/launch-\$(date +%Y%m%d-%H%M%S).log"
ls -t "\$LOGDIR"/launch-*.log 2>/dev/null | tail -n +6 | while read -r f; do rm -f "\$f"; done
exec >>"\$LOG" 2>&1
echo "=== Deadlock launch \$(date) ==="

# Orphaned wine processes look idle in ps (decayed average) but can spin
# whole cores. Sweep them when no wineserver session is alive.
OUR_WS=\$(pgrep -f "\$SS/wine/bin/wineserver" | head -1)
if [ -z "\$OUR_WS" ]; then
    pkill -9 -f "\$SS/wine" 2>/dev/null && echo "killed stale wrapper processes"
    if ! pgrep -x wineserver >/dev/null 2>&1; then
        for p in \$(pgrep -f '/T//winetemp-'); do
            kill -9 "\$p" 2>/dev/null && echo "killed orphan winetemp pid \$p"
        done
    else
        echo "another wineserver is live - leaving winetemp processes alone"
    fi
fi

export WINEPREFIX="\$SS/prefix"
export PATH="\$SS/wine/bin:\$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="\$SS/wine/lib:\$SS/wine/lib64:/usr/lib"
export GST_PLUGIN_SYSTEM_PATH="\$SS/wine/lib64/gstreamer-1.0"
# CX_ROOT is required by wine's cxcompatdb.so; without it the D3DMetal
# redirect never fires and games silently fall back to 10fps wined3d.
export CX_ROOT="\$SS/wine"
export CX_HOME="\$SS/cxhome"
export CX_GRAPHICS_BACKEND=d3dmetal
export CX_APPLEGPTK_LIBD3DSHARED_PATH="\$SS/wine/lib64/apple_gptk/external/libd3dshared.dylib"
export WINEMSYNC=1
export MTL_HUD_ENABLED=\${DEADLOCK_HUD:-0}
export WINEDEBUG=-all

echo "starting Steam"
exec "\$SS/wine/bin/wine" "C:\\\\Program Files (x86)\\\\Steam\\\\Steam.exe" "\$@"
LAUNCH
chmod +x "$TARGET/Contents/MacOS/deadlock-launch"

# ---------- init prefix + install Steam ----------
say "Creating wine prefix (first wine start takes ~a minute)..."
export WINEPREFIX="$SS/prefix"
export PATH="$SS/wine/bin:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$SS/wine/lib:$SS/wine/lib64:/usr/lib"
export CX_ROOT="$SS/wine" CX_HOME="$SS/cxhome" WINEMSYNC=1 WINEDEBUG=-all
"$SS/wine/bin/wine" wineboot -u >/dev/null 2>&1 || die "wineboot failed - check $SS/Logs"

say "Installing Windows Steam..."
curl -fsSL -o "$WORK/SteamSetup.exe" "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
"$SS/wine/bin/wine" "$WORK/SteamSetup.exe" /S >/dev/null 2>&1 || true
[[ -f "$SS/prefix/drive_c/Program Files (x86)/Steam/Steam.exe" ]] || die "Steam install failed - check $SS/Logs"

xattr -cr "$TARGET" 2>/dev/null || true
codesign --force --deep -s - "$TARGET" >/dev/null 2>&1 || true

say "Done. Launching Steam - it will download a ~350 MB client update first."
open "$TARGET"

cat <<'NEXT'

Next steps:
  1. If you run a firewall like LuLu / Little Snitch: ALLOW wine and
     wine-preloader when prompted, or Steam will report "needs to be online".
  2. Log into Steam (QR code via the mobile app is the most reliable path).
  3. Install Deadlock from your library, hit Play.
  4. First session stutters while shaders compile - it smooths out. Set
     resolution to 1440p-ish and start with Medium; High works on M-Max chips.

Launch anytime by opening Deadlock.app. Logs live in
Deadlock.app/Contents/SharedSupport/Logs. Metal HUD for debugging:
DEADLOCK_HUD=1 open <path to Deadlock.app>
NEXT
