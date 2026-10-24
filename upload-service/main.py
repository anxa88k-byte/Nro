import hmac
import asyncio
import json
import os
import re
import tempfile
import time
import uuid
import zipfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from fastapi import BackgroundTasks, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

app = FastAPI(title="IPA Forge upload service")
origins = [value.strip() for value in os.getenv("ALLOWED_ORIGINS", "").split(",") if value.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


@app.on_event("startup")
async def start_expiry_cleanup():
    async def cleanup_loop():
        while True:
            await asyncio.sleep(3600)
            clean_expired_uploads()
    asyncio.create_task(cleanup_loop())

UPLOAD_DIR = Path(os.getenv("UPLOAD_DIR", Path(tempfile.gettempdir()) / "ipa-forge-uploads"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", str(500 * 1024 * 1024)))
UPLOAD_TTL_SECONDS = int(os.getenv("UPLOAD_TTL_SECONDS", str(24 * 60 * 60)))


def setting(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise HTTPException(status_code=503, detail=f"Server is missing {name} configuration")
    return value


def require_upload_key(value: str | None) -> None:
    expected = setting("IPA_UPLOAD_TOKEN")
    if value is None or not hmac.compare_digest(value, expected):
        raise HTTPException(status_code=401, detail="Invalid upload key")


def clean_expired_uploads() -> None:
    cutoff = time.time() - UPLOAD_TTL_SECONDS
    for pattern in ("*.zip", "*.rar"):
        for path in UPLOAD_DIR.glob(pattern):
            try:
                if path.stat().st_mtime < cutoff:
                    path.unlink(missing_ok=True)
            except OSError:
                pass


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/api/config")
def config():
    return {"repository": setting("GITHUB_REPOSITORY")}


@app.post("/api/build")
async def build(
    file: UploadFile = File(...),
    method: str = Form("unsigned"),
    ipa_name: str = Form("ipa"),
    authorization: str | None = Header(default=None),
):
    require_upload_key(authorization.removeprefix("Bearer ") if authorization else None)
    if method not in {"unsigned", "development", "ad-hoc", "app-store-connect"}:
        raise HTTPException(status_code=400, detail="Unsupported signing method")
    ipa_name = re.sub(r"\.ipa$", "", ipa_name.strip(), flags=re.I)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", ipa_name):
        raise HTTPException(status_code=400, detail="IPA name must use 1–64 letters, numbers, dots, dashes, or underscores")
    suffix = Path(file.filename or "").suffix.lower()
    if suffix not in {".zip", ".rar"}:
        raise HTTPException(status_code=400, detail="Choose an Xcode project ZIP or RAR file")

    clean_expired_uploads()
    upload_id = uuid.uuid4().hex
    destination = UPLOAD_DIR / f"{upload_id}{suffix}"
    total = 0
    try:
        with destination.open("wb") as output:
            while chunk := await file.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail=f"Archive exceeds {MAX_UPLOAD_BYTES // (1024 * 1024)} MB")
                output.write(chunk)
        if total == 0:
            raise HTTPException(status_code=400, detail="The archive is empty")
        if suffix == ".rar":
            with destination.open("rb") as archive_file:
                signature = archive_file.read(8)
            if not (signature.startswith(b"Rar!\x1a\x07\x00") or signature.startswith(b"Rar!\x1a\x07\x01\x00")):
                raise HTTPException(status_code=400, detail="This file is not a valid RAR archive")
        else:
            try:
                with zipfile.ZipFile(destination) as archive:
                    entries = archive.infolist()
                    has_xcode_project = any(
                        re.search(r"\.xcodeproj/project\.pbxproj$", entry.filename) or
                        re.search(r"\.xcworkspace/contents\.xcworkspacedata$", entry.filename, re.I)
                        for entry in entries
                    )
                    if not has_xcode_project:
                        raise HTTPException(status_code=400, detail="ZIP must contain an .xcodeproj or .xcworkspace")
                    if sum(entry.file_size for entry in entries) > 5 * 1024 * 1024 * 1024:
                        raise HTTPException(status_code=413, detail="Unpacked project exceeds 5 GB")
                    if len(entries) > 100_000:
                        raise HTTPException(status_code=413, detail="ZIP contains too many files")
                    broken = archive.testzip()
                    if broken:
                        raise HTTPException(status_code=400, detail=f"Damaged ZIP entry: {Path(broken).name}")
            except zipfile.BadZipFile as exc:
                raise HTTPException(status_code=400, detail="This file is not a valid ZIP archive") from exc

        repository = setting("GITHUB_REPOSITORY")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise HTTPException(status_code=503, detail="GITHUB_REPOSITORY must be owner/repository")
        ref = os.getenv("GITHUB_REF", "main").strip()
        endpoint = f"https://api.github.com/repos/{repository}/actions/workflows/ios-ipa.yml/dispatches"
        payload = json.dumps({"ref": ref, "inputs": {
            "method": method, "upload_id": upload_id,
            "archive_type": suffix[1:],
            "ipa_name": ipa_name,
        }}).encode()
        request = Request(endpoint, data=payload, method="POST", headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {setting('GITHUB_TOKEN')}",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        })
        try:
            with urlopen(request, timeout=30) as response:
                if response.status not in (200, 201, 204):
                    raise HTTPException(status_code=502, detail=f"GitHub returned HTTP {response.status}")
        except HTTPError as exc:
            message = exc.read(1200).decode("utf-8", "replace")
            raise HTTPException(status_code=502, detail=f"GitHub could not start the workflow: {message}") from exc
        except URLError as exc:
            raise HTTPException(status_code=502, detail="Could not connect to GitHub Actions") from exc
        return {"upload_id": upload_id, "repository": repository, "ipa_name": ipa_name,
                "workflow_url": f"https://github.com/{repository}/actions/workflows/ios-ipa.yml"}
    except Exception:
        if destination.exists():
            destination.unlink(missing_ok=True)
        raise
    finally:
        await file.close()


@app.get("/api/files/{upload_id}")
def download(upload_id: str, background_tasks: BackgroundTasks,
             authorization: str | None = Header(default=None)):
    token = authorization.removeprefix("Bearer ") if authorization else None
    expected = setting("UPLOAD_SERVICE_TOKEN")
    if token is None or not hmac.compare_digest(token, expected):
        raise HTTPException(status_code=401, detail="Invalid runner token")
    if not re.fullmatch(r"[0-9a-f]{32}", upload_id):
        raise HTTPException(status_code=404, detail="Upload not found")
    matches = list(UPLOAD_DIR.glob(f"{upload_id}.*"))
    path = matches[0] if len(matches) == 1 else None
    if path is None or not path.is_file() or path.stat().st_mtime < time.time() - UPLOAD_TTL_SECONDS:
        if path is not None:
            path.unlink(missing_ok=True)
        raise HTTPException(status_code=404, detail="Upload expired or already downloaded")
    background_tasks.add_task(path.unlink, missing_ok=True)
    return FileResponse(path, media_type="application/octet-stream", filename=path.name, background=background_tasks)
