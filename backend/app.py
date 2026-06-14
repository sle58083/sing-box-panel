import argparse
import io
import re
from datetime import datetime, timezone
from pathlib import Path

import qrcode
from fastapi import Cookie, Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

from auth import COOKIE_NAME, create_session, get_secret, hash_password, verify_password, verify_session
from db import audit, db, init_db, row_to_dict, utc_now
import singbox


BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

app = FastAPI(title="sing-box-panel", docs_url=None, redoc_url=None)


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class NodeCreate(BaseModel):
    protocol: str
    expire_at: str | None = None

    @field_validator("protocol")
    @classmethod
    def valid_protocol(cls, value: str) -> str:
        return singbox.validate_protocol(value)

    @field_validator("expire_at")
    @classmethod
    def valid_expire(cls, value: str | None) -> str | None:
        return parse_expire(value)


class ExpireUpdate(BaseModel):
    expire_at: str | None = None

    @field_validator("expire_at")
    @classmethod
    def valid_expire(cls, value: str | None) -> str | None:
        return parse_expire(value)


def parse_expire(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    cleaned = value.strip()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?)?Z?", cleaned):
        raise ValueError("expire_at must be ISO-like date/time.")
    normalized = cleaned.rstrip("Z")
    try:
        if "T" in normalized:
            parsed = datetime.fromisoformat(normalized)
        else:
            parsed = datetime.fromisoformat(normalized + "T23:59:59")
    except ValueError as exc:
        raise ValueError("Invalid expire_at.") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def require_user(session: str | None = Cookie(default=None, alias=COOKIE_NAME)) -> str:
    username = verify_session(session)
    if not username:
        raise HTTPException(status_code=401, detail="Not authenticated")
    with db() as conn:
        row = conn.execute("SELECT username FROM users WHERE username = ?", (username,)).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return username


@app.on_event("startup")
def startup() -> None:
    init_db()


@app.exception_handler(ValueError)
async def value_error_handler(request: Request, exc: ValueError) -> JSONResponse:
    return JSONResponse(status_code=400, content={"detail": str(exc)})


@app.post("/api/login")
def login(payload: LoginRequest, response: Response) -> dict:
    with db() as conn:
        row = conn.execute(
            "SELECT username, password_hash FROM users WHERE username = ?",
            (payload.username,),
        ).fetchone()
    if not row or not verify_password(payload.password, row["password_hash"]):
        audit("login_failed", payload.username, "invalid credentials")
        raise HTTPException(status_code=401, detail="Invalid username or password")
    token = create_session(row["username"])
    response.set_cookie(
        COOKIE_NAME,
        token,
        httponly=True,
        secure=False,
        samesite="lax",
        max_age=86400,
        path="/",
    )
    audit("login", row["username"], "success")
    return {"ok": True, "username": row["username"]}


@app.post("/api/logout")
def logout(response: Response, username: str = Depends(require_user)) -> dict:
    response.delete_cookie(COOKIE_NAME, path="/")
    audit("logout", username, "success")
    return {"ok": True}


@app.get("/api/me")
def me(username: str = Depends(require_user)) -> dict:
    return {"username": username}


@app.get("/api/nodes")
def list_nodes(username: str = Depends(require_user)) -> dict:
    with db() as conn:
        rows = conn.execute("SELECT * FROM nodes WHERE enabled = 1 ORDER BY created_at DESC").fetchall()
    return {"nodes": [row_to_dict(row) for row in rows]}


