#!/usr/bin/env python3
import json
import sys


def compact(value):
    return json.dumps(value, separators=(",", ":"))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fake_codex_app_server.py TRACE_PATH")

    trace_path = sys.argv[1]
    turn_count = 0

    with open(trace_path, "a", encoding="utf-8") as trace:
        trace.write("START\n")
        trace.flush()

        def send(payload):
            sys.stdout.write(compact(payload) + "\n")
            sys.stdout.flush()

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
            elif method == "model/list":
                send({
                    "id": request_id,
                    "result": {
                        "data": [{
                            "id": "gpt-5.5",
                            "model": "gpt-5.5",
                            "displayName": "GPT-5.5",
                            "hidden": False,
                            "defaultReasoningEffort": "medium",
                            "supportedReasoningEfforts": [
                                {"reasoningEffort": "low", "description": "Lower latency"},
                                {"reasoningEffort": "medium", "description": "Balanced"},
                                {"reasoningEffort": "xhigh", "description": "Deep reasoning"},
                            ],
                            "inputModalities": ["text", "image"],
                            "supportsPersonality": True,
                            "isDefault": True,
                        }],
                        "nextCursor": None,
                    },
                })
            elif method == "thread/start":
                send({"id": request_id, "result": {"thread": {"id": "thread-1"}}})
            elif method == "turn/start":
                turn_count += 1
                turn_id = f"turn-{turn_count}"
                send({"id": request_id, "result": {"turn": {"id": turn_id}}})
                send({
                    "method": "item/agentMessage/delta",
                    "params": {"delta": f"response-{turn_count}"},
                })
                send({
                    "method": "turn/completed",
                    "params": {"turn": {"id": turn_id, "status": "completed"}},
                })
            else:
                send({
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unknown method: {method}"},
                })


if __name__ == "__main__":
    main()
