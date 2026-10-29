from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import caldav
from icalendar import Event

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, XDG_CONFIG_HOME=self.temp.name)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def source(self, **overrides):
        return dict(name="Personal", url="https://dav.example/", username="test",
                    password="secret", **overrides)

    def test_private_config_and_redacted_settings(self):
        result = backend.dispatch({"action": "save_source", "source": self.source()})
        self.assertNotIn("secret", json.dumps(result))
        self.assertEqual(backend.config_path().stat().st_mode & 0o777, 0o600)
        source = result["sources"][0]
        backend.dispatch({"action": "save_source", "source": source | {"password": ""}})
        self.assertEqual(backend.read_sources()[0]["password"], "secret")

    def test_reject_insecure_and_embedded_credentials(self):
        for url in ("http://dav.example/", "https://user:secret@dav.example/", "https://dav.example/?token=secret"):
            with self.subTest(url=url), self.assertRaises(backend.UserError):
                backend.dispatch({"action": "save_source", "source": self.source() | {"url": url}})

    def test_disconnect_does_not_connect_to_server(self):
        data = backend.dispatch({"action": "save_source", "source": self.source()})
        with patch.object(backend, "connect", side_effect=AssertionError("No network allowed")):
            backend.dispatch({"action": "remove_source", "sourceId": data["sources"][0]["id"]})
        self.assertEqual(backend.read_sources(), [])

    def test_tree_cycles_and_orphans(self):
        tasks = [{"id": "a", "parentId": "b"}, {"id": "b", "parentId": "a"},
                 {"id": "c", "parentId": "missing"}]
        result = backend.tree_order(tasks)
        self.assertEqual(len(result), 3)
        seen = set()
        for task in result:
            self.assertTrue(task["parentId"] is None or task["parentId"] in seen)
            seen.add(task["id"])

    def test_event_is_never_a_task(self):
        class Resource:
            def get_icalendar_component(self):
                return Event()
        self.assertIsNone(backend.task_info({}, {}, Resource()))

    def test_subtrees_are_contiguous(self):
        tasks = [{"id": "a", "parentId": None}, {"id": "b", "parentId": None},
                 {"id": "c", "parentId": "a"}, {"id": "d", "parentId": "c"}]
        self.assertEqual([t["id"] for t in backend.tree_order(tasks)], ["a", "c", "d", "b"])

    def test_errors_do_not_leak_secrets(self):
        message = backend.safe_error(RuntimeError("password=secret https://user:secret@example"))
        self.assertNotIn("secret", message)

    def test_protocol_no_sources(self):
        process = subprocess.run([sys.executable, str(Path(backend.__file__))], input='{"action":"sync"}\n',
                                 text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(process.stdout)["data"]["todos"], [])


