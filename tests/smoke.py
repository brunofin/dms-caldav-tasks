"""Load installed DMS components without opening windows, using disposable XDG dirs."""
import os
import json
from pathlib import Path
import subprocess
import shutil
import tempfile

project = Path(__file__).resolve().parents[1]
dms = Path(os.environ.get("DMS_QML_ROOT", "/usr/share/quickshell/dms"))
test_tmp = os.environ.get("CALDAV_TASKS_TEST_TMPDIR", "/tmp/opencode" if Path("/tmp/opencode").is_dir() else tempfile.gettempdir())
with tempfile.TemporaryDirectory(prefix="caldav-qml-", dir=test_tmp) as directory:
    root = Path(directory)
    shell = root / "shell"
    shell.mkdir()
    shutil.copyfile(project / "tests/smoke.qml", shell / "shell.qml")
    for entry in dms.iterdir():
        if entry.is_dir():
            (shell / entry.name).symlink_to(entry)
    for name in ("home", "config", "state", "cache", "data", "runtime"):
        (root / name).mkdir(mode=0o700)
    (root / "state/DankMaterialShell").mkdir()
    (root / "state/DankMaterialShell/session.json").write_text(json.dumps({"isLightMode": True}))
    (root / "config/DankMaterialShell").mkdir()
    (root / "config/DankMaterialShell/settings.json").write_text(json.dumps({
        "syncModeWithPortal": False, "runDmsMatugenTemplates": False,
        "runUserMatugenTemplates": False}))
    # Temporary XDG config alone is NOT isolation: matugen can still contact the
    # live DMS daemon and GSettings can write to the real user's D-Bus session.
    display = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    if not os.path.isabs(display):
        display = str(Path(os.environ["XDG_RUNTIME_DIR"]) / display)
    env = {key: value for key, value in os.environ.items() if not key.startswith("DMS_")}
    env.update({"QT_QPA_PLATFORM": "wayland", "CALDAV_TASKS_PROJECT": str(project),
                "HOME": str(root / "home"), "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_STATE_HOME": str(root / "state"), "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_DATA_HOME": str(root / "data"), "XDG_RUNTIME_DIR": str(root / "runtime"),
                "WAYLAND_DISPLAY": display, "GSETTINGS_BACKEND": "memory",
                "QT_NO_XDG_DESKTOP_PORTAL": "1", "GTK_USE_PORTAL": "0", "NO_AT_BRIDGE": "1",
                "DMS_DISABLE_MATUGEN": "1", "DMS_DISABLE_AUTO_START": "1"})
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)

    def desktop_theme():
        return tuple(subprocess.check_output(command, text=True, timeout=5).strip() for command in (
            ["dms", "ipc", "call", "theme", "getMode"],
            ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]))

    before_theme = desktop_theme()
    result = subprocess.run(["dbus-run-session", "--", "qs", "--no-color", "-p", str(shell)], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    print(result.stdout)
    if desktop_theme() != before_theme:
        raise SystemExit("Preview unexpectedly changed the desktop theme")
    if (result.returncode or "SMOKE FAILURE" in result.stdout or "SMOKE UI CREATED" not in result.stdout
            or "SMOKE BACKEND READY: true" not in result.stdout
            or any(error in result.stdout for error in ("TypeError:", "ReferenceError:", "Binding loop", "Invalid property assignment"))):
        raise SystemExit(1)
