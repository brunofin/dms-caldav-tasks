#!/usr/bin/env python3
"""One JSON request on stdin, one JSON response on stdout. Never log secrets."""
from __future__ import annotations

import contextlib
import json
import logging
import os
from pathlib import Path
import sys
import tempfile
from uuid import uuid4
from urllib.parse import urlparse

import caldav
from caldav.elements import dav
from task_model import UserError, component_info, key, required_text


def config_path():
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dms-caldav-tasks" / "connections.json"


def read_sources():
    try:
        return json.loads(config_path().read_text())["sources"]
    except FileNotFoundError:
        return []


def write_sources(sources):
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump({"version": 1, "sources": sources}, stream, indent=2)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def public_source(source):
    provider = source.get("provider", "caldav")
    return {k: v for k, v in source.items() if k != "password"} | {
        "hasPassword": bool(source.get("password")), "provider": provider,
        "canCreateLists": provider == "caldav"}


def connect(source):
    return caldav.DAVClient(url=source["url"], username=source["username"],
                            password=source["password"], timeout=20,
                            ssl_verify_cert=source.get("verifyTLS", True))


def list_info(source, calendar):
    components = calendar.get_supported_components()
    if "VTODO" not in components:
        return None
    url = str(calendar.url)
    return {"id": key(source["id"], url), "sourceId": source["id"],
            "name": str(calendar.get_display_name() or url.rstrip("/").split("/")[-1]),
            "taskOnly": set(components) == {"VTODO"}, "readOnly": False,
            "canRename": True, "canDelete": set(components) == {"VTODO"}}


def task_info(source, info, task):
    return component_info(source, info, task.get_icalendar_component())


def tree_order(tasks):
    """Keep subtrees contiguous; retain orphans and break corrupt parent cycles."""
    by_id = {task["id"]: task for task in tasks}
    for task in tasks:
        if task["parentId"] not in by_id:
            task["parentId"] = None
        seen = {task["id"]}
        parent = by_id.get(task["parentId"])
        while parent:
            if parent["id"] in seen:
                task["parentId"] = None
                break
            seen.add(parent["id"])
            parent = by_id.get(parent["parentId"])
    children = {}
    for task in tasks:
        children.setdefault(task["parentId"], []).append(task)
    stack = list(reversed(children.get(None, [])))
    result = []
    while stack:
        task = stack.pop()
        result.append(task)
        stack.extend(reversed(children.get(task["id"], [])))
    return result


def snapshot(sources):
    lists, tasks, errors, successful, failed_lists = [], [], [], [], []
    for source in sources:
        if not source.get("enabled", True):
            continue
        try:
            if source.get("provider") == "evolution":
                from evolution_provider import EvolutionProvider
                result = EvolutionProvider(source).snapshot()
                lists.extend(result["lists"])
                tasks.extend(tree_order(result["todos"]))
                failed_lists.extend(result["failedLists"])
                errors.extend({"sourceId": source["id"], "listId": item["listId"],
                               "message": item["name"] + ": " + safe_error(item["error"])}
                              for item in result["errors"])
                successful.append(source["id"])
                continue
            source_lists, source_tasks = [], []
            with connect(source) as client:
                for calendar in client.principal().calendars():
                    info = list_info(source, calendar)
                    if info is None:
                        continue
                    source_lists.append(info)
                    for task in calendar.search(todo=True, include_completed=True):
                        item = task_info(source, info, task)
                        if item:
                            source_tasks.append(item)
            lists.extend(source_lists)
            tasks.extend(tree_order(source_tasks))
            successful.append(source["id"])
        except Exception as exc:
            errors.append({"sourceId": source["id"], "message": safe_error(exc)})
    return {"sources": [public_source(s) for s in sources], "lists": lists,
            "todos": tasks, "errors": errors, "successfulSources": successful,
            "failedLists": failed_lists}


def safe_error(exc):
    # DAV exceptions often include request bodies, URLs or authentication data.
    if isinstance(exc, UserError):
        return str(exc)
    return f"{type(exc).__name__}: request failed; check connection, credentials and server permissions."


