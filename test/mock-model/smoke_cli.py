#!/usr/bin/env python3
"""Check installed Claude and Codex clients against an isolated local server."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from server import TEXT, make_server


def main():
    """Run text, tool, thought, and plan turns in a temporary workspace."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--claude", default="claude")
    parser.add_argument("--codex", default="codex")
    args = parser.parse_args()
    # Resolve paths before subprocesses change their working directory.
    for key in ("claude", "codex"):
        value = getattr(args, key)
        if "/" in value:
            setattr(args, key, str(Path(value).resolve()))
    server = make_server()
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    base = "http://127.0.0.1:" + str(server.server_port)
    try:
        with tempfile.TemporaryDirectory(prefix="mock-model-") as tmp:
            Path(tmp, "codex").mkdir()
            Path(tmp, "src").mkdir()
            Path(tmp, "src/config.json").write_text("{}\n")
            env = {
                **os.environ,
                "HOME": tmp,
                "CODEX_HOME": tmp + "/codex",
                "CLAUDE_CONFIG_DIR": tmp + "/claude",
                "ANTHROPIC_API_KEY": "mock-key",
                "ANTHROPIC_BASE_URL": base,
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "DISABLE_AUTOUPDATER": "1",
                "OTEL_SDK_DISABLED": "true",
            }
            env.pop("CLAUDECODE", None)
            commands = [
                [
                    args.claude,
                    "--bare",
                    "-p",
                    "--model",
                    "claude-sonnet-4-6",
                    "--allowedTools",
                    "Read,TodoWrite",
                    "--",
                ],
                [
                    args.codex,
                    "exec",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "-c",
                    'model_provider="mock"',
                    "-c",
                    'model_providers.mock.name="Mock"',
                    "-c",
                    'model_providers.mock.base_url="' + base + '/v1"',
                    "-c",
                    'model_providers.mock.wire_api="responses"',
                    "-m",
                    "mock-model",
                ],
            ]
            for command in commands:
                for scenario in ("agent_message", "tool_call", "thought", "plan"):
                    result = subprocess.run(
                        command + ["test " + scenario],
                        cwd=tmp,
                        env=env,
                        input="",
                        capture_output=True,
                        text=True,
                        timeout=45,
                    )
                    assert result.returncode == 0, result.stdout + result.stderr
                    if scenario == "agent_message":
                        assert TEXT in result.stdout, result.stdout
                    elif scenario in {"tool_call", "plan"}:
                        assert "Done." in result.stdout, result.stdout + result.stderr
                    print(Path(command[0]).name + ": " + scenario + " OK")
            result = subprocess.run(
                [
                    args.claude,
                    "--bare",
                    "-p",
                    "--model",
                    "claude-sonnet-4-6",
                    "--output-format",
                    "stream-json",
                    "--include-partial-messages",
                    "--verbose",
                    "test long_running",
                ],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=45,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            events = [
                json.loads(line).get("event", {}) for line in result.stdout.splitlines()
            ]
            parts = [
                event["delta"]["text"]
                for event in events
                if event.get("type") == "content_block_delta"
                and event["delta"]["type"] == "text_delta"
            ]
            assert parts == [TEXT] * 3, parts
            print("claude: long_running API deltas OK")
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == "__main__":
    main()
