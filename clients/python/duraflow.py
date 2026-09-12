"""Tiny synchronous stdio client. Only ctx.step callbacks are checkpointed."""
import contextlib
import json
import sys


class Context:
    def __init__(self):
        self._reader = sys.stdin
        self._writer = sys.stdout
        self._seen = set()
        self._active = False
        hello = self._receive()
        if hello["type"] != "hello":
            raise RuntimeError("Expected engine hello")
        self.run_id = hello["run_id"]
        self.inputs = hello["inputs"]
        self.created_at = hello["created_at"]

    def _send(self, kind, **fields):
        line = json.dumps({"v": 1, "type": kind, **fields}, allow_nan=False)
        self._writer.write(line + "\n")
        self._writer.flush()

    def _receive(self):
        line = self._reader.readline()
        if not line:
            raise RuntimeError("Engine closed the protocol pipe; inspect the run error")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("Invalid JSON from the engine") from error
        if message.get("v") != 1:
            raise RuntimeError("Unsupported engine protocol version")
        return message

    def step(self, name, action):
        if self._active or not isinstance(name, str) or not name or name in self._seen:
            raise ValueError("Steps must be sequential, non-nested, and uniquely named")
        self._seen.add(name)
        self._send("begin_step", name=name)
        response = self._receive()
        if response["type"] == "saved":
            print(f"[duraflow] reuse {name}", file=sys.stderr)
            return response["result"]
        if response["type"] != "execute":
            raise RuntimeError(f"Unexpected engine response: {response}")
        print(f"[duraflow] execute {name}, attempt {response['attempt']}", file=sys.stderr)
        self._active = True
        try:
            result = action()
            json.dumps(result, allow_nan=False)  # validate BEFORE completing the step
        except Exception as error:
            self._send("fail_step", name=name, error=str(error))
            raise
        finally:
            self._active = False
        self._send("complete_step", name=name, result=result)
        response = self._receive()
        if response["type"] != "committed":
            raise RuntimeError("Engine did not acknowledge the durable checkpoint")
        # Return the engine's JSON representation, just as replay does (rather
        # than, for example, a Python tuple that becomes a list on recovery).
        return response["result"]


def run(workflow):
    ctx = Context()
    # Normal Python print() calls must not corrupt protocol stdout. Child
    # processes still need captured stdout or explicit stderr redirection.
    with contextlib.redirect_stdout(sys.stderr):
        result = workflow(ctx)
    ctx._send("finish", result=result)  # one-way; exit so the engine can finalize
