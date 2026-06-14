import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


VALID_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
SING_BOX_SERVICE = os.environ.get("SING_BOX_SERVICE", "sing-box")

protocol_map = {
    "reality": ["add", "reality", "auto"],
    "tuic": ["add", "tuic", "auto"],
    "trojan": ["add", "trojan", "auto"],
    "hysteria2": ["add", "hy2", "auto"],
    "anytls": ["add", "anytls", "auto"],
    "ss": ["add", "ss", "auto"],
    "shadowsocks": ["add", "ss", "auto"],
}


class SingBoxError(RuntimeError):
    pass


def clean_output(value: str) -> str:
    return ANSI_RE.sub("", value or "").strip()


@dataclass(frozen=True)
class ConfigSnapshot:
    files: dict[str, float]


def validate_node_name(name: str) -> str:
    value = name.strip()
    if not VALID_NAME.fullmatch(value):
        raise ValueError("Node name must be 1-128 chars: letters, numbers, underscore, dash or dot.")
    return value


def validate_protocol(protocol: str) -> str:
    value = protocol.lower().strip()
    if value not in protocol_map:
        raise ValueError(f"Unsupported protocol: {protocol}")
    return value


def run_command(args: list[str], timeout: int = 30, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            args,
            shell=False,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise SingBoxError(f"command not found: {args[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise SingBoxError(f"command timed out: {' '.join(args)}") from exc
    if check and result.returncode != 0:
        message = clean_output(result.stderr or result.stdout or "command failed")
        raise SingBoxError(message)
    return result


def detect_command() -> str:
    configured = os.environ.get("SING_BOX_CMD")
    if configured:
        path = Path(configured)
        if path.is_absolute() and path.exists() and os.access(path, os.X_OK):
            return str(path)
        found = shutil.which(configured)
        if found:
            return found
        raise SingBoxError(f"SING_BOX_CMD is not executable: {configured}")

    try:
        result = subprocess.run(
            ["command", "-v", "sing-box"],
            shell=False,
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        candidate = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
        if result.returncode == 0 and candidate and Path(candidate).exists():
            return candidate
    except (FileNotFoundError, IndexError, subprocess.SubprocessError):
        pass

    found = shutil.which("sing-box")
    if found:
        return found

    fallback = Path("/usr/local/bin/sing-box")
    if fallback.exists() and os.access(fallback, os.X_OK):
        return str(fallback)

    raise SingBoxError("sing-box management command not found. Install with 233boy/sing-box first.")


def detect_config_dir() -> Path:
    configured = os.environ.get("SING_BOX_CONFIG_DIR")
    candidates = []
    if configured:
        candidates.append(Path(configured))
    candidates.extend([Path("/etc/sing-box/conf"), Path("/etc/sing-box")])

    for candidate in candidates:
        if candidate.is_dir():
            return candidate.resolve()

    root = Path("/etc/sing-box")
    if root.exists():
        result = run_command(["find", str(root), "-name", "*.json", "-type", "f"], timeout=10, check=False)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                path = Path(line.strip())
                if path.is_file():
                    return path.parent.resolve()

    raise SingBoxError("sing-box config directory not found under /etc/sing-box.")


def list_config_files() -> dict[str, float]:
    try:
        config_dir = detect_config_dir()
    except SingBoxError:
        return {}
    files: dict[str, float] = {}
    for path in config_dir.rglob("*.json"):
        if path.is_file():
            files[str(path.resolve())] = path.stat().st_mtime
    return files


def snapshot_configs() -> ConfigSnapshot:
    return ConfigSnapshot(files=list_config_files())


def detect_new_config(before: ConfigSnapshot) -> str:
    after = list_config_files()
    new_paths = [path for path in after if path not in before.files]
    changed_paths = [
        path for path, mtime in after.items()
        if path in before.files and mtime > before.files[path]
    ]
    candidates = new_paths or changed_paths
    if not candidates:
        raise SingBoxError("Node was added, but no new or changed JSON config file was detected.")
    newest = max(candidates, key=lambda path: after[path])
    return newest


def extract_name_from_output(output: str) -> str | None:
    for raw in output.splitlines():
        line = raw.strip()
        for pattern in (
            r"(?:name|节点|名称)\s*[:：]\s*([A-Za-z0-9_.-]{1,128})",
            r"\b([A-Za-z0-9][A-Za-z0-9_.-]{0,127})\.json\b",
        ):
            match = re.search(pattern, line, re.IGNORECASE)
            if match:
                try:
                    return validate_node_name(match.group(1))
                except ValueError:
                    continue
    return None


def extract_url(output: str) -> str:
    cleaned = clean_output(output)
    for line in cleaned.splitlines():
        stripped = line.strip()
        if "://" in stripped:
            return stripped
    return cleaned


def add_node(protocol: str) -> dict:
    protocol = validate_protocol(protocol)
    before = snapshot_configs()
    cmd = detect_command()
    result = run_command([cmd, *protocol_map[protocol]], timeout=180)
    output = clean_output(result.stdout)
    config_file = detect_new_config(before)
    name = extract_name_from_output(output) or validate_node_name(Path(config_file).stem)
    info = ""
    try:
        info = node_info(name)
    except SingBoxError:
        pass
    return {
        "name": name,
        "protocol": protocol,
        "config_file": config_file,
        "output": output,
        "info": info,
    }


def delete_node(name: str) -> str:
    name = validate_node_name(name)
    cmd = detect_command()
    result = run_command([cmd, "del", name], timeout=120, check=False)
    output = clean_output((result.stdout or "") + "\n" + (result.stderr or ""))
    if result.returncode != 0 and "已删除" not in output and "无法找到相关的配置文件" not in output:
        raise SingBoxError(output or "delete command failed")
    return output


def node_info(name: str) -> str:
    name = validate_node_name(name)
    cmd = detect_command()
    result = run_command([cmd, "info", name], timeout=30)
    return clean_output(result.stdout)


def node_url(name: str) -> str:
    name = validate_node_name(name)
    cmd = detect_command()
    result = run_command([cmd, "url", name], timeout=30)
    return extract_url(result.stdout)


def node_qr_text(name: str) -> str:
    name = validate_node_name(name)
    cmd = detect_command()
    result = run_command([cmd, "qr", name], timeout=30)
    return clean_output(result.stdout)


def service_status() -> dict:
    cmd = detect_command()
    result = run_command([cmd, "status"], timeout=30, check=False)
    active = "unknown"
    output = clean_output(result.stdout or result.stderr)
    if result.returncode == 0:
        lowered = output.lower()
        active = "active" if "running" in lowered or "active" in lowered else "ok"
    else:
        active = "error"
    return {
        "service": SING_BOX_SERVICE,
        "command": cmd,
        "active": active,
        "status": output,
    }


def service_logs() -> str:
    cmd = detect_command()
    result = run_command([cmd, "log"], timeout=30, check=False)
    if result.returncode == 0 and clean_output(result.stdout or result.stderr):
        return clean_output(result.stdout or result.stderr)
    fallback = run_command(
        ["journalctl", "-u", SING_BOX_SERVICE, "--no-pager", "-n", "200"],
        timeout=30,
        check=False,
    )
    return clean_output(fallback.stdout or fallback.stderr)


def restart_service() -> str:
    cmd = detect_command()
    result = run_command([cmd, "restart"], timeout=60, check=False)
    if result.returncode == 0:
        return clean_output(result.stdout)
    fallback = run_command(["systemctl", "restart", SING_BOX_SERVICE], timeout=60)
    return clean_output(fallback.stdout)
