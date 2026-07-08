#!/usr/bin/env python3
import json
import sys
import time


def compact(value):
    return json.dumps(value, separators=(",", ":"))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fake_codex_silent_app_server.py TRACE_PATH")

    trace_path = sys.argv[1]

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
            elif method == "thread/start":
                send({"id": request_id, "result": {"thread": {"id": "thread-1"}}})
            elif method == "turn/start":
                send({"id": request_id, "result": {"turn": {"id": "silent-turn"}}})
                while True:
                    time.sleep(1)
            else:
                send({
                    "id": request_id,
                    "error": {"code": -32601, "message": f"unknown method: {method}"},
                })


if __name__ == "__main__":
    main()
