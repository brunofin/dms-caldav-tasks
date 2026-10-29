"""Real EDS CRUD worker. ONLY run inside the test launcher's private D-Bus session."""
from datetime import date
import os
import faulthandler
from pathlib import Path
import sys
import time
from unittest.mock import patch

if os.environ.get("EDS_TEST_ISOLATED") != "1" or not Path(os.environ["HOME"], "isolated-test-marker").exists():
    raise SystemExit("Refusing to run EDS write tests outside the disposable test environment")
faulthandler.dump_traceback_later(15, repeat=True)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend
from evolution_provider import EvolutionProvider
from task_model import UserError

source = {"id": "system-test", "provider": "evolution", "name": "Test system", "enabled": True}
backend.write_sources([source])
print("EDS test: opening private registry", flush=True)
provider = EvolutionProvider(source)
EDS = provider.EDS
assert not provider.registry.list_sources(EDS.SOURCE_EXTENSION_COLLECTION), "Real accounts must never be present"
for default in provider.registry.list_sources(EDS.SOURCE_EXTENSION_TASK_LIST):
    default.set_enabled(False)
    assert default.write_sync(None)


def create_source(name, extension):
    item = EDS.Source.new(None, None)
    item.set_display_name(name)
    item.set_parent("local-stub")
    item.get_extension(extension).set_backend_name("local")
    assert provider.registry.commit_source_sync(item, None)
    from gi.repository import GLib
    context = GLib.MainContext.default()
    deadline = time.monotonic() + 5
    while provider.registry.ref_source(item.get_uid()) is None and time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        time.sleep(0.01)
    return provider.registry.ref_source(item.get_uid())


local = create_source("Isolated tasks", EDS.SOURCE_EXTENSION_TASK_LIST)
print("EDS test: created local task source", flush=True)
assert local is not None
events = create_source("Not tasks", EDS.SOURCE_EXTENSION_CALENDAR)
assert events is not None
other = create_source("Other isolated tasks", EDS.SOURCE_EXTENSION_TASK_LIST)
assert other is not None
info = next(info for item, info in provider.discover() if item.get_uid() == local.get_uid())
lid = info["id"]
assert all("Not tasks" not in item[1]["name"] for item in provider.discover())


def call(action, **fields):
    return backend.dispatch({"action": action, "sourceId": source["id"], "listId": lid, **fields})


def todos():
    state = call("sync")
    assert not state["errors"], state["errors"]
    return [task for task in state["todos"] if task["listId"] == lid]


assert call("add_task", text="Parent")["changed"]
print("EDS test: created task", flush=True)
parent = todos()[0]
print("EDS test: read task", flush=True)
assert call("add_task", text="Child", parentId=parent["id"])["changed"]
child = next(t for t in todos() if t["text"] == "Child")
print("EDS test: read subtask", flush=True)
assert child["parentId"] == parent["id"]

# Seed metadata through the real EDS API, then verify component-level title editing.
client = provider.connect(local)
obj, component = next(pair for pair in provider.objects(client) if str(pair[1]["UID"]) == parent["uid"])
component.add("description", "Must survive")
component.add("due", date(2027, 1, 1))
component.add("x-test-extra", "Preserved custom property")
obj = provider.ICal.Component.new_from_string(component.to_ical().decode())
assert client.modify_object_sync(obj, provider.ECal.ObjModType.THIS, provider.ECal.OperationFlags.CONFLICT_FAIL, None)
assert call("edit_task", id=parent["id"], text="Edited")["changed"]
_, edited = next(pair for pair in provider.objects(client) if str(pair[1]["UID"]) == parent["uid"])
assert str(edited["SUMMARY"]) == "Edited"
assert str(edited["DESCRIPTION"]) == "Must survive"
assert str(edited["X-TEST-EXTRA"]) == "Preserved custom property"
assert edited["DUE"].dt == date(2027, 1, 1)

assert call("set_completed", id=parent["id"], completed=True)["changed"]
assert next(t for t in todos() if t["id"] == parent["id"])["completed"]
assert call("set_completed", id=parent["id"], completed=False)["changed"]
assert not next(t for t in todos() if t["id"] == parent["id"])["completed"]

for action in ("create_list", "rename_list", "delete_list"):
    try:
        call(action, text="Do not change sources", confirm=info["name"])
        raise AssertionError("System list mutation must be blocked")
    except UserError:
        pass

try:
    call("delete_task", id=parent["id"])
    raise AssertionError("Deletion must need confirmation")
except UserError:
    pass
assert call("delete_task", id=parent["id"], confirm=True)["changed"]
remaining = todos()
assert len(remaining) == 1 and remaining[0]["id"] == child["id"]
assert remaining[0]["parentId"] is None

# A failed source must not prevent other EDS lists from being loaded.
original_connect = provider.connect
def fail_one(item):
    if item.get_uid() == local.get_uid():
        raise RuntimeError("private connection details")
    return original_connect(item)
with patch.object(provider, "connect", side_effect=fail_one):
    state = provider.snapshot()
assert lid in state["failedLists"]
assert any(item["id"] != lid for item in state["lists"])

# Check write protection at the backend, not just disabled UI buttons.
class ReadOnlyClient:
    def is_readonly(self):
        return True
with patch.object(provider, "connect", return_value=ReadOnlyClient()):
    try:
        provider.mutate({"action": "add_task", "listId": lid, "text": "Forbidden"})
        raise AssertionError("Read-only source must reject writes")
    except UserError:
        pass

print("EDS CRUD PASS", flush=True)
