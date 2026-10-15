"""Deterministic JSONL app-server used by the AI integration tests."""
import json
import sys
import threading

scenario = sys.argv[1]
lock = threading.Lock()
turns = 0


def send(message):
    encoded = json.dumps(message) + "\n"
    with lock:
        # Exercise the client's buffering across partial JSONL reads.
        midpoint = len(encoded) // 2
        sys.stdout.write(encoded[:midpoint])
        sys.stdout.flush()
        sys.stdout.write(encoded[midpoint:])
        sys.stdout.flush()


def respond(request, result):
    send({"id": request["id"], "result": result})


def complete(thread_id, turn_id, payload):
    summaries = [
        {
            "id": change["id"],
            "what": "Change %s in %s. This explains its effect." % (change["id"], payload["file"]),
            "why": "Purpose of change %s in %s. This explains the broader goal." % (change["id"], payload["file"]),
        }
        for change in payload["changes"]
    ]
    text = "invalid JSON" if scenario == "invalid" else json.dumps({"summaries": summaries})
    send({"method": "item/completed", "params": {"threadId": thread_id, "item": {"type": "agentMessage", "text": text}}})
    turn = {"id": turn_id, "status": "completed", "items": []}
    if scenario in ("failed", "slow_failed"):
        turn.update(status="failed", error={"message": "Usage limit reached"})
    send({"method": "turn/completed", "params": {"threadId": thread_id, "turn": turn}})


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if "id" not in request:
        continue
    if method == "initialize":
        respond(request, {"userAgent": "fake-codex"})
    elif method == "account/read":
        respond(request, {"account": None if scenario == "logged_out" else {"type": "chatgpt", "planType": "plus"}})
    elif method == "account/login/start":
        respond(request, {"type": "chatgpt", "loginId": "login-1", "authUrl": "https://example.invalid/sign-in"})
        send({"method": "account/login/completed", "params": {"loginId": "login-1", "success": True, "error": None}})
    elif method == "config/read":
        respond(request, {"config": {"mcp_servers": {"test_server": {"enabled": True}}}})
    elif method == "thread/start":
        params = request["params"]
        assert params["ephemeral"] is True
        assert params["sandbox"] == "read-only"
        assert params["config"]["mcp_servers"]["test_server"]["enabled"] is False
        assert params["config"]["features"]["shell_tool"] is False
        assert params["config"]["features"]["multi_agent"] is False
        assert params["config"]["features"]["plugins"] is False
        respond(request, {"thread": {"id": "thread-" + str(request["id"])}})
    elif method == "turn/start":
        if scenario == "crash":
            sys.exit(7)
        turns += 1
        params = request["params"]
        schema = params["outputSchema"]["properties"]["summaries"]["items"]
        assert schema["required"] == ["id", "what", "why"]
        payload = json.loads(params["input"][0]["text"].split("\n\n", 1)[1])
        turn_id = "turn-" + str(turns)
        respond(request, {"turn": {"id": turn_id, "status": "inProgress"}})
        if scenario != "hang":
            delay = 0.35 if scenario in ("slow", "slow_failed") else 0.01
            timer = threading.Timer(delay, complete, (params["threadId"], turn_id, payload))
            timer.daemon = True
            timer.start()
    elif method == "test/stats":
        respond(request, {"turns": turns})
    else:
        respond(request, {})
