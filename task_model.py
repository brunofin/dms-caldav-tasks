"""Provider-neutral task identities, validation and iCalendar mapping."""
import hashlib
import json


class UserError(ValueError):
    pass


def key(*parts):
    return hashlib.sha256(json.dumps(parts).encode()).hexdigest()[:24]


def required_text(value):
    text = str(value or "").strip()
    if not text or len(text) > 2000:
        raise UserError("Enter a name between 1 and 2000 characters.")
    return text


def component_info(source, info, component):
    if component.name != "VTODO" or component.get("RECURRENCE-ID"):
        return None
    uid = str(component.get("UID", ""))
    if not uid:
        return None
    relationships = component.get("RELATED-TO", [])
    if not isinstance(relationships, list):
        relationships = [relationships]
    parent = next((str(r) for r in relationships if r.params.get("RELTYPE", "PARENT") == "PARENT"), None)
    due = component.get("DUE")
    return {"id": key(info["id"], uid), "uid": uid, "sourceId": source["id"],
            "listId": info["id"], "text": str(component.get("SUMMARY", "(Untitled)")),
            "completed": str(component.get("STATUS", "")) == "COMPLETED",
            "parentId": key(info["id"], parent) if parent else None,
            "due": due.dt.isoformat() if due else "", "recurring": bool(component.get("RRULE"))}
