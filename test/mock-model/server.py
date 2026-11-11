#!/usr/bin/env python3
"""Serve deterministic mock-acp scenarios through model HTTP APIs."""

import argparse
import json
import re
import shlex
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

FIXTURES = Path(__file__).parent / "fixtures"
SCENARIOS = {
    "agent_message": "golden/session_update_agent_message_chunk",
    "thought": "golden/session_update_agent_thought_chunk",
    "plan": "golden/session_update_plan",
    "tool_call": "golden/session_update_tool_call",
    "tool_call_read": "golden/session_update_tool_call_read",
    "tool_call_edit": "golden/session_update_tool_call_edit",
    "tool_call_locations": "golden/session_update_tool_call_locations_rawinput",
    "tool_call_diff": "addition/session_update_tool_call_update_diff_content",
    "tool_call_diff_no_old": "addition/session_update_tool_call_update_diff_no_old_content",
    "tool_call_terminal": "addition/session_update_tool_call_update_terminal_content",
    "config_option": "golden/session_update_config_option_update",
    "user_message": "golden/session_update_user_message_chunk",
    "available_commands": "addition/session_update_available_commands",
    "current_mode": "addition/session_update_current_mode",
    "session_info": "addition/session_update_session_info",
    "usage": "addition/session_update_usage",
}
USAGE = {"input_tokens": 512, "output_tokens": 32}


def fixture(name):
    """Read a vendored ACP fixture."""
    return json.loads((FIXTURES / (name + ".json")).read_text())


TEXT = fixture("golden/session_update_agent_message_chunk")["content"]["text"]
THOUGHT = fixture("golden/session_update_agent_thought_chunk")["content"]["text"]


def text_content(content):
    """Extract text without treating tool results as user prompts."""
    if isinstance(content, str):
        return content
    return "\n".join(
        block.get("text", "")
        for block in content
        if block.get("type") in {"text", "input_text", "output_text"}
    )


def select_scenario(items):
    """Find the latest user scenario and count subsequent tool results."""
    prompt, results = "", 0
    for item in items:
        content = item.get("content", [])
        if item.get("role") == "user":
            text = text_content(content)
            if text:
                prompt, results = text, 0
        if item.get("role") == "tool" or item.get("type") in {
            "function_call_output",
            "custom_tool_call_output",
        }:
            results += 1
        if isinstance(content, list):
            results += sum(block.get("type") == "tool_result" for block in content)
    # Harnesses can wrap user text in XML or prepend model-change notes.
    matches = re.findall(r"(?im)^\s*test ([a-z_]+)\s*(?:$|<)", prompt)
    return (matches[-1].lower() if matches else ""), results


