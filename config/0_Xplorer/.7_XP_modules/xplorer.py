import sys
import os
import importlib
import shutil
from pathlib import Path

HOME_DIR = Path.home()

MODULES_PATH = HOME_DIR / "printer_data/config/0_Xplorer/.7_XP_modules"
EXTRAS_PATH = HOME_DIR / "klipper/klippy/extras"

if str(MODULES_PATH) not in sys.path:
    sys.path.insert(0, str(MODULES_PATH))

class XplorerMain:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.config = config
        self.modules_copied = []
        self.modules_loaded = []
        self.modules_failed = []
        self.modules_skipped = []
        self.copy_modules()
        self.load_external_modules()
        self.print_summary()

    def log_info(self, message):
        try:
            gcode = self.printer.lookup_object('gcode')
            gcode.respond_info(message)
        except Exception:
            pass  # fallback if gcode object not ready

    def copy_modules(self):
        for filename in os.listdir(MODULES_PATH):
            if not filename.endswith(".py"):
                continue
            if filename.startswith("_"):
                continue  # Skip helpers
            src = os.path.join(MODULES_PATH, filename)
            dst = os.path.join(EXTRAS_PATH, filename)
            try:
                if not os.path.exists(dst):
                    shutil.copyfile(src, dst)
                    self.log_info(f"[xplorer] Copied {filename} into klippy/extras/")
                    self.modules_copied.append(filename)
                else:
                    src_mtime = os.path.getmtime(src)
                    dst_mtime = os.path.getmtime(dst)
                    if src_mtime > dst_mtime:
                        shutil.copyfile(src, dst)
                        self.log_info(f"[xplorer] Updated {filename} (newer source)")
                        self.modules_copied.append(filename)
                    else:
                        self.modules_skipped.append(filename)
            except Exception as e:
                self.log_info(f"[xplorer] Failed to copy {filename}: {e}")

    def load_external_modules(self):
        for filename in os.listdir(MODULES_PATH):
            if not filename.endswith(".py") or filename.startswith("_"):
                continue
            module_name = filename[:-3]  # Remove ".py"
            try:
                module = importlib.import_module(module_name)
                if hasattr(module, 'init'):
                    self.log_info(f"[xplorer] Loading module: {module_name}")
                    module.init(self.printer, self.config)
                    self.modules_loaded.append(module_name)
                else:
                    self.log_info(f"[xplorer] Skipping {module_name} (no init function)")
            except Exception as e:
                self.log_info(f"[xplorer] Failed to load {module_name}: {e}")
                self.modules_failed.append(module_name)

    def print_summary(self):
        summary = []

        if self.modules_copied:
            summary.append(f"Copied or updated: {', '.join(self.modules_copied)}")
        if self.modules_skipped:
            summary.append(f"Skipped (up-to-date): {', '.join(self.modules_skipped)}")
        if self.modules_loaded:
            summary.append(f"Loaded successfully: {', '.join(self.modules_loaded)}")
        if self.modules_failed:
            summary.append(f"Failed to load: {', '.join(self.modules_failed)}")

        if summary:
            full_message = "[xplorer boot summary]\n" + "\n".join(summary)
            self.log_info(full_message)

def load_config(config):
    return XplorerMain(config)

