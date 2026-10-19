"""A stand-in for MemBraince for the hook tests.

Usage: python fake_server.py <folder>

It listens on a free port, writes the port number to <folder>/port, and exits
once <folder> is deleted, so a test run never leaves it behind.

Every prompt a save uploads is appended to <folder>/uploaded.txt, one per line,
with the API key that sent it. While <folder>/fail exists, saves answer 500.
Recall routes answer with a fixed line so tests can see recall output.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

folder = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8")
        if not self.path.endswith("/transcript"):
            self.reply(200, b"Memories from MemBraince: (test)")
            return
        time.sleep(0.2)
        if os.path.exists(os.path.join(folder, "fail")):
            self.reply(500, b"")
            return
        with open(os.path.join(folder, "uploaded.txt"), "a", encoding="utf-8", newline="\n") as log:
            for line in body.splitlines():
                log.write(self.headers.get("X-API-Key", "") + " " + json.loads(line)["hook"]["prompt"] + "\n")
        self.reply(200, b'{"saved": 1}')

    def reply(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
# Written under a temporary name and renamed, so a test never reads half a number.
with open(os.path.join(folder, "port.tmp"), "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
os.replace(os.path.join(folder, "port.tmp"), os.path.join(folder, "port"))


def stop_when_folder_is_gone():
    while os.path.isdir(folder):
        time.sleep(1)
    server.shutdown()


threading.Thread(target=stop_when_folder_is_gone, daemon=True).start()
server.serve_forever()
