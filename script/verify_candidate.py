#!/usr/bin/env python3
"""Verify and launch mounted candidate apps with isolated, paused storage."""

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import sqlite3
import subprocess
import tempfile
import time
import uuid


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE)


def storage_ready(database):
    if not database.is_file():
        return False
    try:
        with sqlite3.connect(database, timeout=0.2) as connection:
            if connection.execute("PRAGMA user_version").fetchone()[0] != 4:
                return False
            tables = ["history_items", "history_assets", "library_items", "library_assets", "library_groups", "recognized_text", "sync_outbox", "sync_received", "sync_versions", "sync_settings", "sync_snapshot_deletions"]
            return all(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0 for table in tables)
    except sqlite3.Error:
        return False


def verify(artifacts, arch, version, build):
    dmg = artifacts / f"PasteLite-{version}-macos-{arch}.dmg"
    result = {"architecture": arch, "dmg": dmg.name, "sha256": hashlib.sha256(dmg.read_bytes()).hexdigest()}
    mounted = plistlib.loads(subprocess.check_output(
        ["/usr/bin/hdiutil", "attach", str(dmg), "-readonly", "-nobrowse", "-plist"],
        stderr=subprocess.PIPE,
    ))
    mount = next(item["mount-point"] for item in mounted["system-entities"] if "mount-point" in item)
    try:
        with tempfile.TemporaryDirectory(prefix=f"pastelite-candidate-{arch}-") as temporary:
            base = pathlib.Path(temporary)
            installed = base / "PasteLite.app"
            run("/usr/bin/ditto", str(pathlib.Path(mount) / "PasteLite.app"), str(installed))
            info = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
            expected = ("com.xia.PasteLite", version, build, "12.0")
            actual = tuple(info[key] for key in [
                "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"
            ])
            if actual != expected:
                raise RuntimeError(f"Unexpected bundle metadata: {actual}")
            executable = installed / "Contents/MacOS/PasteLite"
            if run("/usr/bin/lipo", "-archs", str(executable)).strip() != arch:
                raise RuntimeError(f"Incorrect architecture in {dmg.name}")
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed))
            unexpected = [str(path.relative_to(installed)) for path in installed.rglob("*")
                          if path.is_file() and (path.suffix in [".sqlite3", ".log", ".swift"] or path.name.startswith(".env"))]
            if unexpected:
                raise RuntimeError(f"Unexpected artifact files: {unexpected}")
            strings = run("/usr/bin/strings", str(executable))
            if str(pathlib.Path.home()) in strings or "Demo secret, for UI testing only" in strings:
                raise RuntimeError("Candidate contains local build paths or development fixtures")
            suite = f"PasteLite.CandidateSmoke.{uuid.uuid4().hex}"
            for key, value in [("design.recordingPaused", "true"), ("design.automaticUpdates", "false")]:
                run("/usr/bin/defaults", "write", suite, key, "-bool", value)
            data = base / "data"
            data.mkdir()
            log_path = base / "runtime.log"
            try:
                with log_path.open("wb") as log:
                    environment = dict(os.environ, PASTELITE_DATA_DIRECTORY=str(data), PASTELITE_PREFERENCES_SUITE=suite)
                    process = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=subprocess.STDOUT)
                    try:
                        deadline = time.monotonic() + 15
                        while time.monotonic() < deadline and process.poll() is None:
                            if storage_ready(data / "History.sqlite3"):
                                break
                            time.sleep(0.1)
                        else:
                            raise RuntimeError(f"Candidate startup did not finish: {log_path.read_text(errors='replace')}")
                        result.update(bundle=f"{version} ({build})", minimum_os="12.0", signature="verified",
                                      mounted_launch="passed; schema 4 and empty isolated storage verified",
                                      runtime="native Apple Silicon")
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
            finally:
                subprocess.run(["/usr/bin/defaults", "delete", suite], capture_output=True, check=False)
    finally:
        run("/usr/bin/hdiutil", "detach", mount)
    archive = artifacts / f"PasteLite-{version}-macos-{arch}.app.zip"
    listing = run("/usr/bin/unzip", "-Z1", str(archive))
    if "__MACOSX" in listing or ".DS_Store" in listing:
        raise RuntimeError(f"Unexpected archive metadata in {archive.name}")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--version", default="0.4.1")
    parser.add_argument("--build", default="41")
    parser.add_argument("--output", type=pathlib.Path)
    arguments = parser.parse_args()
    results = []
    for architecture in ["arm64"]:
        result = verify(arguments.directory.resolve(), architecture, arguments.version, arguments.build)
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
