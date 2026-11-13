#!/usr/bin/env python3
"""stdio MCP bridge for the SIFT desktop app's loopback endpoint.

Clients that only speak stdio (Claude Code, Codex, omp, ...) register this script.
It reads newline-delimited JSON-RPC from stdin, forwards each message to the app's
127.0.0.1 endpoint with the bearer token, and writes the response to stdout.

Environment:
  SIFT_MCP_TOKEN  required; shown in SIFT > To-do Settings > MCP 연결
  SIFT_MCP_URL    optional; default http://127.0.0.1:47831/mcp

Standard library only.
"""
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("SIFT_MCP_URL", "http://127.0.0.1:47831/mcp")
TOKEN = os.environ.get("SIFT_MCP_TOKEN", "")
TIMEOUT_SECONDS = 60


def error_reply(request_id, code, message):
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def forward(line):
    """Returns the JSON-RPC response text, or None for notifications."""
    try:
        parsed = json.loads(line)
    except json.JSONDecodeError:
        return error_reply(None, -32700, "Parse error")
    has_id = isinstance(parsed, dict) and "id" in parsed
    request_id = parsed.get("id") if isinstance(parsed, dict) else None

    request = urllib.request.Request(
        URL,
        data=line.encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {TOKEN}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8").strip()
            return body or None
    except urllib.error.HTTPError as error:
        if not has_id:
            return None
        return error_reply(request_id, -32000, f"SIFT endpoint returned HTTP {error.code}")
    except (urllib.error.URLError, OSError) as error:
        if not has_id:
            return None
        return error_reply(request_id, -32000, f"SIFT app not reachable at {URL}: {error}")


def main():
    if not TOKEN:
        print("SIFT_MCP_TOKEN is required", file=sys.stderr)
        return 2
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        reply = forward(line)
        if reply is not None:
            sys.stdout.write(reply + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
