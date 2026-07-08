#!/usr/bin/env python3
import json
import sys


def compact(value):
    return json.dumps(value, separators=(",", ":"))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fake_codex_tool_app_server.py TRACE_PATH")

    trace_path = sys.argv[1]
    current_turn_id = "tool-turn"

    with open(trace_path, "a", encoding="utf-8") as trace:
        trace.write("START\n")
        trace.flush()

        def send(payload):
            sys.stdout.write(compact(payload) + "\n")
            sys.stdout.flush()

        def complete_with(output):
            send({
                "method": "item/agentMessage/delta",
                "params": {"delta": f"tool-output={output}"},
            })
            send({
                "method": "turn/completed",
                "params": {"turn": {"id": current_turn_id, "status": "completed"}},
            })

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            trace.write("JSON:" + line + "\n")
            trace.flush()

            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")

            if method == "initialize":
                send({"id": request_id, "result": {}})
            elif method == "initialized":
                continue
            elif method == "thread/start":
                send({"id": request_id, "result": {"thread": {"id": "thread-1"}}})
            elif method == "turn/start":
                send({"id": request_id, "result": {"turn": {"id": current_turn_id}}})
                send({
                    "id": 99,
                    "method": "item/tool/call",
                    "params": {
                        "tool": "lean_echo",
                        "arguments": {"text": "hello"},
                    },
                })
            elif request_id == 99:
                result = message.get("result", {})
                output = result.get("output", "")
                complete_with(output)
            else:
                send({
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unknown method: {method}"},
                })


if __name__ == "__main__":
    main()
