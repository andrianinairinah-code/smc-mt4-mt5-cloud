import os, subprocess, glob, json, sys
import socketserver
import http.server
import urllib.parse

PORT = int(os.environ.get("PORT", 5000))
WINEPREFIX = os.environ.get("WINEPREFIX", os.path.expanduser("~/.wine"))

MT5_EXPERTS = os.path.join(WINEPREFIX, "drive_c", "Program Files", "MetaTrader 5", "MQL5", "Experts")
MT5_INCLUDES = os.path.join(WINEPREFIX, "drive_c", "Program Files", "MetaTrader 5", "MQL5", "Include")
MT4_EXPERTS = os.path.join(WINEPREFIX, "drive_c", "Program Files", "HFM MT4", "MQL4", "Experts")
MT4_INCLUDES = os.path.join(WINEPREFIX, "drive_c", "Program Files", "HFM MT4", "MQL4", "Include")

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    os.makedirs(os.path.join(path, "SMC"), exist_ok=True)

def json_resp(data, status=200):
    body = json.dumps(data).encode()
    return (status, {'Content-Type': 'application/json'}, body)

def json_error(msg, status=400):
    return json_resp({"error": msg}, status)

class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self, status, headers, body):
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path.rstrip('/') or '/'
        try:
            if path == '/status':
                mt5 = mt4 = False
                try:
                    ps = subprocess.run(["ps", "aux"], capture_output=True, text=True)
                    mt5 = "terminal64" in ps.stdout.lower()
                    mt4 = "terminal.exe" in ps.stdout.lower()
                except: pass
                r = json_resp({"mt5_running": mt5, "mt4_running": mt4, "status": "ok"})
            elif path == '/files/ea':
                ensure_dir(MT5_EXPERTS)
                ensure_dir(MT4_EXPERTS)
                m5 = [os.path.basename(f) for f in glob.glob(os.path.join(MT5_EXPERTS, "*.ex5")) + glob.glob(os.path.join(MT5_EXPERTS, "*.mq5"))]
                m4 = [os.path.basename(f) for f in glob.glob(os.path.join(MT4_EXPERTS, "*.ex4")) + glob.glob(os.path.join(MT4_EXPERTS, "*.mq4"))]
                r = json_resp({"mt5": m5, "mt4": m4})
            else:
                r = json_error("Not found", 404)
        except Exception as e:
            r = json_error(str(e), 500)
        self.respond(*r)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path.rstrip('/') or '/'
        ct = self.headers.get('Content-Type', '')
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length > 0 else b''
        try:
            if path == '/restart/mt5':
                subprocess.run(["pkill", "-f", "terminal64"], check=False)
                subprocess.run(["pkill", "-f", "metaeditor"], check=False)
                subprocess.run(["wine", "C:\\Program Files\\MetaTrader 5\\terminal64.exe"], check=False)
                r = json_resp({"status": "restarted", "target": "MT5"})
            elif path == '/restart/mt4':
                subprocess.run(["pkill", "-f", "terminal.exe"], check=False)
                subprocess.run(["wine", "C:\\Program Files\\HFM MT4\\terminal.exe"], check=False)
                r = json_resp({"status": "restarted", "target": "MT4"})
            elif path == '/git-pull':
                data = json.loads(body) if body else {}
                repo = data.get("repo", "")
                if not repo:
                    r = json_error("repo URL required")
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
                    r = json_resp({"status": "ok", "synced_from": repo})
            else:
                # File uploads - parse multipart manually
                if 'multipart/form-data' in ct:
                    boundary = ct.split('boundary=')[-1].strip()
                    parts = body.split(b'--' + boundary.encode())
                    file_data = {}
                    for part in parts:
                        if b'Content-Disposition' in part:
                            h, _, content = part.partition(b'\r\n\r\n')
                            disp = h.decode('utf-8', errors='replace')
                            name = ''
                            fn = ''
                            if 'name="' in disp:
                                name = disp.split('name="')[1].split('"')[0]
                            if 'filename="' in disp:
                                fn = disp.split('filename="')[1].split('"')[0]
                            if fn:
                                dest_dir = MT5_EXPERTS if '/ea4' not in path else MT4_EXPERTS
                                if '/ea' in path:
                                    ensure_dir(dest_dir)
                                    with open(os.path.join(dest_dir, fn), 'wb') as f:
                                        f.write(content.rstrip(b'\r\n'))
                                    file_data['ea'] = fn
                                elif '/include' in path:
                                    for d in [os.path.join(MT5_INCLUDES, "SMC"), os.path.join(MT4_INCLUDES, "SMC")]:
                                        os.makedirs(d, exist_ok=True)
                                        with open(os.path.join(d, fn), 'wb') as f:
                                            f.write(content.rstrip(b'\r\n'))
                                    file_data.setdefault('includes', []).append(fn)
                    r = json_resp(file_data)
                else:
                    r = json_error("Unsupported Content-Type", 415)
        except Exception as e:
            r = json_error(str(e), 500)
        self.respond(*r)

    def do_OPTIONS(self):
        self.respond(200, {'Content-Length': '0'}, b'')

    def log_message(self, fmt, *args):
        pass

if __name__ == '__main__':
    try:
        srv = socketserver.ThreadingTCPServer(('0.0.0.0', PORT), Handler)
        srv.allow_reuse_address = True
        srv.serve_forever()
    except Exception as e:
        print(f"FATAL: {e}", flush=True)
        sys.exit(1)