def tool_call(scenario, tools, completed=False):
    """Map a scenario to an advertised Claude or Codex tool."""
    names = {
        tool.get("name", tool.get("function", {}).get("name")): tool for tool in tools
    }
    data = fixture(SCENARIOS[scenario]) if scenario in SCENARIOS else {}
    path = "src/config.json"
    if scenario == "fs_read":
        data = fixture("golden/fs_read_text_file_request")
        path = "src/main.py"
    elif scenario == "fs_write":
        data = fixture("golden/fs_write_text_file_request")
        path = "config.json"
    command = "cat " + shlex.quote(path)
    candidates = [("Read", {"file_path": path}), ("read_file", {"path": path})]
    if scenario == "fs_read":
        candidates[0][1].update(offset=data["line"], limit=data["limit"])
        command = "sed -n '10,59p' src/main.py"
    elif scenario in {
        "tool_call_edit",
        "tool_call_diff",
        "tool_call_diff_no_old",
        "fs_write",
    }:
        content = data.get("content", data.get("rawInput", {}).get("content", ""))
        if isinstance(content, list):
            content = content[0]["newText"]
        command = (
            "mkdir -p "
            + shlex.quote(str(Path(path).parent))
            + "; printf %s "
            + shlex.quote(content)
            + " > "
            + shlex.quote(path)
        )
        candidates = [
            ("Write", {"file_path": path, "content": content}),
            ("write_file", {"path": path, "content": content}),
        ]
    elif scenario == "plan":
        entries = data["entries"]
        candidates = [
            (
                "TodoWrite",
                {
                    "todos": [
                        {
                            "content": e["content"],
                            "activeForm": e["content"],
                            "status": "completed" if completed else "pending",
                        }
                        for e in entries
                    ]
                },
            ),
            (
                "update_plan",
                {
                    "plan": [
                        {
                            "step": e["content"],
                            "status": "completed" if completed else "pending",
                        }
                        for e in entries
                    ]
                },
            ),
        ]
        command = (
            "printf '%s\\n' 'Check for syntax errors' 'Identify potential type issues'"
        )
    elif scenario == "request_permission":
        path = "mock-permission.txt"
        content = "Mock permission granted.\n"
        candidates = [("Write", {"file_path": path, "content": content})]
        command = "printf %s " + shlex.quote(content) + " > " + shlex.quote(path)
    elif scenario == "tool_call_terminal":
        # Print the fixture transcript instead of installing packages.
        command = "printf '%s\\n' " + shlex.quote(
            "Terminal command completed.\n$ npm install\nadded 42 packages in 2s"
        )
        candidates = []
    candidates += [
        ("Bash", {"command": command, "description": data.get("title", scenario)}),
        ("exec_command", {"cmd": command}),
        ("shell_command", {"command": command}),
        ("shell", {"command": ["sh", "-c", command]}),
    ]
    for name, arguments in candidates:
        if name in names:
            if scenario == "request_permission" and name in {
                "exec_command",
                "shell_command",
                "shell",
            }:
                arguments.update(
                    sandbox_permissions="require_escalated",
                    justification="Allow the mock permission write?",
                )
            return {
                "type": "tool_use",
                "id": "call_" + uuid4().hex,
                "name": name,
                "input": arguments,
            }
    raise ValueError(
        "Scenario requires an advertised read, write, plan, or shell tool: " + scenario
    )


def scenario_blocks(request, items):
    """Build one model turn; tool results advance multi-turn scenarios."""
    scenario, results = select_scenario(items)
    if scenario in {"error", "init_error", "auth_error"}:
        return scenario, []
    sequence = (
        list(SCENARIOS) + ["long_running", "request_permission", "fs_read", "fs_write"]
        if scenario == "all"
        else [scenario]
    )
    blocks = []
    tool_index = 0
    for name in sequence:
        if name.startswith("tool_call") or name in {
            "plan",
            "request_permission",
            "fs_read",
            "fs_write",
        }:
            steps = 2 if name == "plan" else 1
            if tool_index + steps > results:
                blocks.append(
                    tool_call(
                        name, request.get("tools", []), completed=results > tool_index
                    )
                )
                break
            tool_index += steps
            continue
        if results > tool_index or (results and scenario != "all"):
            continue
        if name == "thought":
            blocks.append(
                {"type": "thinking", "thinking": THOUGHT, "signature": "mock-signature"}
            )
        elif name == "agent_message":
            blocks.append({"type": "text", "text": TEXT})
        elif name == "long_running":
            blocks.extend(
                [
                    {
                        "type": "thinking",
                        "thinking": THOUGHT * 3,
                        "signature": "mock-signature",
                    },
                    {"type": "text", "text": TEXT * 3},
                ]
            )
        elif name in {"model", "permission", "reasoning"}:
            if name == "model":
                value = request.get("model", "mock-model")
            elif name == "reasoning":
                value = request.get("reasoning", {}).get(
                    "effort", request.get("output_config", {}).get("effort", "low")
                )
            else:
                value = "ask"
            blocks.append({"type": "text", "text": value})
        elif name in SCENARIOS:
            # ACP-only updates have no model-API event. Preserve their payload as text.
            blocks.append(
                {
                    "type": "text",
                    "text": json.dumps(fixture(SCENARIOS[name]), sort_keys=True),
                }
            )
    if not blocks:
        blocks = [{"type": "text", "text": "Done."}]
    return scenario, blocks