@app.post("/api/nodes")
def create_node(payload: NodeCreate, username: str = Depends(require_user)) -> dict:
    now = utc_now()
    try:
        added = singbox.add_node(payload.protocol)
        name = added["name"]
        url = ""
        try:
            url = singbox.node_url(name)
        except Exception:
            url = ""
        acceleration = singbox.enable_acceleration()
        with db() as conn:
            conn.execute(
                """
                INSERT INTO nodes (name, protocol, config_file, url, expire_at, enabled, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(name) DO UPDATE SET
                    protocol = excluded.protocol,
                    config_file = excluded.config_file,
                    url = excluded.url,
                    expire_at = excluded.expire_at,
                    enabled = 1,
                    updated_at = excluded.updated_at
                """,
                (name, payload.protocol, added["config_file"], url, payload.expire_at, now, now),
            )
        acceleration_status = "ok" if acceleration["ok"] else "failed"
        audit(
            "node_create",
            name,
            f"created by {username}; protocol={payload.protocol}; acceleration={acceleration_status}",
        )
        return {
            "ok": True,
            "node": name,
            "url": url,
            "info": added.get("info", ""),
            "output": added.get("output", ""),
            "acceleration": acceleration,
        }
    except singbox.SingBoxError as exc:
        audit("node_create_failed", payload.protocol, str(exc))
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.delete("/api/nodes/{name}")
def delete_node(name: str, username: str = Depends(require_user)) -> dict:
    name = singbox.validate_node_name(name)
    with db() as conn:
        row = conn.execute("SELECT name FROM nodes WHERE name = ?", (name,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Node not found")
    try:
        singbox.delete_node(name)
    except singbox.SingBoxError as exc:
        audit("node_delete_command_failed", name, str(exc))
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    with db() as conn:
        conn.execute("UPDATE nodes SET enabled = 0, updated_at = ? WHERE name = ?", (utc_now(), name))
    audit("node_delete", name, f"deleted by {username}")
    return {"ok": True}


@app.patch("/api/nodes/{name}/expire")
def update_expire(name: str, payload: ExpireUpdate, username: str = Depends(require_user)) -> dict:
    name = singbox.validate_node_name(name)
    with db() as conn:
        cur = conn.execute(
            "UPDATE nodes SET expire_at = ?, updated_at = ? WHERE name = ?",
            (payload.expire_at, utc_now(), name),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Node not found")
    audit("node_expire_update", name, f"updated by {username}: {payload.expire_at or 'never'}")
    return {"ok": True, "expire_at": payload.expire_at}


@app.get("/api/nodes/{name}/url")
def get_node_url(name: str, username: str = Depends(require_user)) -> dict:
    name = singbox.validate_node_name(name)
    with db() as conn:
        row = conn.execute("SELECT url FROM nodes WHERE name = ?", (name,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Node not found")
    url = row["url"]
    if not url:
        try:
            url = singbox.node_url(name)
            with db() as conn:
                conn.execute("UPDATE nodes SET url = ?, updated_at = ? WHERE name = ?", (url, utc_now(), name))
        except singbox.SingBoxError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"name": name, "url": url}


@app.get("/api/nodes/{name}/qr")
def get_node_qr(name: str, username: str = Depends(require_user)) -> StreamingResponse:
    data = get_node_url(name, username)["url"]
    if not data:
        raise HTTPException(status_code=404, detail="No URL available")
    image = qrcode.make(data)
    stream = io.BytesIO()
    image.save(stream, format="PNG")
    stream.seek(0)
    return StreamingResponse(stream, media_type="image/png")


@app.get("/api/nodes/{name}/info")
def get_node_info(name: str, username: str = Depends(require_user)) -> dict:
    name = singbox.validate_node_name(name)
    with db() as conn:
        row = conn.execute("SELECT name FROM nodes WHERE name = ?", (name,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Node not found")
    try:
        return {"name": name, "info": singbox.node_info(name)}
    except singbox.SingBoxError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/api/status")
def status(username: str = Depends(require_user)) -> dict:
    return singbox.service_status()


@app.get("/api/logs")
def logs(username: str = Depends(require_user)) -> dict:
    with db() as conn:
        rows = conn.execute("SELECT * FROM audit_logs ORDER BY id DESC LIMIT 100").fetchall()
    try:
        system_logs = singbox.service_logs()
    except singbox.SingBoxError as exc:
        system_logs = str(exc)
    return {"system_logs": system_logs, "audit_logs": [row_to_dict(row) for row in rows]}


@app.post("/api/restart")
def restart(username: str = Depends(require_user)) -> dict:
    try:
        output = singbox.restart_service()
    except singbox.SingBoxError as exc:
        audit("restart_failed", username, str(exc))
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    audit("restart", username, output)
    return {"ok": True, "output": output}


@app.get("/")
def root() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")


def init_admin(username: str, password: str) -> None:
    init_db()
    get_secret()
    now = utc_now()
    with db() as conn:
        exists = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
        if exists:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE username = ?",
                (hash_password(password), username),
            )
        else:
            conn.execute(
                "INSERT INTO users (username, password_hash, created_at) VALUES (?, ?, ?)",
                (username, hash_password(password), now),
            )
    audit("admin_init", username, "admin user initialized")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--init-admin", action="store_true")
    parser.add_argument("--username", default="admin")
    parser.add_argument("--password")
    args = parser.parse_args()
    if args.init_admin:
        if not args.password:
            raise SystemExit("--password is required")
        init_admin(args.username, args.password)
        print("admin initialized")


if __name__ == "__main__":
    main()
