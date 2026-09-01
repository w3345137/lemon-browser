#!/usr/bin/env python3

"""Create a Gitee Release and upload build artifacts using only stdlib."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import urllib.parse
import subprocess


API_ROOT = "https://gitee.com/api/v5"


def curl_json(url: str, token: str, *arguments: str):
    command = [
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        "300",
        "--header",
        f"Authorization: Bearer {token}",
        "--header",
        "Accept: application/json",
        *arguments,
        url,
    ]
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Gitee API failed: {detail[:500]}")
    payload = result.stdout.decode("utf-8")
    return json.loads(payload) if payload else {}


def find_release(owner: str, repo: str, tag: str, token: str):
    query = urllib.parse.urlencode({"per_page": 100})
    releases = curl_json(f"{API_ROOT}/repos/{owner}/{repo}/releases?{query}", token)
    return next((release for release in releases if release.get("tag_name") == tag), None)


def create_release(owner: str, repo: str, tag: str, title: str, body: str, token: str):
    return curl_json(
        f"{API_ROOT}/repos/{owner}/{repo}/releases",
        token,
        "--request",
        "POST",
        "--data-urlencode",
        f"access_token={token}",
        "--data-urlencode",
        f"tag_name={tag}",
        "--data-urlencode",
        "target_commitish=main",
        "--data-urlencode",
        f"name={title}",
        "--data-urlencode",
        f"body={body}",
        "--data-urlencode",
        "prerelease=false",
    )


def upload_asset(owner: str, repo: str, release_id: int, path: pathlib.Path, token: str):
    return curl_json(
        f"{API_ROOT}/repos/{owner}/{repo}/releases/{release_id}/attach_files",
        token,
        "--request",
        "POST",
        "--form-string",
        f"access_token={token}",
        "--form",
        f"file=@{path}",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--owner", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--body", required=True)
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()

    token = os.environ.get("GITEE_TOKEN", "").strip()
    if not token:
        raise SystemExit("GITEE_TOKEN is required")

    release = find_release(args.owner, args.repo, args.tag, token)
    if release is None:
        release = create_release(args.owner, args.repo, args.tag, args.title, args.body, token)

    existing_names = {
        asset.get("name") for asset in release.get("assets", []) if isinstance(asset, dict)
    }
    for raw_path in args.files:
        path = pathlib.Path(raw_path)
        if path.name in existing_names:
            print(f"已存在，跳过：{path.name}")
            continue
        result = upload_asset(args.owner, args.repo, int(release["id"]), path, token)
        print(f"已上传：{result.get('name', path.name)}")


if __name__ == "__main__":
    main()
