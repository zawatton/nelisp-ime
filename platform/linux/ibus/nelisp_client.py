"""NeLisp REPL protocol client shared by the IBus adapter and its smoke test."""
import json
import os
import pathlib
import subprocess


class NeLispClient:
    def __init__(self):
        runtime = os.environ.get("NELISP_IME_RUNTIME", "/usr/libexec/nelisp-ime/nelisp")
        root = os.environ.get("NELISP_IME_ROOT", "/usr/share/nelisp-ime/nelisp-root")
        self.process = subprocess.Popen(
            [runtime, "--repl", "--no-prompt", "--no-print"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            encoding="utf-8", bufsize=1)
        files = ("packages/nelisp-json/src/nelisp-json.el",
                 "packages/nelisp-ime/src/nelisp-ime-input.el",
                 "packages/nelisp-ime/src/nelisp-ime.el",
                 "packages/nelisp-ime-lattice/src/nelisp-ime-lattice.el",
                 "packages/nelisp-ime-lattice/data/nelisp-ime-dictionary-data.el",
                 "packages/nelisp-ime/src/nelisp-ime-protocol.el")
        form = "(progn " + " ".join(
            "(load %s)" % json.dumps(os.path.join(root, item), ensure_ascii=False)
            for item in files) + ' (princ "ready\\n"))'
        self._line(form)
        if self.process.stdout.readline().rstrip("\n") != "ready":
            raise RuntimeError("NeLisp IME bootstrap failed")
        self.request("ime/initialize", {"protocolVersion": 1})
        self.learning_path = pathlib.Path(
            os.environ.get("XDG_DATA_HOME", pathlib.Path.home() / ".local/share")
        ) / "nelisp-ime/learning.json"
        self._load_learning()

    def _line(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        request = json.dumps({"jsonrpc": "2.0", "id": 1,
                              "method": method, "params": params},
                             ensure_ascii=False, separators=(",", ":"))
        form = '(princ (concat (nelisp-ime-protocol-handle-json %s) "\\n"))' % json.dumps(request, ensure_ascii=False)
        self._line(form)
        response = json.loads(self.process.stdout.readline())
        if "error" in response:
            raise RuntimeError(response["error"]["message"])
        return response["result"]

    def _load_learning(self):
        try:
            rows = json.loads(self.learning_path.read_text(encoding="utf-8"))
            self.request("ime/learning.import", {"rows": rows})
        except FileNotFoundError:
            pass

    def save_learning(self):
        rows = self.request("ime/learning.export", {})["rows"]
        self.learning_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.learning_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
        temporary.replace(self.learning_path)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=2)
