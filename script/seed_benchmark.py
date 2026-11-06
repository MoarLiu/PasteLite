#!/usr/bin/env python3
"""Populate an explicitly selected empty verification database with synthetic data."""

import base64
import hashlib
import pathlib
import sqlite3
import sys
import time
import uuid


def main():
    path = pathlib.Path(sys.argv[1]).resolve()
    if not path.is_file():
        raise SystemExit("Start an isolated app once to create its schema first.")
    with sqlite3.connect(path) as database:
        if database.execute("PRAGMA user_version").fetchone()[0] != 4:
            raise SystemExit("Unsupported verification schema.")
        for table in ["history_items", "library_items", "library_groups"]:
            if database.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]:
                raise SystemExit("Refusing to replace an existing nonempty database.")
        now = time.time()
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZJ1sAAAAASUVORK5CYII=")
        for index in range(5000):
            identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, f"pastelite-benchmark-history-{index}")).upper()
            title = f"Entry {index:04d} 中文 English"
            text = title + ("\n长文本 English content " * 2500 if index % 100 == 0 else " synthetic content")
            image = index % 100 == 1
            kind, blob, representation = ("image", png, "public.png") if image else ("text", text.encode(), "public.utf8-plain-text")
            digest = hashlib.sha256(blob).hexdigest()
            database.execute("INSERT INTO history_items (id,title,kind,source_app_name,source_bundle_identifier,copied_at,content_hash,preview_text,is_pinned,use_count) VALUES (?,?,?,?,?,?,?,?,0,0)",
                             (identifier, title, kind, "Notes" if index % 2 else "Editor", "example.notes" if index % 2 else "example.editor", now-index, digest+str(index), "" if image else text))
            database.execute("INSERT INTO history_assets (id,history_id,item_index,pasteboard_type,storage_kind,data_blob,byte_count) VALUES (?,?,0,?,'blob',?,?)", (str(uuid.uuid4()),identifier,representation,blob,len(blob)))
        group = str(uuid.uuid4()).upper()
        database.execute("INSERT INTO library_groups VALUES (?,?,?,?,?)", (group, "提示词常用分组与很长名称完整显示验证", "提示词常用分组与很长名称完整显示验证", now, now))
        for index in range(200):
            identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, f"pastelite-benchmark-saved-{index}")).upper()
            title = f"Saved {index:03d}"
            text = "x" * 1048576 if index == 199 else f"Snippet {index} 常用文本 synthetic content"
            blob = text.encode()
            database.execute("INSERT INTO library_items (id,group_id,name,item_type,kind,original_title,preview_text,source_app_name,source_bundle_identifier,content_hash,saved_at,updated_at,use_count,revision) VALUES (?,?,?,'snippet','text',?,?,?,?,?,?,?,0,1)",
                             (identifier, group if index % 2 else None, title,title,text,"Notes","example.notes",hashlib.sha256(blob).hexdigest(),now,now))
            database.execute("INSERT INTO library_assets VALUES (?,?,0,'public.utf8-plain-text',?,?)", (str(uuid.uuid4()),identifier,blob,len(blob)))
    print("Created 5,000 synthetic history items and 200 saved snippets, including long text, images and a 1 MiB snippet.")


if __name__ == "__main__":
    main()
