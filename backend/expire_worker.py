from datetime import datetime, timezone

from db import audit, db, init_db, utc_now
import singbox


def disable_expired_nodes() -> int:
    init_db()
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    with db() as conn:
        rows = conn.execute(
            "SELECT name FROM nodes WHERE enabled = 1 AND expire_at IS NOT NULL AND expire_at <= ?",
            (now,),
        ).fetchall()

    count = 0
    for row in rows:
        name = singbox.validate_node_name(row["name"])
        try:
            singbox.delete_node(name)
            detail = "expired node removed from sing-box"
        except Exception as exc:
            detail = f"expire command failed: {exc}"
        with db() as conn:
            conn.execute(
                "UPDATE nodes SET enabled = 0, updated_at = ? WHERE name = ?",
                (utc_now(), name),
            )
        audit("node_expired", name, detail)
        count += 1
    return count


if __name__ == "__main__":
    disabled = disable_expired_nodes()
    print(f"disabled {disabled} expired nodes")
