import os, subprocess, glob, json, sys, urllib.parse, socketserver, http.server, threading, logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger('api')

WINEPREFIX = os.environ.get("WINEPREFIX", os.path.expanduser("~/.wine"))
PORT = int(os.environ.get("PORT", 5000))

MT5_EXPERTS = os.path.join(WINEPREFIX, "drive_c", "Program Files", "MetaTrader 5", "MQL5", "Experts")
MT5_INCLUDES = os.path.join(WINEPREFIX, "drive_c", "Program Files", "MetaTrader 5", "MQL5", "Include")
MT4_EXPERTS = os.path.join(WINEPREFIX, "drive_c", "Program Files", "HFM MT4", "MQL4", "Experts")
MT4_INCLUDES = os.path.join(WINEPREFIX, "drive_c", "Program Files", "HFM MT4", "MQL4", "Include")

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    os.makedirs(os.path.join(path, "SMC"), exist_ok=True)

def json_resp(data, status=200):
    body = json.dumps(data).encode()
    return status, {'Content-Type': 'application/json'}, body

def json_error(msg, status=400):
    return json_resp({"error": msg}, status)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip('/') or '/'
        try:
            if path == '/status':
                mt5 = mt4 = False
                try:
                    ps = subprocess.run(["ps", "aux"], capture_output=True, text=True)
                    mt5 = "terminal64" in ps.stdout.lower()
                    mt4 = "terminal.exe" in ps.stdout.lower()
                except: pass
                status, headers, body = json_resp({"mt5_running": mt5, "mt4_running": mt4,
                    "api": "running", "version": "2.0"})
            elif path == '/files/ea':
                ensure_dir(MT5_EXPERTS); ensure_dir(MT4_EXPERTS)
                mt5_files = [os.path.basename(f) for f in glob.glob(os.path.join(MT5_EXPERTS, "*.ex5")) +
                             glob.glob(os.path.join(MT5_EXPERTS, "*.mq5"))]
                mt4_files = [os.path.basename(f) for f in glob.glob(os.path.join(MT4_EXPERTS, "*.ex4")) +
                             glob.glob(os.path.join(MT4_EXPERTS, "*.mq4"))]
                status, headers, body = json_resp({"mt5": mt5_files, "mt4": mt4_files})
            else:
                status, headers, body = json_error("Not found", 404)
        except Exception as e:
            log.error(f"GET {path}: {e}")
            status, headers, body = json_error(str(e), 500)
        self._send(status, headers, body)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip('/') or '/'
        content_len = int(self.headers.get('Content-Length', 0))
        body_raw = self.rfile.read(content_len)
        cont_type = self.headers.get('Content-Type', '')
        try:
            if path in ('/upload/ea', '/upload/ea4'):
                import cgi
                fs = cgi.FieldStorage(fp=self.rfile, headers=self.headers,
                    environ={'REQUEST_METHOD': 'POST', 'CONTENT_TYPE': cont_type})
                file_item = fs['file']
                if not file_item.filename:
                    status, headers, body = json_error("No file provided")
                else:
                    dest = MT5_EXPERTS if '/ea4' not in path else MT4_EXPERTS
                    ensure_dir(dest)
                    with open(os.path.join(dest, file_item.filename), 'wb') as f:
                        f.write(file_item.file.read())
                    status, headers, body = json_resp({"status": "ok", "file": file_item.filename})
            elif path == '/upload/include':
                import cgi
                fs = cgi.FieldStorage(fp=self.rfile, headers=self.headers,
                    environ={'REQUEST_METHOD': 'POST', 'CONTENT_TYPE': cont_type})
                file_item = fs['file']
                if not file_item.filename:
                    status, headers, body = json_error("No file provided")
                else:
                    for d in [os.path.join(MT5_INCLUDES, "SMC"), os.path.join(MT4_INCLUDES, "SMC")]:
                        os.makedirs(d, exist_ok=True)
                        with open(os.path.join(d, file_item.filename), 'wb') as f:
                            f.write(file_item.file.read())
                    status, headers, body = json_resp({"status": "ok", "file": file_item.filename})
            elif path == '/restart/mt5':
                subprocess.run(["pkill", "-f", "terminal64"], check=False)
                subprocess.run(["pkill", "-f", "metaeditor"], check=False)
                subprocess.run(["wine", "C:\\Program Files\\MetaTrader 5\\terminal64.exe"], check=False)
                status, headers, body = json_resp({"status": "restarted", "target": "MT5"})
            elif path == '/restart/mt4':
                subprocess.run(["pkill", "-f", "terminal.exe"], check=False)
                subprocess.run(["wine", "C:\\Program Files\\HFM MT4\\terminal.exe"], check=False)
                status, headers, body = json_resp({"status": "restarted", "target": "MT4"})
            elif path == '/git-pull':
                try:
                    data = json.loads(body_raw) if body_raw else {}
                    repo = data.get("repo", "")
                    if not repo:
                        status, headers, body = json_error("repo URL required")
                    else:
                        dest = data.get("dest", "/tmp/smc-update")
                        if os.path.exists(dest):
                            subprocess.run(["git", "-C", dest, "pull"], check=True)
                        else:
                            subprocess.run(["git", "clone", repo, dest], check=True)
                        for f in glob.glob(os.path.join(dest, "*.ex5")) + glob.glob(os.path.join(dest, "*.mq5")):
                            with open(f, "rb") as src:
                                with open(os.path.join(MT5_EXPERTS, os.path.basename(f)), "wb") as dst:
                                    dst.write(src.read())
                        status, headers, body = json_resp({"status": "ok", "synced_from": repo})
                except Exception as e:
                    status, headers, body = json_error(str(e), 500)
            else:
                status, headers, body = json_error("Not found", 404)
        except Exception as e:
            log.error(f"POST {path}: {e}")
            status, headers, body = json_error(str(e), 500)
        self._send(status, headers, body)

    def _send(self, status, headers, body):
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(200, {'Content-Length': '0'}, b'')

    def log_message(self, format, *args):
        log.info(f"{self.client_address[0]} {format % args}")

if __name__ == '__main__':
    server = socketserver.ThreadingTCPServer(('0.0.0.0', PORT), Handler)
    server.allow_reuse_address = True
    log.info(f"API server listening on 0.0.0.0:{PORT}")
    server.serve_forever()
