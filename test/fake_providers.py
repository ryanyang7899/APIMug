#!/usr/bin/env python3
"""本地假服务器：模拟 OpenRouter / Kimi / SiliconFlow / StepFun / DeepInfra 的余额接口（离线自测用）。"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8788

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = None
        if self.path.startswith('/api/v1/key'):
            # OpenRouter: GET /api/v1/key
            body = json.dumps({"data": {
                "label": "test-key", "limit": 100.0, "limit_remaining": 42.5,
                "usage": 57.5, "usage_daily": 3.2, "usage_weekly": 12.4,
                "usage_monthly": 30.1, "is_free_tier": False
            }}).encode()
        elif self.path.startswith('/v1/users/me/balance'):
            # Kimi: GET /v1/users/me/balance
            body = json.dumps({"code": 0, "data": {
                "available_balance": 88.66, "voucher_balance": 10.0, "cash_balance": 78.66
            }, "scode": "0", "status": True}).encode()
        elif self.path.startswith('/v1/user/info'):
            # SiliconFlow: GET /v1/user/info
            body = json.dumps({"code": 20000, "message": "Success", "data": {
                "id": "1", "email": "t@t.com", "balance": 15.0,
                "chargeBalance": 20.0, "totalBalance": 35.0, "status": "active"
            }, "metadata": {}}).encode()
        elif self.path.startswith('/v1/accounts'):
            # StepFun: GET /v1/accounts
            body = json.dumps({
                "object": "account", "type": "prepaid",
                "balance": 123.45, "total_cash_balance": 200.0, "total_voucher_balance": 0.0
            }).encode()
        elif self.path.startswith('/payment/checklist'):
            # DeepInfra: GET /payment/checklist?compute_owed=true
            body = json.dumps({
                "stripe_balance": -66.6, "recent": 5.5, "limit": 200.0,
                "suspended": False, "suspend_reason": None
            }).encode()
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
    print(f"fake providers listening on 127.0.0.1:{PORT}")
    HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