class Handler(BaseHTTPRequestHandler):
    """Handle local model API requests without external dependencies."""

    def send_json(self, status, data):
        """Send a bounded JSON response."""
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        """Answer the Claude Code connectivity probe without a response body."""
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        """Expose readiness and a deterministic model list."""
        path = urlsplit(self.path).path
        if path == "/health":
            self.send_json(200, {"status": "ok"})
        elif path == "/requests":
            with self.server.history_lock:
                requests = list(self.server.requests)
            self.send_json(200, requests)
        elif path == "/v1/models":
            self.send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": name,
                            "object": "model",
                            "created": 0,
                            "owned_by": "mock-model",
                        }
                        for name in (
                            "mock-model",
                            "mock-model-2",
                            "claude-sonnet-4-6",
                            "claude-opus-4-6",
                        )
                    ],
                },
            )
        else:
            self.send_json(
                404,
                {"error": {"type": "not_found_error", "message": "Unknown endpoint"}},
            )

    def do_POST(self):
        """Validate a request and dispatch its wire format."""
        path = urlsplit(self.path).path
        if path not in {
            "/v1/messages",
            "/v1/messages/count_tokens",
            "/v1/chat/completions",
            "/v1/responses",
            "/responses",
        }:
            self.send_json(
                404,
                {"error": {"type": "not_found_error", "message": "Unknown endpoint"}},
            )
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16 * 1024 * 1024:
                raise ValueError("Request body must contain 1 byte to 16 MiB")
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object")
            if path.endswith("count_tokens"):
                self.send_json(200, {"input_tokens": 512})
                return
            items = request.get("messages", request.get("input", []))
            if isinstance(items, str):
                items = [{"role": "user", "content": items}]
            if not isinstance(items, list) or any(
                not isinstance(item, dict) for item in items
            ):
                raise ValueError("messages/input must be a list of objects")
            previous = request.get("previous_response_id")
            if previous:
                with self.server.history_lock:
                    if previous not in self.server.history:
                        raise ValueError("Unknown previous_response_id")
                    items = self.server.history[previous] + items
            with self.server.history_lock:
                self.server.requests.append({"path": path, "body": request})
            scenario, blocks = scenario_blocks(request, items)
            if scenario in {"error", "init_error", "auth_error"}:
                self.send_json(
                    401 if scenario == "auth_error" else 500,
                    {
                        "type": "error",
                        "error": {
                            "type": "authentication_error"
                            if scenario == "auth_error"
                            else "api_error",
                            "message": "Intentionally triggered error for testing.",
                        },
                    },
                )
                return
        except (ValueError, TypeError, KeyError, AttributeError) as error:
            self.send_json(
                400,
                {
                    "type": "error",
                    "error": {"type": "invalid_request_error", "message": str(error)},
                },
            )
            return
        try:
            if path.endswith("messages"):
                self.messages(request, blocks, scenario)
            elif path.endswith("completions"):
                self.completions(request, blocks, scenario)
            else:
                self.respond_responses(request, blocks, scenario, items)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancellation closes this request, not other conversations.

    def start_stream(self):
        """Start a close-delimited SSE response."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def event(self, data, name=None):
        """Flush one SSE event."""
        payload = data if isinstance(data, str) else json.dumps(data)
        self.wfile.write(
            (
                ("event: " + name + "\n" if name else "") + "data: " + payload + "\n\n"
            ).encode()
        )
        self.wfile.flush()

    def delay(self, scenario):
        """Keep long-running streams open for cancellation tests."""
        if scenario == "long_running":
            time.sleep(self.server.delay)

    def stream_parts(self, text, scenario):
        """Split a long-running block into three deltas within the same block."""
        if scenario == "long_running":
            size = len(text) // 3
            return [text[index : index + size] for index in range(0, len(text), size)]
        return [text]

    def messages(self, request, blocks, scenario):
        """Emit Anthropic Messages JSON or streaming events."""
        stop = "tool_use" if blocks[-1]["type"] == "tool_use" else "end_turn"
        message = {
            "id": "msg_" + uuid4().hex,
            "type": "message",
            "role": "assistant",
            "model": request.get("model", "mock-model"),
            "content": blocks,
            "stop_reason": stop,
            "stop_sequence": None,
            "usage": USAGE,
        }
        if not request.get("stream"):
            self.send_json(200, message)
            return
        self.start_stream()
        self.event(
            {
                "type": "message_start",
                "message": {
                    **message,
                    "content": [],
                    "stop_reason": None,
                    "usage": {"input_tokens": 512, "output_tokens": 0},
                },
            },
            "message_start",
        )
        for index, block in enumerate(blocks):
            kind = block["type"]
            initial = (
                {**block, "input": {}}
                if kind == "tool_use"
                else {"type": kind, "text" if kind == "text" else "thinking": ""}
            )
            self.event(
                {
                    "type": "content_block_start",
                    "index": index,
                    "content_block": initial,
                },
                "content_block_start",
            )
            if kind == "tool_use":
                delta = {
                    "type": "input_json_delta",
                    "partial_json": json.dumps(block["input"]),
                }
            elif kind == "thinking":
                delta = {"type": "thinking_delta", "thinking": block["thinking"]}
            else:
                delta = {"type": "text_delta", "text": block["text"]}
            field = (
                "partial_json"
                if kind == "tool_use"
                else "thinking"
                if kind == "thinking"
                else "text"
            )
            for part in self.stream_parts(delta[field], scenario):
                self.event(
                    {
                        "type": "content_block_delta",
                        "index": index,
                        "delta": {**delta, field: part},
                    },
                    "content_block_delta",
                )
                self.delay(scenario)
            if kind == "thinking":
                self.event(
                    {
                        "type": "content_block_delta",
                        "index": index,
                        "delta": {
                            "type": "signature_delta",
                            "signature": block["signature"],
                        },
                    },
                    "content_block_delta",
                )
            self.event(
                {"type": "content_block_stop", "index": index}, "content_block_stop"
            )
        self.event(
            {
                "type": "message_delta",
                "delta": {"stop_reason": stop, "stop_sequence": None},
                "usage": {"output_tokens": 32},
            },
            "message_delta",
        )
        self.event({"type": "message_stop"}, "message_stop")

    def completions(self, request, blocks, scenario):
        """Emit OpenAI Chat Completions JSON or chunks."""
        message = {
            "role": "assistant",
            "content": "".join(b.get("text", "") for b in blocks),
        }
        calls = [
            {
                "id": b["id"],
                "type": "function",
                "function": {"name": b["name"], "arguments": json.dumps(b["input"])},
            }
            for b in blocks
            if b["type"] == "tool_use"
        ]
        if calls:
            message["tool_calls"] = calls
            message["content"] = None
        reasoning = "".join(b.get("thinking", "") for b in blocks)
        if reasoning:
            message["reasoning_content"] = reasoning
        base = {
            "id": "chatcmpl_" + uuid4().hex,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.get("model", "mock-model"),
        }
        finish = "tool_calls" if calls else "stop"
        usage = {"prompt_tokens": 512, "completion_tokens": 32, "total_tokens": 544}
        if not request.get("stream"):
            self.send_json(
                200,
                {
                    **base,
                    "choices": [
                        {"index": 0, "message": message, "finish_reason": finish}
                    ],
                    "usage": usage,
                },
            )
            return
        self.start_stream()
        base["object"] = "chat.completion.chunk"
        self.event(
            {
                **base,
                "choices": [
                    {"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}
                ],
            }
        )
        for block in blocks:
            if block["type"] == "tool_use":
                delta = {"tool_calls": [{"index": 0, **calls[0]}]}
            else:
                delta = {
                    "content"
                    if block["type"] == "text"
                    else "reasoning_content": block.get("text", block.get("thinking"))
                }
            deltas = [delta]
            if block["type"] != "tool_use":
                field = "content" if block["type"] == "text" else "reasoning_content"
                deltas = [
                    {field: part} for part in self.stream_parts(delta[field], scenario)
                ]
            for delta in deltas:
                self.event(
                    {
                        **base,
                        "choices": [
                            {"index": 0, "delta": delta, "finish_reason": None}
                        ],
                    }
                )
                self.delay(scenario)
        self.event(
            {
                **base,
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
                "usage": usage,
            }
        )
        self.event("[DONE]")

    def respond_responses(self, request, blocks, scenario, items):
        """Emit the Responses API event sequence used by Codex."""
        output = []
        for block in blocks:
            if block["type"] == "tool_use":
                output.append(
                    {
                        "id": "fc_" + uuid4().hex,
                        "type": "function_call",
                        "status": "completed",
                        "call_id": block["id"],
                        "name": block["name"],
                        "arguments": json.dumps(block["input"]),
                    }
                )
            elif block["type"] == "thinking":
                output.append(
                    {
                        "id": "rs_" + uuid4().hex,
                        "type": "reasoning",
                        "summary": [
                            {"type": "summary_text", "text": block["thinking"]}
                        ],
                    }
                )
            else:
                output.append(
                    {
                        "id": "msg_" + uuid4().hex,
                        "type": "message",
                        "status": "completed",
                        "role": "assistant",
                        "content": [
                            {
                                "type": "output_text",
                                "text": block["text"],
                                "annotations": [],
                            }
                        ],
                    }
                )
        response = {
            "id": "resp_" + uuid4().hex,
            "object": "response",
            "created_at": int(time.time()),
            "status": "completed",
            "error": None,
            "incomplete_details": None,
            "model": request.get("model", "mock-model"),
            "output": output,
            "usage": {
                **USAGE,
                "total_tokens": 544,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens_details": {"reasoning_tokens": 0},
            },
            "parallel_tool_calls": False,
        }
        # ponytail: in-memory history lasts for one test-server run; restart between suites.
        with self.server.history_lock:
            self.server.history[response["id"]] = items + output
        if not request.get("stream"):
            self.send_json(200, response)
            return
        self.start_stream()
        sequence = 0

        def send(kind, **fields):
            """Send an ordered Responses event."""
            nonlocal sequence
            self.event({"type": kind, "sequence_number": sequence, **fields}, kind)
            sequence += 1

        pending = {**response, "status": "in_progress", "output": [], "usage": None}
        send("response.created", response=pending)
        send("response.in_progress", response=pending)
        for index, item in enumerate(output):
            kind = item["type"]
            initial = {**item, "status": "in_progress"}
            initial[
                "arguments"
                if kind == "function_call"
                else "summary"
                if kind == "reasoning"
                else "content"
            ] = "" if kind == "function_call" else []
            send("response.output_item.added", output_index=index, item=initial)
            fields = {"item_id": item["id"], "output_index": index}
            if kind == "function_call":
                send(
                    "response.function_call_arguments.delta",
                    **fields,
                    delta=item["arguments"],
                )
                self.delay(scenario)
                send(
                    "response.function_call_arguments.done",
                    **fields,
                    arguments=item["arguments"],
                )
            elif kind == "reasoning":
                fields["summary_index"] = 0
                send(
                    "response.reasoning_summary_part.added",
                    **fields,
                    part={"type": "summary_text", "text": ""},
                )
                for part in self.stream_parts(item["summary"][0]["text"], scenario):
                    send("response.reasoning_summary_text.delta", **fields, delta=part)
                    self.delay(scenario)
                send(
                    "response.reasoning_summary_text.done",
                    **fields,
                    text=item["summary"][0]["text"],
                )
                send(
                    "response.reasoning_summary_part.done",
                    **fields,
                    part=item["summary"][0],
                )
            else:
                fields["content_index"] = 0
                send(
                    "response.content_part.added",
                    **fields,
                    part={"type": "output_text", "text": "", "annotations": []},
                )
                for part in self.stream_parts(item["content"][0]["text"], scenario):
                    send("response.output_text.delta", **fields, delta=part)
                    self.delay(scenario)
                send(
                    "response.output_text.done",
                    **fields,
                    text=item["content"][0]["text"],
                )
                send("response.content_part.done", **fields, part=item["content"][0])
            send("response.output_item.done", output_index=index, item=item)
        send("response.completed", response=response)


def make_server(host="127.0.0.1", port=0, delay=1.5):
    """Create an isolated server; port zero selects a free local port."""
    from threading import Lock

    server = ThreadingHTTPServer((host, port), Handler)
    server.history = {}
    server.requests = []
    server.history_lock = Lock()
    server.delay = delay
    return server


def main():
    """Start a loopback HTTP server until interrupted."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    server = make_server(port=args.port)
    print(
        "Mock model listening on http://127.0.0.1:" + str(server.server_port),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
