"""Fake Coolify + GitHub API for deploy-coolify tests.

Usage: python3 mock-coolify.py <port> <scenario> <tested-sha> <request-log>
Serves:
  GET  /repos/<owner>/<repo>/git/ref/heads/<branch>   (GitHub API)
  POST /api/v1/deploy?uuid=...                         (Coolify)
  GET  /api/v1/deployments/<uuid>                      (Coolify)
Every request line is appended to <request-log>.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, SCENARIO, SHA, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
OTHER_SHA = "f" * 40
polls = {"n": 0}

DEPLOY_ERRORS = {"deploy-401": 401, "deploy-403": 403, "deploy-404": 404, "deploy-500": 500, "queue-full": 429}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload):
        body = payload if isinstance(payload, str) else json.dumps(payload)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def record(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def do_GET(self):
        self.record()
        if self.path.startswith("/repos/"):
            if SCENARIO == "head-unreadable":
                return self.reply(404, {"message": "Not Found"})
            head = OTHER_SHA if SCENARIO == "stale" else SHA
            return self.reply(200, {"object": {"sha": head}})
        if self.path.startswith("/api/v1/deployments/"):
            polls["n"] += 1
            if SCENARIO == "already-queued":
                return self.reply(404, {"message": "Deployment not found."})
            if SCENARIO == "poll-hang":
                time.sleep(60)
            if SCENARIO == "poll-403":
                return self.reply(403, {"message": "Missing required permissions: read"})
            if SCENARIO == "poll-500":
                return self.reply(500, {"message": "boom"})
            if SCENARIO == "poll-garbage":
                return self.reply(200, "<html>not json</html>")
            if SCENARIO == "timeout" or polls["n"] == 1:
                return self.reply(200, {"status": "in_progress", "commit": "HEAD"})
            final = {
                "failed": ("failed", SHA),
                "cancelled": ("cancelled-by-user", SHA),
                "commit-mismatch": ("finished", OTHER_SHA),
            }.get(SCENARIO, ("finished", SHA))
            return self.reply(200, {"status": final[0], "commit": final[1]})
        self.reply(404, {"message": "unknown path"})

    def do_POST(self):
        self.record()
        if self.path.startswith("/api/v1/deploy"):
            if SCENARIO in DEPLOY_ERRORS:
                return self.reply(DEPLOY_ERRORS[SCENARIO], {"message": SCENARIO})
            if SCENARIO == "already-queued":
                return self.reply(200, {"deployments": [{
                    "message": "Deployment already queued for this commit.",
                    "resource_uuid": "app-uuid",
                    "deployment_uuid": "orphan-456",
                }]})
            if SCENARIO == "no-uuid":
                return self.reply(200, {"deployments": []})
            return self.reply(200, {"deployments": [{
                "message": "Application deployment queued.",
                "resource_uuid": "app-uuid",
                "deployment_uuid": "dep-123",
            }]})
        self.reply(404, {"message": "unknown path"})


class Server(HTTPServer):
    allow_reuse_address = True


Server(("127.0.0.1", PORT), Handler).serve_forever()