def dispatch(request):
    action = request.get("action", "sync")
    sources = read_sources()
    if action == "settings":
        return {"sources": [public_source(s) for s in sources]}
    if action == "save_source":
        data = request["source"]
        existing = next((s for s in sources if s["id"] == data.get("id")), None)
        provider = data.get("provider", (existing or {}).get("provider", "caldav"))
        if provider not in {"caldav", "evolution"}:
            raise UserError("Unknown source provider.")
        if existing and provider != existing.get("provider", "caldav"):
            raise UserError("Create a new connection to change provider.")
        if provider == "evolution":
            if any(s.get("provider") == "evolution" and s["id"] != data.get("id") for s in sources):
                raise UserError("System accounts are already connected. Edit that connection instead.")
            source = {"id": existing["id"] if existing else uuid4().hex, "provider": provider,
                      "name": required_text(data.get("name")), "enabled": bool(data.get("enabled", True))}
            write_sources([s for s in sources if s["id"] != source["id"]] + [source])
            return {"sources": [public_source(s) for s in read_sources()]}
        url = str(data.get("url", "")).strip()
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise UserError("Use an HTTPS CalDAV URL without embedded credentials, query or fragment.")
        source = {"id": existing["id"] if existing else uuid4().hex, "provider": provider,
                  "name": required_text(data.get("name")), "url": url.rstrip("/") + "/",
                  "username": required_text(data.get("username")),
                  "password": data.get("password") or (existing or {}).get("password", ""),
                  "verifyTLS": True, "enabled": bool(data.get("enabled", True))}
        if not source["password"]:
            raise UserError("Enter an app password for this connection.")
        write_sources([s for s in sources if s["id"] != source["id"]] + [source])
        return {"sources": [public_source(s) for s in read_sources()]}
    if action == "remove_source":
        write_sources([s for s in sources if s["id"] != request["sourceId"]])
        return {"sources": [public_source(s) for s in read_sources()]}
    if action == "sync":
        return snapshot(sources)
    source = next((s for s in sources if s["id"] == request.get("sourceId") and s.get("enabled", True)), None)
    if not source:
        raise UserError("Choose an enabled connection first.")
    if source.get("provider") == "evolution":
        from evolution_provider import EvolutionProvider
        return EvolutionProvider(source).mutate(request)
    with connect(source) as client:
        principal = client.principal()
        if action == "create_list":
            principal.make_calendar(name=required_text(request.get("text")),
                                    supported_calendar_component_set=["VTODO"])
            return {"changed": True}
        # Resolve opaque IDs through discovery: never accept arbitrary task/calendar URLs.
        calendar, info = None, None
        for candidate in principal.calendars():
            candidate_info = list_info(source, candidate)
            if candidate_info and candidate_info["id"] == request.get("listId"):
                calendar, info = candidate, candidate_info
                break
        if calendar is None:
            raise UserError("Task list no longer exists. Refresh and try again.")
        if action == "rename_list":
            calendar.set_properties([dav.DisplayName(required_text(request.get("text")))])
        elif action == "delete_list":
            if request.get("confirm") != info["name"]:
                raise UserError("Type the list name to confirm deletion.")
            # Mixed collections can contain events/journals; never delete those collections.
            if not info["taskOnly"]:
                raise UserError("Cannot delete a mixed calendar. Only task-only lists may be deleted.")
            calendar.delete(wipe=False)
        elif action == "add_task":
            fields = {"summary": required_text(request.get("text"))}
            if request.get("parentId"):
                parents = calendar.search(todo=True, include_completed=True)
                parent = next((t for t in parents if (task_info(source, info, t) or {}).get("id") == request["parentId"]), None)
                if not parent:
                    raise UserError("Parent task no longer exists.")
                fields["related_to"] = str(parent.get_icalendar_component()["UID"])
            calendar.save_todo(**fields)
        elif action in {"edit_task", "set_completed", "delete_task"}:
            matches = [t for t in calendar.search(todo=True, include_completed=True)
                       if (task_info(source, info, t) or {}).get("id") == request.get("id")]
            if len(matches) != 1:
                raise UserError("Task is missing or has multiple recurrence instances. Refresh first.")
            task = matches[0]
            component = task.get_icalendar_component()
            if action == "edit_task":
                with task.edit_icalendar_component() as editable:
                    editable["SUMMARY"] = required_text(request.get("text"))
                task.save(no_create=True)
            elif action == "set_completed":
                if component.get("RRULE"):
                    raise UserError("Recurring task completion is not supported yet; use your CalDAV app.")
                if request.get("completed"):
                    task.complete()
                else:
                    task.uncomplete()
            else:
                if request.get("confirm") is not True:
                    raise UserError("Confirm task deletion first.")
                task.delete()
        else:
            raise UserError("Unknown operation.")
    return {"changed": True}


def main():
    logging.disable(logging.CRITICAL)
    try:
        request = json.loads(sys.stdin.readline(1024 * 1024))
        # Keep any unexpected library prints out of the JSON protocol.
        with contextlib.redirect_stdout(sys.stderr):
            data = dispatch(request)
        response = {"success": True, "data": data}
    except Exception as exc:
        response = {"success": False, "message": safe_error(exc)}
    print(json.dumps(response), flush=True)


if __name__ == "__main__":
    main()
