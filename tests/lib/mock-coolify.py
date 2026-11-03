"""Fake Coolify + GitHub API for deploy-coolify tests.

Usage: python3 mock-coolify.py <port> <scenario> <tested-sha> <request-log> <coolify-token>
Serves:
  GET  /repos/<owner>/<repo>/git/ref/heads/<branch>   (GitHub API)
  POST /api/v1/deploy?uuid=app-uuid&force=false        (Coolify; 400 on any other query)
  GET  /api/v1/deployments/<uuid>                      (Coolify)
  GET  /health                                         (the deployed application)
Coolify routes answer 401 unless `Authorization: Bearer <coolify-token>` is sent.
Every request line is appended to <request-log>.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, SCENARIO, SHA, LOG, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
OTHER_SHA = "f" * 40
polls = {"n": 0, "health": 0}

DEPLOY_ERRORS = {"deploy-401": 401, "deploy-403": 403, "deploy-404": 404, "deploy-500": 500, "queue-full": 429}
# Statuses reported before the terminal one, per scenario (one per poll).
INTERMEDIATE = {"queued": ["queued", "in_progress"]}


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

    def authorized(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_GET(self):
        self.record()
        if self.path.startswith("/repos/"):
            return self.github_head()
        if self.path.startswith("/api/v1/deployments/"):
            if not self.authorized():
                return self.reply(401, {"message": "Unauthenticated."})
            return self.deployment_status()
        if self.path.startswith("/health"):
            return self.health()
        self.reply(404, {"message": "unknown path"})

    def do_POST(self):
        self.record()
        if self.path.startswith("/api/v1/deploy"):
            if not self.authorized():
                return self.reply(401, {"message": "Unauthenticated."})
            if self.path != "/api/v1/deploy?uuid=app-uuid&force=false":
                return self.reply(400, {"message": f"unexpected query: {self.path}"})
            return self.deploy()
        self.reply(404, {"message": "unknown path"})

    def github_head(self):
        if SCENARIO == "head-unreadable":
            return self.reply(404, {"message": "Not Found"})
        head = OTHER_SHA if SCENARIO == "stale" else SHA
        return self.reply(200, {"object": {"sha": head}})

    def deploy(self):
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

    def deployment_status(self):
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
        before = INTERMEDIATE.get(SCENARIO, ["in_progress"])
        if SCENARIO == "timeout" or polls["n"] <= len(before):
            return self.reply(200, {"status": before[min(polls["n"], len(before)) - 1], "commit": "HEAD"})
        final = {
            "failed": ("failed", SHA),
            "cancelled": ("cancelled-by-user", SHA),
            "commit-mismatch": ("finished", OTHER_SHA),
        }.get(SCENARIO, ("finished", SHA))
        return self.reply(200, {"status": final[0], "commit": final[1]})

    def health(self):
        polls["health"] += 1
        if SCENARIO == "health-503":
            return self.reply(503, "starting")
        if SCENARIO == "health-late" and polls["health"] <= 2:
            return self.reply(503, "starting")
        if SCENARIO == "health-body":
            return self.reply(200, "ok")
        return self.reply(200, f"ok {SHA}")


class Server(HTTPServer):
    allow_reuse_address = True


Server(("127.0.0.1", PORT), Handler).serve_forever()
