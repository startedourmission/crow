"""Owned loopback HTTP/WebSocket fixture for Crow browser integration tests."""
import base64
import hashlib
import http.server
import pathlib
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers()
            self.wfile.write(b'\x81\x09socket-ok')
            self.wfile.flush()
            return
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', 'http://localhost:%d/page' % self.server.server_port)
            self.end_headers()
            return
        body = b'asset-ok'
        if self.path == '/page':
            body = ('''<!doctype html><title>Crow browser fixture</title><body>Loading<script>
            Promise.all([fetch('/asset').then(r=>r.text()),
              new Promise((resolve,reject)=>{const ws=new WebSocket('ws://'+location.host+'/socket');
                ws.onmessage=e=>{resolve(e.data); ws.close()};ws.onerror=reject})])
              .then(values=>document.body.dataset.result=values.join(','))
              .catch(e=>document.body.dataset.result='ERROR:'+e);
            </script>''').encode()
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Type', 'text/html' if self.path == '/page' else 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


primary = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(primary.server_port))
primary.serve_forever()
