import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend
from evolution_provider import load_eds

TEST_TMP = os.environ.get("CALDAV_TASKS_TEST_TMPDIR", "/tmp/opencode" if Path("/tmp/opencode").is_dir() else tempfile.gettempdir())


def eds_available():
    try:
        load_eds()
        return True
    except backend.UserError:
        return False


class EvolutionConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEST_TMP, prefix="eds-config-")
        self.env = patch.dict(os.environ, XDG_CONFIG_HOME=self.temp.name)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def test_provider_needs_no_credentials_and_drops_supplied_secrets(self):
        result = backend.dispatch({"action": "save_source", "source": {
            "provider": "evolution", "name": "System accounts", "password": "never-store",
            "url": "ignore", "username": "ignore"}})
        self.assertEqual(result["sources"][0]["provider"], "evolution")
        self.assertFalse(result["sources"][0]["canCreateLists"])
        self.assertNotIn("never-store", backend.config_path().read_text())
        self.assertNotIn("url", backend.read_sources()[0])

    def test_duplicate_system_provider_is_rejected_but_edit_is_allowed(self):
        source = {"provider": "evolution", "name": "System"}
        result = backend.dispatch({"action": "save_source", "source": source})
        with self.assertRaises(backend.UserError):
            backend.dispatch({"action": "save_source", "source": source})
        backend.dispatch({"action": "save_source", "source": result["sources"][0] | {"name": "Renamed"}})
        self.assertEqual(backend.read_sources()[0]["name"], "Renamed")

    def test_provider_change_and_unknown_provider_rejected(self):
        result = backend.dispatch({"action": "save_source", "source": {"provider": "evolution", "name": "System"}})
        with self.assertRaises(backend.UserError):
            backend.dispatch({"action": "save_source", "source": result["sources"][0] | {"provider": "caldav"}})
        with self.assertRaises(backend.UserError):
            backend.dispatch({"action": "save_source", "source": {"provider": "other", "name": "No"}})

    def test_disconnect_does_not_touch_system_accounts(self):
        result = backend.dispatch({"action": "save_source", "source": {"provider": "evolution", "name": "System"}})
        with patch.dict(sys.modules, {"evolution_provider": None}):
            backend.dispatch({"action": "remove_source", "sourceId": result["sources"][0]["id"]})
        self.assertEqual(backend.read_sources(), [])

    def test_partial_failure_is_redacted_and_other_lists_are_retained(self):
        result = backend.dispatch({"action": "save_source", "source": {"provider": "evolution", "name": "System"}})
        sid = result["sources"][0]["id"]
        with patch("evolution_provider.EvolutionProvider") as provider:
            provider.return_value.snapshot.return_value = {
                "lists": [{"id": "bad", "sourceId": sid}, {"id": "good", "sourceId": sid}],
                "todos": [], "failedLists": ["bad"],
                "errors": [{"listId": "bad", "name": "Unavailable", "error": RuntimeError("secret-token")}]}
            state = backend.dispatch({"action": "sync"})
        self.assertEqual(state["failedLists"], ["bad"])
        self.assertEqual(state["successfulSources"], [sid])
        self.assertEqual(len(state["lists"]), 2)
        self.assertNotIn("secret-token", json.dumps(state))


@unittest.skipUnless(eds_available() and shutil.which("dbus-run-session"),
                     "Requires EDS introspection and dbus-run-session")
class EvolutionIntegrationTests(unittest.TestCase):
    def test_real_eds_in_disposable_session(self):
        # The private bus is essential: changing XDG dirs alone does not isolate EDS.
        with tempfile.TemporaryDirectory(dir=TEST_TMP, prefix="eds-integration-") as directory:
            root = Path(directory)
            (root / "isolated-test-marker").touch()
            env = os.environ | {
                "HOME": directory, "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_STATE_HOME": str(root / "state"), "EDS_TEST_ISOLATED": "1",
                "GSETTINGS_BACKEND": "memory", "NO_AT_BRIDGE": "1"}
            env.pop("DBUS_SESSION_BUS_ADDRESS", None)
            process = subprocess.Popen(["dbus-run-session", "--", sys.executable,
                                        str(Path(__file__).with_name("worker_eds.py"))],
                                       env=env, text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                output, _ = process.communicate(timeout=55)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                output, _ = process.communicate(timeout=10)
                self.fail("Isolated EDS test timed out:\n" + output)
            self.assertEqual(process.returncode, 0, output)
            self.assertIn("EDS CRUD PASS", output)


if __name__ == "__main__":
    unittest.main()
