"""System task sources through EDS. No GOA tokens/passwords are read or copied."""
from datetime import datetime, timezone
import threading
from uuid import uuid4

from icalendar import Component, Todo

from task_model import UserError, component_info, key, required_text


def load_eds():
    try:
        import gi
        gi.require_version("EDataServer", "1.2")
        gi.require_version("ECal", "2.0")
        gi.require_version("ICalGLib", "3.0")
        from gi.repository import EDataServer, ECal, ICalGLib, Gio
        return EDataServer, ECal, ICalGLib, Gio
    except (ImportError, ValueError) as exc:
        raise UserError("Evolution support needs PyGObject and the EDataServer, ECal and ICalGLib introspection libraries.") from exc


class EvolutionProvider:
    def __init__(self, source):
        self.source = source
        self.EDS, self.ECal, self.ICal, self.Gio = load_eds()
        self.registry = self.timed(lambda cancel: self.EDS.SourceRegistry.new_sync(cancel))

    def timed(self, operation):
        """Bound individual D-Bus operations even if a backend is unavailable."""
        cancel = self.Gio.Cancellable.new()
        timer = threading.Timer(25, cancel.cancel)
        timer.daemon = True
        timer.start()
        try:
            return operation(cancel)
        finally:
            timer.cancel()

    def discover(self):
        result = []
        for source in self.registry.list_sources(self.EDS.SOURCE_EXTENSION_TASK_LIST):
            if not self.registry.check_enabled(source):
                continue
            collection = self.registry.find_extension(source, self.EDS.SOURCE_EXTENSION_COLLECTION)
            account = collection.get_display_name() if collection else "On this computer"
            name = source.get_display_name()
            info = {"id": key(self.source["id"], "eds", source.get_uid()),
                    "sourceId": self.source["id"], "name": account + " / " + name,
                    "accountName": account, "listName": name, "provider": "evolution",
                    "taskOnly": True, "readOnly": True, "canRename": False, "canDelete": False}
            result.append((source, info))
        return sorted(result, key=lambda pair: pair[1]["name"].casefold())

    def connect(self, source):
        # EDS uses guint32(-1) to skip waiting for remote authentication. Use its
        # cache immediately; EDS owns connection/reconnection and background sync.
        client = self.timed(lambda cancel: self.ECal.Client.connect_sync(
            source, self.ECal.ClientSourceType.TASKS, 0xFFFFFFFF, cancel))
        if client is None:
            raise UserError("EDS could not open this task list.")
        return client

    def objects(self, client):
        ok, objects = self.timed(lambda cancel: client.get_object_list_sync("#t", cancel))
        if not ok:
            raise UserError("EDS could not read this task list.")
        return [(obj, Component.from_ical(obj.as_ical_string())) for obj in objects]

    def snapshot(self):
        lists, todos, errors, failed = [], [], [], []
        for source, info in self.discover():
            lists.append(info)
            try:
                client = self.connect(source)
                info["readOnly"] = client.is_readonly()
                info["online"] = client.is_online()
                items = [component_info(self.source, info, component) for _, component in self.objects(client)]
                todos.extend(item for item in items if item)
            except Exception as exc:
                info["readOnly"] = True
                failed.append(info["id"])
                errors.append({"listId": info["id"], "name": info["name"], "error": exc})
        return {"lists": lists, "todos": todos, "errors": errors, "failedLists": failed}

    def mutate(self, request):
        action = request["action"]
        if action in {"create_list", "rename_list", "delete_list"}:
            raise UserError("Manage system account task lists in Evolution. No account/source configuration was changed.")
        if action not in {"add_task", "edit_task", "set_completed", "delete_task"}:
            raise UserError("Unknown operation.")
        match = next((pair for pair in self.discover() if pair[1]["id"] == request.get("listId")), None)
        if match is None:
            raise UserError("System task list no longer exists or is disabled. Refresh first.")
        source, info = match
        client = self.connect(source)
        if client.is_readonly():
            raise UserError("This system task list is read-only.")
        flags = self.ECal.OperationFlags.CONFLICT_FAIL | self.ECal.OperationFlags.DISABLE_ITIP_MESSAGE
        objects = self.objects(client)

        def find_task(task_id):
            matches = [component for _, component in objects
                       if (component_info(self.source, info, component) or {}).get("id") == task_id]
            if len(matches) != 1:
                raise UserError("Task is missing or ambiguous. Refresh first.")
            return matches[0]

        if action == "add_task":
            component = Todo()
            component.add("uid", str(uuid4()))
            component.add("dtstamp", datetime.now(timezone.utc))
            component.add("summary", required_text(request.get("text")))
            component.add("status", "NEEDS-ACTION")
            if request.get("parentId"):
                parent = find_task(request["parentId"])
                component.add("related-to", str(parent["UID"]), parameters={"RELTYPE": "PARENT"})
            obj = self.ICal.Component.new_from_string(component.to_ical().decode())
            ok, _ = self.timed(lambda cancel: client.create_object_sync(obj, flags, cancel))
        else:
            component = find_task(request.get("id"))
            if component.get("RRULE") or component.get("RDATE"):
                raise UserError("Edit recurring system tasks in Evolution; recurrence-safe writes are not supported yet.")
            if action == "delete_task":
                if request.get("confirm") is not True:
                    raise UserError("Confirm task deletion first.")
                ok = self.timed(lambda cancel: client.remove_object_sync(
                    str(component["UID"]), None, self.ECal.ObjModType.THIS, flags, cancel))
            else:
                if action == "edit_task":
                    component["SUMMARY"] = required_text(request.get("text"))
                else:
                    completed = bool(request.get("completed"))
                    component["STATUS"] = "COMPLETED" if completed else "NEEDS-ACTION"
                    component["PERCENT-COMPLETE"] = 100 if completed else 0
                    component.pop("COMPLETED", None)
                    if completed:
                        component.add("completed", datetime.now(timezone.utc))
                component.pop("LAST-MODIFIED", None)
                component.add("last-modified", datetime.now(timezone.utc))
                obj = self.ICal.Component.new_from_string(component.to_ical().decode())
                ok = self.timed(lambda cancel: client.modify_object_sync(
                    obj, self.ECal.ObjModType.THIS, flags, cancel))
        if not ok:
            raise UserError("EDS did not accept the task change.")
        return {"changed": True}
