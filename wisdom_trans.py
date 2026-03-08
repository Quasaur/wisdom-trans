#!/usr/bin/env python3
"""
Wisdom Translator — English to ES / FR / HI / ZH-Pinyin
Run: python3 wisdom_trans.py
"""

import ctypes
import ctypes.util
import json
import re
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import font as tkfont
from tkinter import ttk

from deep_translator import GoogleTranslator
from pypinyin import Style, lazy_pinyin

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MAX_CHARS    = 1000
DEBOUNCE_MS  = 900
IN_HEIGHT    = 6   # rows — English input box
OUT_HEIGHT   = 7   # rows — each translation box
BASE_FONT_SZ = 11  # pt — starting size for all text widgets
FONT_STEP    = 2   # pt — increment per zoom level
MAX_ZOOM     = 3   # maximum number of zoom-in steps

PREFS_FILE = Path.home() / ".config" / "wisdom-trans" / "prefs.json"

# macOS system color tokens (auto-adapt to Light / Dark mode)
_FIELD_BG = "systemTextBackgroundColor"
_TEXT_FG  = "systemLabelColor"
_CTRL_BG  = "systemControlBackgroundColor"
_SEL_BG   = "systemSelectedTextBackgroundColor"
_SEL_FG   = "systemSelectedTextColor"
_DIM_FG   = "systemSecondaryLabelColor"
_ERR_FG   = "systemRed"

LANGUAGES = [
    ("Spanish (Spain)",             "es"),
    ("French (France)",             "fr"),
    ("Hindi",                       "hi"),
    ("Chinese (Simplified) Pinyin", "zh-CN"),   # translated then romanised
]


# ---------------------------------------------------------------------------
# macOS menu-bar name override (no pyobjc required)
# ---------------------------------------------------------------------------
def _macos_rename_app(name: str) -> None:
    """
    Change the macOS menu-bar app name from 'Python' to *name* by:
      1. Writing CFBundleName into the main bundle's info dictionary
         (this is what Tk reads when it builds the Application menu).
      2. Setting NSProcessInfo.processName so Activity Monitor and
         the Dock tooltip also show the custom name.
    Must be called BEFORE tk.Tk() so Tk picks up the new bundle name.
    """
    if sys.platform != "darwin":
        return
    try:
        _lib = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
        _lib.objc_getClass.restype   = ctypes.c_void_p
        _lib.objc_getClass.argtypes  = [ctypes.c_char_p]
        _lib.sel_registerName.restype  = ctypes.c_void_p
        _lib.sel_registerName.argtypes = [ctypes.c_char_p]

        # Cast objc_msgSend to typed wrappers for each call shape
        _addr  = ctypes.cast(_lib.objc_msgSend, ctypes.c_void_p).value
        msg0   = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(_addr)
        msg_cs = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p)(_addr)
        msg_o  = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(_addr)
        msg_oo = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(_addr)

        sel = _lib.sel_registerName
        cls = _lib.objc_getClass

        NSString = cls(b"NSString")
        sel_utf8 = sel(b"stringWithUTF8String:")
        ns_name  = msg_cs(NSString, sel_utf8, name.encode("utf-8"))
        ns_key   = msg_cs(NSString, sel_utf8, b"CFBundleName")

        # 1. Patch CFBundleName in the running bundle's info dictionary
        bundle = msg0(cls(b"NSBundle"), sel(b"mainBundle"))
        info   = msg0(bundle, sel(b"infoDictionary"))
        msg_oo(info, sel(b"setValue:forKey:"), ns_name, ns_key)

        # 2. Update the process name (Dock / Activity Monitor)
        proc_info = msg0(cls(b"NSProcessInfo"), sel(b"processInfo"))
        msg_o(proc_info, sel(b"setProcessName:"), ns_name)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Preferences (persist zoom level across runs)
# ---------------------------------------------------------------------------
def _load_prefs() -> dict:
    try:
        return json.loads(PREFS_FILE.read_text())
    except Exception:
        return {}


