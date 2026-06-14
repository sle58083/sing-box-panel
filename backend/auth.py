import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path


SECRET_PATH = os.environ.get("PANEL_SECRET_PATH", "/etc/sing-box-panel/session_secret")
COOKIE_NAME = "sing_box_panel_session"
SESSION_TTL_SECONDS = int(os.environ.get("PANEL_SESSION_TTL_SECONDS", "86400"))


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode((data + padding).encode("ascii"))


def get_secret() -> bytes:
    path = Path(SECRET_PATH)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(secrets.token_urlsafe(48), encoding="utf-8")
        try:
            os.chmod(path, 0o600)
        except PermissionError:
            pass
    return path.read_text(encoding="utf-8").strip().encode("utf-8")


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    rounds = 260000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, rounds)
    return f"pbkdf2_sha256${rounds}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, stored_hash: str) -> bool:
    try:
        algo, rounds_text, salt_text, digest_text = stored_hash.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        rounds = int(rounds_text)
        salt = _unb64(salt_text)
        expected = _unb64(digest_text)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, rounds)
        return hmac.compare_digest(actual, expected)
    except Exception:
        return False


def create_session(username: str) -> str:
    payload = {
        "sub": username,
        "iat": int(time.time()),
        "exp": int(time.time()) + SESSION_TTL_SECONDS,
        "nonce": secrets.token_urlsafe(12),
    }
    body = _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = hmac.new(get_secret(), body.encode("ascii"), hashlib.sha256).digest()
    return f"{body}.{_b64(signature)}"


def verify_session(token: str | None) -> str | None:
    if not token or "." not in token:
        return None
    try:
        body, signature_text = token.split(".", 1)
        expected = hmac.new(get_secret(), body.encode("ascii"), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _unb64(signature_text)):
            return None
        payload = json.loads(_unb64(body).decode("utf-8"))
        if int(payload.get("exp", 0)) < int(time.time()):
            return None
        username = payload.get("sub")
        if not isinstance(username, str) or not username:
            return None
        return username
    except Exception:
        return None
