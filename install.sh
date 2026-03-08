#!/usr/bin/env zsh
# install.sh — sets up Wisdom Translator on macOS
#
# What it does:
#   1. Checks Python 3 and required packages are available
#   2. Creates ~/bin/wisdom-translator (terminal launcher)
#   3. Creates /Applications/Wisdom Translator.app (Spotlight launcher)
#      - Uses absolute python3 path so Spotlight's minimal env works
#      - Generates a unique AppIcon.icns via make_icon.py
#   4. Triggers Spotlight re-indexing of the new app
#
# Usage (from the repo root):
#   chmod +x install.sh && ./install.sh

set -euo pipefail

# ── Resolve repo root (works wherever the script is called from) ───────────
REPO_DIR="${0:A:h}"
SCRIPT="$REPO_DIR/wisdom_trans.py"

# ── Colours for output ─────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { print -P "%F{green}✓%f $1"; }
warn() { print -P "%F{yellow}⚠%f $1"; }
err()  { print -P "%F{red}✗%f $1"; exit 1; }

print "\n🔧  Wisdom Translator — Installer\n"

# ── 1. Verify Python 3 ─────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    err "python3 not found. Install it via: brew install python"
fi
ok "python3 found: $(python3 --version)"

# ── 2. Verify required packages ────────────────────────────────────────────
MISSING=()
python3 -c "import deep_translator" 2>/dev/null || MISSING+=("deep-translator")
python3 -c "import pypinyin"        2>/dev/null || MISSING+=("pypinyin")
python3 -c "import tkinter"         2>/dev/null || MISSING+=("python-tk (brew install python-tk@3.x)")