@unittest.skipUnless(importlib.util.find_spec("radicale"), "Install radicale to run real DAV integration tests")
class RadicaleTests(unittest.TestCase):
    """Disposable localhost server. No access to real credentials or user collections."""

    def setUp(self):
        ConfigTests.setUp(self)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        config = Path(self.temp.name) / "radicale.conf"
        config.write_text(f"""[server]
hosts = 127.0.0.1:{self.port}
[auth]
type = none
[rights]
type = owner_only
[storage]
filesystem_folder = {self.temp.name}/collections
[logging]
level = critical
""")
        self.server = subprocess.Popen([sys.executable, "-m", "radicale", "--config", str(config)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for attempt in range(100):
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    break
            except OSError:
                if self.server.poll() is not None:
                    self.fail("Radicale failed to start")
                time.sleep(0.05)
        else:
            self.fail("Radicale did not become ready")
        self.connector = patch.object(backend, "connect", self.connect_local)
        self.connector.start()
        backend.write_sources([
            {"id": "personal", "name": "Personal", "url": f"http://127.0.0.1:{self.port}/",
             "username": "alice", "password": "test", "enabled": True},
            {"id": "work", "name": "Work", "url": f"http://127.0.0.1:{self.port}/",
             "username": "bob", "password": "test", "enabled": True}])

    def connect_local(self, source):
        return caldav.DAVClient(url=source["url"], username=source["username"],
                                password=source["password"], require_tls=False, timeout=3)

    def tearDown(self):
        self.connector.stop()
        self.server.terminate()
        self.server.wait(timeout=10)
        ConfigTests.tearDown(self)

    def call(self, action, **fields):
        return backend.dispatch(dict(action=action, sourceId="personal", **fields))

    def test_crud_two_sources_and_list_lifecycle(self):
        self.call("create_list", text="Inbox")
        backend.dispatch({"action": "create_list", "sourceId": "work", "text": "Work tasks"})
        state = self.call("sync")
        self.assertEqual(state["errors"], [])
        self.assertEqual(len(state["lists"]), 2)
        personal = next(l for l in state["lists"] if l["sourceId"] == "personal")
        self.assertTrue(personal["taskOnly"])
        lid = personal["id"]
        self.call("add_task", listId=lid, text="Parent")
        task = self.call("sync")["todos"][0]
        self.call("add_task", listId=lid, text="Child", parentId=task["id"])
        state = self.call("sync")
        child = next(t for t in state["todos"] if t["text"] == "Child")
        self.assertEqual(child["parentId"], task["id"])
        self.call("edit_task", listId=lid, id=task["id"], text="Edited")
        self.assertEqual(self.call("sync")["todos"][0]["text"], "Edited")
        self.call("set_completed", listId=lid, id=task["id"], completed=True)
        self.assertTrue(self.call("sync")["todos"][0]["completed"])
        self.call("set_completed", listId=lid, id=task["id"], completed=False)
        self.assertFalse(self.call("sync")["todos"][0]["completed"])
        with self.assertRaises(backend.UserError):
            self.call("delete_task", listId=lid, id=task["id"])
        self.call("delete_task", listId=lid, id=task["id"], confirm=True)
        remaining = self.call("sync")["todos"]
        self.assertEqual(len(remaining), 1)
        self.assertIsNone(remaining[0]["parentId"])
        self.call("rename_list", listId=lid, text="Renamed")
        self.assertEqual(next(l for l in self.call("sync")["lists"] if l["id"] == lid)["name"], "Renamed")
        with self.assertRaises(backend.UserError):
            self.call("delete_list", listId=lid, confirm="wrong")
        self.call("delete_list", listId=lid, confirm="Renamed")
        self.assertEqual(len(self.call("sync")["lists"]), 1)

    def test_events_hidden_and_mixed_collection_deletion_blocked(self):
        source = backend.read_sources()[0]
        with self.connect_local(source) as client:
            principal = client.principal()
            events = principal.make_calendar(name="Events", supported_calendar_component_set=["VEVENT"])
            events.save_event(summary="Never show me", dtstart=datetime(2027, 1, 1, tzinfo=timezone.utc))
            mixed = principal.make_calendar(name="Mixed", supported_calendar_component_set=["VEVENT", "VTODO"])
            mixed.save_event(summary="Keep this event", dtstart=datetime(2027, 1, 1, tzinfo=timezone.utc))
            mixed.save_todo(summary="Visible task", description="Preserve description", due=__import__('datetime').date(2027, 1, 1))
            state = self.call("sync")
            self.assertEqual(len(state["lists"]), 1)
            self.assertEqual([t["text"] for t in state["todos"]], ["Visible task"])
            info = state["lists"][0]
            task = state["todos"][0]
            with self.assertRaises(backend.UserError):
                self.call("delete_list", listId=info["id"], confirm="Mixed")
            self.call("edit_task", listId=info["id"], id=task["id"], text="Updated")
            component = mixed.search(todo=True, include_completed=True)[0].get_icalendar_component()
            self.assertEqual(str(component["DESCRIPTION"]), "Preserve description")
            self.assertEqual(component["DUE"].dt.isoformat(), "2027-01-01")
            self.assertEqual(len(mixed.search(event=True)), 1)

    def test_failure_of_one_source_does_not_hide_other(self):
        self.call("create_list", text="Still works")
        original = self.connect_local
        def connect(source):
            if source["id"] == "work":
                raise RuntimeError("secret")
            return original(source)
        with patch.object(backend, "connect", connect):
            state = self.call("sync")
        self.assertEqual(state["successfulSources"], ["personal"])
        self.assertEqual(len(state["lists"]), 1)
        self.assertNotIn("secret", json.dumps(state))


if __name__ == "__main__":
    unittest.main()
