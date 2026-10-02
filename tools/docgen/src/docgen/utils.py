from typing import Any


def ok(**fields: Any) -> dict[str, Any]:
    return {"ok": True, **fields}


def err(message: str, **fields: Any) -> dict[str, Any]:
    return {"ok": False, "error": message, **fields}