if (( ${#MISSING[@]} )); then
    warn "Missing packages: ${MISSING[*]}"
    warn "Install with:  pip3 install ${MISSING[*]}"
    warn "  (for tkinter: brew install python-tk@\$(python3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")'))"
    err "Please install missing packages and re-run install.sh"
fi
ok "All Python dependencies present"

# ── 3. Resolve absolute python3 path (required for Spotlight launch) ──────
# Spotlight starts apps with a minimal PATH that excludes /opt/homebrew/bin,
# so we must hard-code the real python3 binary — not a shim or env lookup.
PYTHON3_BIN="$(command -v python3)"
# Follow shims to the real executable (pyenv, asdf, etc.)
if [[ "$PYTHON3_BIN" == *shim* || "$PYTHON3_BIN" == *pyenv* ]]; then
    PYTHON3_BIN="$(python3 -c 'import sys; print(sys.executable)')"
fi
ok "Using python3 at: $PYTHON3_BIN"

# ── 4. ~/bin launcher ─────────────────────────────────────────────────────
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/wisdom-translator"

cat > "$LAUNCHER" << EOF
#!/bin/zsh
exec "$PYTHON3_BIN" "$SCRIPT" "\$@"
EOF
chmod +x "$LAUNCHER"
ok "Terminal launcher created: $LAUNCHER"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your PATH."
    warn "Add this line to your ~/.zshrc:   export PATH=\"\$HOME/bin:\$PATH\""
fi

# ── 5. /Applications/.app bundle ─────────────────────────────────────────
APP="/Applications/Wisdom Translator.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# Launcher uses absolute python3 + sets minimal PATH for Spotlight compatibility
cat > "$MACOS_DIR/WisdomTranslator" << EOF
#!/bin/zsh
export HOME="\${HOME:-$HOME}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
exec "$PYTHON3_BIN" "$SCRIPT" "\$@"
EOF
chmod +x "$MACOS_DIR/WisdomTranslator"

# ── 6. App icon ───────────────────────────────────────────────────────────
ICONSET_DIR="/tmp/WisdomTranslator.iconset"
ICNS_FILE="$RES_DIR/AppIcon.icns"

python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import math, os, sys

def make_bg(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    r = size // 7
    steps = size
    for i in range(steps):
        t = i / (steps - 1)
        rr = int(200 * (1 - t) + 26  * t)
        gg = int(150 * (1 - t) + 39  * t)
        bb = int(12  * (1 - t) + 68  * t)
        draw.line([(r if i < r or i > size - r else 0), i,
                   (size - r - 1 if i < r or i > size - r else size - 1), i],
                  fill=(rr, gg, bb, 255))
    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    img.putalpha(mask)
    return img

def make_icon(size):
    img = make_bg(size)
    draw = ImageDraw.Draw(img)
    s = size
    cx, cy = s // 2, s // 2
    bw = int(s * 0.68)
    bh = int(s * 0.46)
    bx = cx - bw // 2
    by = cy - bh // 2 + int(s * 0.04)
    spine_w = max(3, s // 80)
    lpts = [
        (bx,           by + int(bh * 0.10)),
        (cx - spine_w, by),
        (cx - spine_w, by + bh),
        (bx,           by + bh - int(bh * 0.08)),
    ]
    draw.polygon(lpts, fill=(255, 252, 235, 235))
    rpts = [
        (cx + spine_w, by),
        (bx + bw,      by + int(bh * 0.10)),
        (bx + bw,      by + bh - int(bh * 0.08)),
        (cx + spine_w, by + bh),
    ]
    draw.polygon(rpts, fill=(255, 252, 235, 235))
    draw.line([(cx, by - int(s*0.01)), (cx, by + bh + int(s*0.01))],
              fill=(180, 140, 20, 230), width=spine_w)
    font_paths = [
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    latin_font = None
    for fp in font_paths:
        if os.path.exists(fp):
            try:
                latin_font = ImageFont.truetype(fp, max(10, s // 8))
                break
            except Exception:
                continue
    glyph_col = (40, 30, 5, 240)
    if latin_font:
        ltext = "A \u2192"
        lbbox = draw.textbbox((0, 0), ltext, font=latin_font)
        lw, lh = lbbox[2] - lbbox[0], lbbox[3] - lbbox[1]
        draw.text(
            (bx + (bw // 2 - spine_w - lw) // 2, by + (bh - lh) // 2),
            ltext, font=latin_font, fill=glyph_col)
        rtext = "\u6587"
        rbbox = draw.textbbox((0, 0), rtext, font=latin_font)
        rw, rh = rbbox[2] - rbbox[0], rbbox[3] - rbbox[1]
        draw.text(
            (cx + spine_w + (bw // 2 - spine_w - rw) // 2, by + (bh - rh) // 2),
            rtext, font=latin_font, fill=glyph_col)
    line_col = (200, 180, 100, 100)
    lw_pad = int(bw * 0.06)
    line_x1 = cx - spine_w - lw_pad
    for i in range(3):
        ly = by + bh * (i + 2) // 5
        draw.line([(bx + lw_pad, ly), (line_x1, ly)],
                  fill=line_col, width=max(1, s // 256))
    sx, sy = int(s * 0.78), int(s * 0.18)
    sr = max(2, s // 28)
    star_col = (255, 235, 80, 210)
    for angle in range(0, 360, 45):
        rad = math.radians(angle)
        ex = sx + int(sr * 1.8 * math.cos(rad))
        ey = sy + int(sr * 1.8 * math.sin(rad))
        draw.line([(sx, sy), (ex, ey)], fill=star_col, width=max(1, s // 128))
    draw.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=star_col)
    return img

iconset_dir = "/tmp/WisdomTranslator.iconset"
os.makedirs(iconset_dir, exist_ok=True)
for sz in [16, 32, 64, 128, 256, 512, 1024]:
    make_icon(sz).save(f"{iconset_dir}/icon_{sz}x{sz}.png")
    if sz <= 512:
        make_icon(sz * 2).save(f"{iconset_dir}/icon_{sz}x{sz}@2x.png")
print("Iconset generated")
PYEOF

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE" \
    && ok "App icon generated: $ICNS_FILE" \
    || warn "iconutil failed — app will use default icon"
rm -rf "$ICONSET_DIR"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WisdomTranslator</string>
    <key>CFBundleIdentifier</key>
    <string>com.quasaur.wisdom-translator</string>
    <key>CFBundleName</key>
    <string>Wisdom Translator</string>
    <key>CFBundleDisplayName</key>
    <string>Wisdom Translator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
</dict>
</plist>
EOF

touch "$APP"
mdimport "$APP" 2>/dev/null && ok "Spotlight index updated" || warn "mdimport failed — Spotlight will index the app on its next scan"
ok "App bundle created: $APP"

# ── Done ───────────────────────────────────────────────────────────────────
print "\n✅  Installation complete!\n"
print "  • Terminal:  wisdom-translator"
print "  • Spotlight: ⌘ Space → type 'Wisdom'"
print "  • Settings:  ~/.config/wisdom-trans/prefs.json (created on first use)\n"
