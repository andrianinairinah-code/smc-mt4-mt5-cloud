import http.server
import json
import os

PORT = int(os.environ.get("PORT", 5000))

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok", "msg": "Python stdlib works"}).encode())
    def do_POST(self):
        self.do_GET()
    def do_OPTIONS(self):
        self.do_GET()
    def log_message(self, *a): pass

s = http.server.HTTPServer(('0.0.0.0', PORT), H)
s.serve_forever()
