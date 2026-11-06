#!/usr/bin/env python3
"""Exercise repeated quit and clear-on-quit in an isolated DEBUG app."""

import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import uuid


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    executable = app / "Contents/MacOS/PasteLite"
    suite = f"PasteLite.RuntimeReview.{uuid.uuid4().hex}"
    with tempfile.TemporaryDirectory(prefix="pastelite-runtime-review-") as directory:
        import os

        environment = dict(os.environ)
        environment["PASTELITE_DATA_DIRECTORY"] = directory
        environment["PASTELITE_PREFERENCES_SUITE"] = suite
        process = subprocess.Popen(
            [str(executable), "--ui-preview", "--review-quit"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            output, _ = process.communicate(timeout=25)
            if process.returncode != 0:
                raise RuntimeError(f"App quit with {process.returncode}: {output.decode(errors='replace')}")
            database = pathlib.Path(directory) / "History.sqlite3"
            if not database.is_file():
                raise RuntimeError("The app did not create its isolated history database.")
            with sqlite3.connect(database) as connection:
                items = connection.execute("SELECT COUNT(*) FROM history_items").fetchone()[0]
                assets = connection.execute("SELECT COUNT(*) FROM history_assets").fetchone()[0]
                saved = connection.execute("SELECT COUNT(*) FROM library_items").fetchone()[0]
                saved_assets = connection.execute("SELECT COUNT(*) FROM library_assets").fetchone()[0]
                groups = connection.execute("SELECT COUNT(*) FROM library_groups").fetchone()[0]
                recognized = connection.execute("SELECT COUNT(*) FROM recognized_text").fetchone()[0]
                sync_count = sum(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                                 for table in ["sync_outbox", "sync_received", "sync_versions", "sync_settings", "sync_snapshot_deletions"])
            if items or assets or saved or saved_assets or groups or recognized or sync_count:
                raise RuntimeError(f"Quit left data: {items} history, {assets} history assets, {saved} saved, {saved_assets} saved assets, {groups} groups.")
            print("PASS: repeated quit waited for history, saved items, groups, OCR, sync metadata and attachment clearing.")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            subprocess.run(
                ["/usr/bin/defaults", "delete", suite],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )


if __name__ == "__main__":
    main()
