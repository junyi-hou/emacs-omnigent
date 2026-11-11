"""Check mock scenarios over real HTTP connections with only the stdlib."""

import json
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import SCENARIOS, TEXT, THOUGHT, make_server

TOOLS = [
    {
        "type": "function",
        "name": "exec_command",
        "description": "Run a command",
        "parameters": {
            "type": "object",
            "properties": {"cmd": {"type": "string"}},
            "required": ["cmd"],
        },
    }
]
PATHS = ("/v1/messages", "/v1/chat/completions", "/v1/responses")


class ServerTest(unittest.TestCase):
    """Exercise all scenarios and both streaming and JSON responses."""

    @classmethod
    def setUpClass(cls):
        """Start an isolated loopback server."""
        cls.server = make_server(delay=0.02)
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.start()
        cls.url = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        """Close all server resources."""
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def post(self, path, scenario="agent_message", stream=False, **extra):
        """Send a model request and return its JSON body or SSE events."""
        request = {
            "model": "mock-model",
            "stream": stream,
            "max_tokens": 1024,
            "input" if path.endswith("responses") else "messages": [
                {"role": "user", "content": "test " + scenario}
            ],
            "tools": TOOLS,
            **extra,
        }
        with urlopen(
            Request(
                self.url + path,
                json.dumps(request).encode(),
                {"Content-Type": "application/json"},
            ),
            timeout=5,
        ) as response:
            body = response.read().decode()
        if stream:
            return [
                json.loads(line[6:])
                for line in body.splitlines()
                if line.startswith("data: ") and line != "data: [DONE]"
            ]
        return json.loads(body)

    def test_all_scenarios(self):
        """Every named scenario works in each protocol and response mode."""
        names = list(SCENARIOS) + [
            "all",
            "fs_read",
            "fs_write",
            "request_permission",
            "model",
            "permission",
            "reasoning",
            "long_running",
        ]
        for path in PATHS:
            for stream in (False, True):
                for name in names:
                    with self.subTest(path=path, stream=stream, name=name):
                        result = self.post(path, name, stream)
                        self.assertTrue(result)
                        if stream:
                            if path.endswith("messages"):
                                self.assertEqual(result[-1]["type"], "message_stop")
                            elif path.endswith("responses"):
                                self.assertEqual(
                                    result[-1]["type"], "response.completed"
                                )
                                self.assertEqual(
                                    [e["sequence_number"] for e in result],
                                    list(range(len(result))),
                                )
                            else:
                                self.assertEqual(
                                    result[-1]["choices"][0]["finish_reason"],
                                    "tool_calls"
                                    if any(
                                        "tool_calls" in e["choices"][0].get("delta", {})
                                        for e in result
                                    )
                                    else "stop",
                                )
                        elif name == "agent_message":
                            self.assertIn(TEXT, json.dumps(result))

    def test_long_running_deltas(self):
        """Each API streams three deltas per block, not three complete messages."""
        events = self.post(PATHS[0], "long_running", True)
        starts = [event for event in events if event["type"] == "content_block_start"]
        self.assertEqual(len(starts), 2)
        for index, field, text in ((0, "thinking", THOUGHT), (1, "text", TEXT)):
            parts = [
                event["delta"][field]
                for event in events
                if event["type"] == "content_block_delta"
                and event["index"] == index
                and field in event["delta"]
            ]
            self.assertEqual(parts, [text] * 3)
        events = self.post(PATHS[2], "long_running", True)
        self.assertEqual(len(events[-1]["response"]["output"]), 2)
        for kind, text in (
            ("response.reasoning_summary_text.delta", THOUGHT),
            ("response.output_text.delta", TEXT),
        ):
            self.assertEqual(
                [event["delta"] for event in events if event["type"] == kind],
                [text] * 3,
            )
        events = self.post(PATHS[1], "long_running", True)
        for field, text in (("reasoning_content", THOUGHT), ("content", TEXT)):
            self.assertEqual(
                [
                    event["choices"][0]["delta"][field]
                    for event in events
                    if field in event["choices"][0]["delta"]
                ],
                [text] * 3,
            )

    def test_tool_continuation(self):
        """Tool results end single-tool scenarios without a repeated call."""
        message = self.post(PATHS[0], "tool_call")
        call = message["content"][0]
        result = self.post(
            PATHS[0],
            messages=[
                {"role": "user", "content": "test tool_call"},
                {"role": "assistant", "content": [call]},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": call["id"],
                            "content": "Permission denied",
                            "is_error": True,
                        }
                    ],
                },
            ],
        )
        self.assertEqual(result["stop_reason"], "end_turn")
        chat = self.post(PATHS[1], "tool_call")
        result = self.post(
            PATHS[1],
            messages=[
                {"role": "user", "content": "test tool_call"},
                chat["choices"][0]["message"],
                {
                    "role": "tool",
                    "tool_call_id": chat["choices"][0]["message"]["tool_calls"][0][
                        "id"
                    ],
                    "content": "ok",
                },
            ],
        )
        self.assertEqual(result["choices"][0]["finish_reason"], "stop")
        response = self.post(PATHS[2], "tool_call")
        result = self.post(
            PATHS[2],
            previous_response_id=response["id"],
            input=[
                {
                    "type": "function_call_output",
                    "call_id": response["output"][0]["call_id"],
                    "output": "ok",
                }
            ],
        )
        self.assertEqual(result["output"][0]["type"], "message")

    def test_all_finishes(self):
        """The all scenario advances through tools and terminates."""
        response = self.post(PATHS[2], "all")
        for _ in range(20):
            calls = [
                item for item in response["output"] if item["type"] == "function_call"
            ]
            if not calls:
                break
            response = self.post(
                PATHS[2],
                previous_response_id=response["id"],
                input=[
                    {
                        "type": "function_call_output",
                        "call_id": calls[0]["call_id"],
                        "output": "ok",
                    }
                ],
            )
        else:
            self.fail("all repeated a tool call")

    def test_plan_completion_and_native_tools(self):
        """Plans complete, and Claude tools receive workspace-relative arguments."""
        tools = [
            {"name": name, "input_schema": {"type": "object"}}
            for name in ("Read", "Write", "Bash", "TodoWrite")
        ]
        for scenario, name in (
            ("tool_call_read", "Read"),
            ("tool_call_diff", "Write"),
            ("fs_write", "Write"),
            ("request_permission", "Write"),
        ):
            result = self.post(PATHS[0], scenario, tools=tools)
            call = result["content"][0]
            self.assertEqual(call["name"], name)
            if "file_path" in call["input"]:
                self.assertFalse(call["input"]["file_path"].startswith("/"))
            if scenario == "tool_call_diff":
                self.assertIn('"debug": true', call["input"]["content"])
        result = self.post(
            PATHS[2], "plan", tools=[{"name": "update_plan", "type": "function"}]
        )
        self.assertEqual(result["output"][0]["name"], "update_plan")
        result = self.post(
            PATHS[2],
            previous_response_id=result["id"],
            input=[{"type": "function_call_output", "output": "ok"}],
            tools=[{"name": "update_plan", "type": "function"}],
        )
        plan = json.loads(result["output"][0]["arguments"])["plan"]
        self.assertTrue(all(entry["status"] == "completed" for entry in plan))
        permission = self.post(PATHS[2], "request_permission")
        arguments = json.loads(permission["output"][0]["arguments"])
        self.assertEqual(arguments["sandbox_permissions"], "require_escalated")
        self.assertIn("mock-permission.txt", arguments["cmd"])
        chat = self.post(
            PATHS[1],
            "tool_call",
            tools=[{"type": "function", "function": {"name": "shell_command"}}],
        )
        self.assertEqual(
            chat["choices"][0]["message"]["tool_calls"][0]["function"]["name"],
            "shell_command",
        )
        wrapped = self.post(
            PATHS[0],
            messages=[
                {"role": "user", "content": "test thought"},
                {"role": "assistant", "content": "old reply"},
                {
                    "role": "user",
                    "content": "Model changed.\n<user_query>\ntest agent_message\n</user_query>",
                },
            ],
        )
        self.assertEqual(wrapped["content"][0]["text"], TEXT)

    def test_errors(self):
        """Invalid input and intentional errors return useful HTTP status codes."""
        for path in PATHS:
            for name, status in (
                ("error", 500),
                ("init_error", 500),
                ("auth_error", 401),
            ):
                with self.assertRaises(HTTPError) as error:
                    self.post(path, name)
                self.assertEqual(error.exception.code, status)
        for body in (b"{", b"[]", b'{"messages":[1]}'):
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + PATHS[0], body))
            self.assertEqual(error.exception.code, 400)
        with self.assertRaises(HTTPError) as error:
            self.post(PATHS[2], previous_response_id="missing")
        self.assertEqual(error.exception.code, 400)

    def test_stream_is_live_and_isolated(self):
        """Long-running output starts before completion and does not block peers."""
        request = {
            "model": "mock-model",
            "stream": True,
            "messages": [{"role": "user", "content": "test long_running"}],
        }
        self.server.delay = 1.5
        started = time.monotonic()
        try:
            with urlopen(
                Request(self.url + PATHS[0], json.dumps(request).encode()), timeout=5
            ) as response:
                while True:
                    line = response.readline()
                    self.assertTrue(line, "Stream ended before its first content delta")
                    if b"content_block_delta" in line:
                        break
                self.assertIn(TEXT, json.dumps(self.post(PATHS[0])))
                self.assertLess(time.monotonic() - started, self.server.delay)
            self.assertIn(TEXT, json.dumps(self.post(PATHS[0])))
        finally:
            self.server.delay = 0.02

    def test_recorded_requests(self):
        """Expose the received model and effort without fabricating control state."""
        marker = "recorded-request-check"
        self.post(
            PATHS[0],
            model="claude-opus-4-6",
            output_config={"effort": "high"},
            messages=[{"role": "user", "content": "test model\n" + marker}],
        )
        with urlopen(self.url + "/requests") as response:
            records = [
                item for item in json.load(response) if marker in json.dumps(item)
            ]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["path"], PATHS[0])
        self.assertEqual(records[0]["body"]["model"], "claude-opus-4-6")
        self.assertEqual(records[0]["body"]["output_config"], {"effort": "high"})

    def test_discovery_and_tokens(self):
        """Health, discovery, token count, and query strings work."""
        with urlopen(self.url + "/health") as response:
            self.assertEqual(json.load(response)["status"], "ok")
        with urlopen(self.url + "/v1/models") as response:
            self.assertEqual(len(json.load(response)["data"]), 4)
        self.assertEqual(self.post("/v1/messages/count_tokens"), {"input_tokens": 512})
        self.assertIn(TEXT, json.dumps(self.post("/v1/messages?beta=true")))


if __name__ == "__main__":
    unittest.main()
