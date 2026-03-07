#!/usr/bin/env zsh
# install.sh — sets up Wisdom Translator on macOS
#
# What it does:
#   1. Checks Python 3 and required packages are available
#   2. Creates ~/bin/wisdom-translator (terminal launcher)
#   3. Creates /Applications/Wisdom Translator.app (Spotlight launcher)
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

# ── 3. ~/bin launcher ─────────────────────────────────────────────────────
BIN_DIR="$HOME/bin"
mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/wisdom-translator"

cat > "$LAUNCHER" << EOF
#!/usr/bin/env zsh
exec /usr/bin/env python3 "$SCRIPT" "\$@"
EOF
chmod +x "$LAUNCHER"
ok "Terminal launcher created: $LAUNCHER"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your PATH."
    warn "Add this line to your ~/.zshrc:   export PATH=\"\$HOME/bin:\$PATH\""
fi

# ── 4. /Applications/.app bundle ─────────────────────────────────────────
APP="/Applications/Wisdom Translator.app"
MACOS_DIR="$APP/Contents/MacOS"
mkdir -p "$MACOS_DIR"
mkdir -p "$APP/Contents/Resources"

cat > "$MACOS_DIR/WisdomTranslator" << EOF
#!/usr/bin/env zsh
exec /usr/bin/env python3 "$SCRIPT" "\$@"
EOF
chmod +x "$MACOS_DIR/WisdomTranslator"

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
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

touch "$APP"
mdimport "$APP" 2>/dev/null && ok "Spotlight index updated" || warn "mdimport failed — Spotlight will index the app on its next scan"
ok "App bundle created: $APP"

# ── Done ───────────────────────────────────────────────────────────────────
print "\n✅  Installation complete!\n"
print "  • Terminal:  wisdom-translator"
print "  • Spotlight: ⌘ Space → type 'Wisdom'\n"
