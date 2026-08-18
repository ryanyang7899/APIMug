#!/usr/bin/env python3
"""本地假 NewAPI 服务：验证 newapi 协议的解析逻辑（离线自测用）。"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import time
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/v1/dashboard/billing/subscription'):
            body = json.dumps({"object": "billing_subscription", "hard_limit_usd": 500,
                               "soft_limit_usd": 0, "system_hard_limit_usd": 100,
                               "system_soft_limit_usd": 0, "access_until": int(time.time()) + 86400}).encode()
        elif self.path.startswith('/v1/dashboard/billing/usage'):
            body = json.dumps({"object": "list", "total_usage": 12345.0, "daily_costs": []}).encode()
        elif self.path.startswith('/user/balance'):
            body = json.dumps({"is_available": True, "balance_infos": [
                {"currency": "CNY", "total_balance": "65.28",
                 "granted_balance": "0.00", "topped_up_balance": "65.28"}]}).encode()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    print(f"fake newapi listening on 127.0.0.1:{PORT}")
    HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
