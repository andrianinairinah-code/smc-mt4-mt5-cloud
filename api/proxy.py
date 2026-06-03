import http.server, socketserver, json, os, sys, signal, socket, select, urllib.request

PORT = int(os.environ.get("PROXY_PORT", 6901))
API_PORT = int(os.environ.get("API_PORT", 8080))
NOVNC_PORT = int(os.environ.get("NOVNC_PORT", 6080))

running = True
api_ready = False
novnc_ready = False

def check_backends():
    global api_ready, novnc_ready
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect(('127.0.0.1', API_PORT))
        api_ready = True
    except: api_ready = False
    s.close()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect(('127.0.0.1', NOVNC_PORT))
        novnc_ready = True
    except: novnc_ready = False
    s.close()

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        check_backends()
        if self.path.startswith('/api/'):
            self.proxy_to(f'http://127.0.0.1:{API_PORT}/', strip='/api/')
        elif self.path == '/':
            self.respond(200, {'Content-Type': 'application/json'}, json.dumps({
                'status': 'ok', 'api': api_ready, 'novnc': novnc_ready
            }).encode())
        else:
            if novnc_ready:
                self.proxy_to(f'http://127.0.0.1:{NOVNC_PORT}', strip='')
            else:
                self.respond(503, {'Content-Type': 'application/json'}, json.dumps({'status': 'starting'}).encode())

    def do_POST(self):
        self.proxy_to(f'http://127.0.0.1:{API_PORT}/', strip='/api/')

    def do_OPTIONS(self):
        self.respond(200, {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': '*',
            'Content-Length': '0'
        }, b'')

    def proxy_to(self, base_url, strip=''):
        target_path = self.path
        if strip:
            target_path = self.path.replace(strip, '', 1)
        url = base_url.rstrip('/') + target_path
        try:
            data = None
            headers = {}
            cl = self.headers.get('Content-Length')
            if cl and int(cl) > 0:
                data = self.rfile.read(int(cl))
            for h in ['Content-Type', 'Authorization']:
                if self.headers.get(h):
                    headers[h] = self.headers[h]
            req = urllib.request.Request(url, data=data, headers=headers, method=self.command)
            resp = urllib.request.urlopen(req, timeout=10)
            body = resp.read()
            self.respond(resp.status, dict(resp.headers), body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.respond(e.code, dict(e.headers) if e.headers else {}, body)
        except Exception as e:
            self.respond(502, {'Content-Type': 'application/json'}, json.dumps({'error': str(e)}).encode())

    def respond(self, code, headers, body):
        self.send_response(code)
        for k, v in headers.items():
            self.send_header(k.lower().title(), v)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *a): pass

def signal_handler(signum, frame):
    global running
    running = False

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    try:
        socketserver.ThreadingTCPServer.allow_reuse_address = True
        srv = socketserver.ThreadingTCPServer(('0.0.0.0', PORT), ProxyHandler)
        print(f"Proxy server started on port {PORT}", flush=True)
        while running:
            srv.handle_request()
    except Exception as e:
        print(f"FATAL: {e}", flush=True)
        sys.exit(1)
