#!/usr/bin/env python3
"""Write a timestamped build-source manifest without selecting future versions."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def run(*args: str) -> str:
    try:
        return subprocess.check_output(args, stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def repo_info(name: str, path: Path) -> dict[str, object]:
    describe = run("git", "-C", str(path), "describe", "--tags", "--always")
    tag = run("git", "-C", str(path), "describe", "--tags", "--exact-match")
    commit = run("git", "-C", str(path), "rev-parse", "HEAD")
    status = run("git", "-C", str(path), "status", "--porcelain", "--untracked-files=all")
    changes = hashlib.sha256()
    diff = subprocess.run(
        ["git", "-C", str(path), "diff", "--binary", "HEAD"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    changes.update(diff.stdout)
    untracked = subprocess.run(
        ["git", "-C", str(path), "ls-files", "--others", "--exclude-standard", "-z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout
    for raw_name in untracked.split(b"\0"):
        if not raw_name:
            continue
        rel = Path(raw_name.decode(errors="surrogateescape"))
        candidate = path / rel
        if candidate.is_file():
            changes.update(raw_name)
            with candidate.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    changes.update(block)
    return {
        "name": name,
        "path": str(path),
        "source_role": "staged_build_copy" if "_src" in path.parts else "workspace_checkout",
        "version": describe or "unknown",
        "tag": tag or ("master" if name == "ffmpeg-source" else ""),
        "commit": commit or "unknown",
        "working_tree_dirty": bool(status),
        "working_tree_status_entries": len(status.splitlines()),
        "working_tree_patch_sha256": changes.hexdigest(),
    }


def version_line(command: str) -> str:
    path = command or shutil.which(command) or ""
    output = run(path, "--version") if path else ""
    return output.splitlines()[0] if output else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def macro(path: Path, name: str) -> str:
    if not path.is_file():
        return ""
    match = re.search(rf"^\s*#define\s+{re.escape(name)}\s+(\d+)", path.read_text(errors="replace"), re.MULTILINE)
    return match.group(1) if match else ""


def cuda_toolkit_version(cuda_home: Path) -> str:
    version_file = cuda_home / "version.json"
    if version_file.is_file():
        try:
            payload = json.loads(version_file.read_text(errors="replace"))
            version = payload.get("cuda", {}).get("version", "")
            if isinstance(version, str) and version:
                return version
        except (OSError, json.JSONDecodeError):
            pass

    raw = macro(cuda_home / "include" / "cuda.h", "CUDA_VERSION")
    if raw:
        number = int(raw)
        return f"{number // 1000}.{(number % 1000) // 10}.{number % 10}"
    return ""


def configure_args(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines = path.read_text(errors="replace").splitlines()
    if path.name == "config.log":
        for line in lines:
            candidate = line[2:].strip() if line.startswith(("$ ", "# ")) else ""
            if candidate.startswith("./configure ") or candidate == "./configure":
                return [candidate]
        return []
    return [line for line in lines if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--build-name", required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--configure-file", type=Path, required=True)
    parser.add_argument("--config-mak", type=Path, required=True)
    parser.add_argument("--started", required=True)
    parser.add_argument("--target-platform", required=True)
    parser.add_argument("--cpu-minimum", required=True)
    parser.add_argument("--source-repo", action="append", default=[])
    parser.add_argument("--build-mode", choices=("full", "resume", "selective"), default="full")
    parser.add_argument("--toolchain-flavor", default=os.environ.get("TOOLCHAIN_FLAVOR", ""))
    parser.add_argument("--incremental-build", choices=("0", "1"), default=os.environ.get("INCREMENTAL_BUILD", "0"))
    parser.add_argument("--ffmpeg-built", choices=("0", "1"), default="1")
    parser.add_argument("--built-stage", action="append", default=[])
    parser.add_argument("--validate", action="append", default=[])
    parser.add_argument("--skip", action="append", default=[])
    args = parser.parse_args()

    source_repos = []
    for item in args.source_repo:
        name, _, raw_path = item.partition("=")
        path = Path(raw_path)
        if (path / ".git").exists():
            source_repos.append(repo_info(name, path))
    if not args.source_repo:
        # Canonical inputs now live under sources/. Keep legacy workspace support,
        # but do not confuse the project's own Git repository with a dependency.
        configured_sources = os.environ.get("SOURCE_ROOT")
        source_root = Path(configured_sources) if configured_sources else args.root / "sources"
        if not source_root.is_dir():
            source_root = args.root
        for path in sorted(source_root.iterdir()):
            if path.is_dir() and (path / ".git").exists():
                source_repos.append(repo_info(path.name, path))

    tools = {}
    for name in ("CC", "CXX", "AR", "RANLIB", "STRIP", "WINDRES", "DLLTOOL", "PKG_CONFIG"):
        value = os.environ.get(name, "")
        tools[name.lower()] = {"path": value, "version": version_line(value)}
    for name in ("cmake", "ninja", "meson", "make", "python3"):
        tools[name] = {"path": shutil.which(name) or "", "version": version_line(name)}

    cuda = {}
    if args.build_name in {"full", "nvenc-lite"}:
        cuda_home = Path(os.environ.get("CUDA_HOME", ""))
        nvcc = os.environ.get("NVCC", "")
        cuda_version = cuda_toolkit_version(cuda_home)
        nvenc_h = args.prefix / "include" / "ffnvcodec" / "nvEncodeAPI.h"
        api_version = ".".join(filter(None, (
            macro(nvenc_h, "NVENCAPI_MAJOR_VERSION"),
            macro(nvenc_h, "NVENCAPI_MINOR_VERSION"),
        )))
        cuda = {
            "toolkit_path": str(cuda_home),
            "toolkit_version": cuda_version,
            "nvcc_path": nvcc,
            "nvcc_version": run(nvcc, "--version") if nvcc else "",
            "nvenc_api_version": api_version,
        }

    onevpl = {}
    if args.build_name == "qsv-lite":
        pkg_config = os.environ.get("PKG_CONFIG", "pkg-config")
        onevpl = {
            "pkg_config_version": run(pkg_config, "--modversion", "vpl"),
        }

    config = {}
    if args.ffmpeg_built == "1" and args.config_mak.is_file():
        wanted = ("CONFIG_LIBOPUS", "CONFIG_LIBOPUS_ENCODER", "CONFIG_OPUS_DECODER",
                  "CONFIG_LIBVPL", "CONFIG_HEVC_NVENC_ENCODER", "CONFIG_AV1_NVENC_ENCODER",
                  "CONFIG_HEVC_QSV_ENCODER", "CONFIG_AV1_QSV_ENCODER")
        lines = args.config_mak.read_text(errors="replace").splitlines()
        config = {key: "yes" for key in wanted if f"{key}=yes" in lines}

    artifacts = []
    for path in sorted(args.artifact_dir.iterdir()) if args.artifact_dir.is_dir() else []:
        if path.is_file() and path.suffix.lower() in {".exe", ".dll", ".7z"}:
            artifacts.append({
                "path": str(path),
                "name": path.name,
                "size_bytes": path.stat().st_size,
                "sha256": sha256(path),
            })

    completed = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    payload = {
        "build_name": args.build_name,
        "build_started": args.started,
        "build_completed": completed,
        "source_update_policy": "rolling upstream latest stable tags or configured rolling branches; recorded commits describe this build only",
        "build_scope": {
            "mode": args.build_mode,
            "built_stages": args.built_stage,
            "partial": args.build_mode != "full",
        },
        "toolchain_flavor": args.toolchain_flavor,
        "incremental_build": args.incremental_build == "1",
        "ffmpeg_built_this_run": args.ffmpeg_built == "1",
        "source_repositories": source_repos,
        "toolchain": tools,
        "cuda": cuda,
        "oneVPL": onevpl,
        "configure_args": configure_args(args.configure_file) if args.ffmpeg_built == "1" else [],
        "configure_result": config,
        "target_platform": args.target_platform,
        "cpu_minimum_instruction_set": args.cpu_minimum,
        "prefix": str(args.prefix),
        "artifacts": artifacts,
        "successful_validations": args.validate,
        "skipped_validations": args.skip + ([
            "This partial build reused previously installed PREFIX dependencies; their original source revisions are outside this build scope."
        ] if args.build_mode != "full" else []),
        "manifest_policy": "record-only; rolling latest source selection is resolved again on the next update",
    }

    out_dir = args.root / "build-manifests" / args.build_name
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    out = out_dir / f"{args.build_name}-{stamp}.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