def _save_prefs(data: dict) -> None:
    try:
        PREFS_FILE.parent.mkdir(parents=True, exist_ok=True)
        PREFS_FILE.write_text(json.dumps(data))
    except Exception:
        pass


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
class WisdomTranslator:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Wisdom Translator")
        self.root.resizable(True, True)
        ttk.Style().theme_use("aqua")

        self._debounce_id: str | None = None
        self._last_translated: str = ""
        self._zoom_level: int = _load_prefs().get("zoom_level", 0)

        # Shared font objects — configuring size here updates every widget.
        initial_size = BASE_FONT_SZ + self._zoom_level * FONT_STEP
        self._bold_font = tkfont.Font(family="Helvetica", size=initial_size, weight="bold")
        self._mono_font = tkfont.Font(family="Menlo",     size=initial_size)

        self._build_ui()
        self._bind_zoom_keys()

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        bold = self._bold_font
        mono = self._mono_font

        # Give all four LabelFrame titles the same bold font as the
        # "English" label above the input box.
        style = ttk.Style()
        style.configure("Bold.TLabelframe.Label", font=bold)

        # ── Scrollable canvas (whole-window scroll) ────────────────────
        vsb = ttk.Scrollbar(self.root, orient=tk.VERTICAL)
        vsb.pack(side=tk.RIGHT, fill=tk.Y)

        self._canvas = tk.Canvas(self.root, highlightthickness=0, yscrollcommand=vsb.set)
        self._canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        vsb.configure(command=self._canvas.yview)

        outer = ttk.Frame(self._canvas, padding=16)
        self._cwin = self._canvas.create_window((0, 0), window=outer, anchor="nw")

        outer.bind(
            "<Configure>",
            lambda e: self._canvas.configure(scrollregion=self._canvas.bbox("all")),
        )
        self._canvas.bind(
            "<Configure>",
            lambda e: self._canvas.itemconfig(self._cwin, width=e.width),
        )
        self._canvas.bind_all(
            "<MouseWheel>",
            lambda e: self._canvas.yview_scroll(int(-1 * e.delta / 60), "units"),
        )

        # ── English input — full-width single row ──────────────────────
        ttk.Label(outer, text="English", font=bold, anchor="w").pack(fill=tk.X)

        en_wrap = ttk.Frame(outer)
        en_wrap.pack(fill=tk.X, pady=(4, 2))

        self.en_text = tk.Text(
            en_wrap,
            height=IN_HEIGHT,
            font=mono,
            wrap=tk.WORD,
            relief=tk.FLAT,
            bd=0,
            padx=6,
            pady=6,
            background=_FIELD_BG,
            foreground=_TEXT_FG,
            insertbackground=_TEXT_FG,
            selectbackground=_SEL_BG,
            selectforeground=_SEL_FG,
            highlightthickness=2,
            highlightbackground="#FFD700",
            highlightcolor="#FFD700",
        )
        en_sb = ttk.Scrollbar(en_wrap, orient=tk.VERTICAL, command=self.en_text.yview)
        self.en_text.configure(yscrollcommand=en_sb.set)
        en_sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.en_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self.char_var = tk.StringVar(value="0 / 1000")
        self.char_label = ttk.Label(
            outer, textvariable=self.char_var, foreground=_DIM_FG, anchor="e"
        )
        self.char_label.pack(fill=tk.X, pady=(2, 6))

        self.en_text.bind("<KeyRelease>", self._on_input)
        self.en_text.bind("<<Paste>>", lambda e: self.root.after(10, self._on_input))

        # ── Translate button + status ──────────────────────────────────
        ctrl = ttk.Frame(outer)
        ctrl.pack(fill=tk.X, pady=(0, 10))
        self.trans_btn = ttk.Button(ctrl, text="Translate", command=self._trigger_translate)
        self.trans_btn.pack(side=tk.LEFT)
        self.status_var = tk.StringVar(value="")
        ttk.Label(ctrl, textvariable=self.status_var, foreground=_DIM_FG).pack(
            side=tk.LEFT, padx=12
        )

        # ── 2 × 2 translation grid ────────────────────────────────────
        grid_frame = ttk.Frame(outer)
        grid_frame.pack(fill=tk.BOTH, expand=True)
        grid_frame.columnconfigure(0, weight=1, uniform="col")
        grid_frame.columnconfigure(1, weight=1, uniform="col")

        self._out_widgets: dict[str, tk.Text] = {}
        for idx, (lang_name, _) in enumerate(LANGUAGES):
            self._build_output_panel(
                grid_frame, lang_name, bold, mono,
                row=idx // 2, col=idx % 2,
            )

    def _build_output_panel(
        self, parent: ttk.Frame, lang_name: str, bold, mono, row: int, col: int
    ) -> None:
        wrapper = ttk.LabelFrame(parent, text=f"  {lang_name}  ", padding=(8, 6), style="Bold.TLabelframe")
        wrapper.grid(row=row, column=col, sticky="nsew", padx=4, pady=4)
        wrapper.columnconfigure(0, weight=1)
        wrapper.rowconfigure(0, weight=1)

        tw = tk.Text(
            wrapper,
            height=OUT_HEIGHT,
            font=mono,
            wrap=tk.WORD,
            state=tk.DISABLED,
            relief=tk.FLAT,
            bd=0,
            padx=6,
            pady=6,
            background=_CTRL_BG,
            foreground=_TEXT_FG,
            highlightthickness=2,
            highlightbackground="#FFD700",
            highlightcolor="#FFD700",
        )
        sb = ttk.Scrollbar(wrapper, orient=tk.VERTICAL, command=tw.yview)
        tw.configure(yscrollcommand=sb.set)
        sb.grid(row=0, column=1, sticky="ns")
        tw.grid(row=0, column=0, sticky="nsew")

        ttk.Button(
            wrapper,
            text="⧉  Copy",
            command=lambda w=tw: self._copy(w),
        ).grid(row=1, column=0, columnspan=2, sticky="e", pady=(6, 0))

        self._out_widgets[lang_name] = tw

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------
    def _on_input(self, _event=None) -> None:
        self._enforce_limit()
        self._update_counter()
        self._schedule_translate()

    def _enforce_limit(self) -> None:
        content = self.en_text.get("1.0", tk.END)
        if len(content) - 1 > MAX_CHARS:
            self.en_text.delete("1.0", tk.END)
            self.en_text.insert("1.0", content[:MAX_CHARS])
            self.en_text.mark_set(tk.INSERT, tk.END)

    def _update_counter(self) -> None:
        n = len(self.en_text.get("1.0", tk.END).rstrip("\n"))
        self.char_var.set(f"{n} / {MAX_CHARS}")
        self.char_label.configure(foreground=_ERR_FG if n >= MAX_CHARS else _DIM_FG)

    def _schedule_translate(self) -> None:
        if self._debounce_id:
            self.root.after_cancel(self._debounce_id)
        self._debounce_id = self.root.after(DEBOUNCE_MS, self._trigger_translate)

    def _trigger_translate(self) -> None:
        text = self.en_text.get("1.0", tk.END).strip()
        if not text or text == self._last_translated:
            return
        self._last_translated = text
        self.status_var.set("Translating…")
        self.trans_btn.configure(state=tk.DISABLED)
        threading.Thread(
            target=self._translate_worker, args=(text,), daemon=True
        ).start()

    # ------------------------------------------------------------------
    # Translation (background thread)
    # ------------------------------------------------------------------
    def _translate_worker(self, text: str) -> None:
        results: dict[str, str] = {}
        for lang_name, code in LANGUAGES:
            try:
                if code == "zh-CN":
                    zh = GoogleTranslator(source="en", target="zh-CN").translate(text)
                    results[lang_name] = " ".join(
                        p.strip() for p in lazy_pinyin(zh, style=Style.TONE)
                    )
                else:
                    results[lang_name] = (
                        GoogleTranslator(source="en", target=code).translate(text) or ""
                    )
            except Exception as exc:  # noqa: BLE001
                results[lang_name] = f"[Error: {exc}]"
            results[lang_name] = re.sub(r"[^\S\n]{2,}", " ", results[lang_name])
        self.root.after(0, self._apply_results, results)

    def _apply_results(self, results: dict[str, str]) -> None:
        for lang_name, translated in results.items():
            tw = self._out_widgets[lang_name]
            tw.configure(state=tk.NORMAL)
            tw.delete("1.0", tk.END)
            tw.insert("1.0", translated)
            tw.configure(state=tk.DISABLED)
        self.status_var.set("Done ✓")
        self.root.after(2500, lambda: self.status_var.set(""))
        self.trans_btn.configure(state=tk.NORMAL)

    # ------------------------------------------------------------------
    # Font zoom  (Cmd++  /  Cmd+-)
    # ------------------------------------------------------------------
    def _bind_zoom_keys(self) -> None:
        # Cmd+= fires on the unshifted key; Cmd+shift+= (i.e. Cmd++) fires both.
        self.root.bind_all("<Command-equal>", lambda e: self._zoom(+1))
        self.root.bind_all("<Command-plus>",  lambda e: self._zoom(+1))
        self.root.bind_all("<Command-minus>", lambda e: self._zoom(-1))

    def _zoom(self, direction: int) -> None:
        new_level = self._zoom_level + direction
        if new_level < 0 or new_level > MAX_ZOOM:
            return
        self._zoom_level = new_level
        new_size = BASE_FONT_SZ + self._zoom_level * FONT_STEP
        self._bold_font.configure(size=new_size)
        self._mono_font.configure(size=new_size)
        _save_prefs({"zoom_level": self._zoom_level})


    def _copy(self, tw: tk.Text) -> None:
        content = tw.get("1.0", tk.END).strip()
        if not content:
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(content)
        self.status_var.set("Copied to clipboard ✓")
        self.root.after(2000, lambda: self.status_var.set(""))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    _macos_rename_app("Wisdom Translator")   # must run before tk.Tk()
    root = tk.Tk()
    root.minsize(760, 560)
    WisdomTranslator(root)
    root.mainloop()


if __name__ == "__main__":
    main()
