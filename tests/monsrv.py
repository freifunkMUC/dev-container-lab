#!/usr/bin/env python3
"""Servers for the client traffic monitor (tests/clientmon.sh). Runs in the
netns of the internet node. Both listen on IPv6 and IPv4.
  port 9000: a long-lived stream, one line every 100 ms.
  port 8081: HTTP, answers "ok". /big answers BIG bytes (a bulk transfer
             with full-size DF packets, for the PMTU test)."""

import http.server
import socket
import socketserver
import threading
import time

BIG = 256 * 1024

class Dual:
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


class Stream(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while True:
                self.request.sendall(f"{time.time():.3f}\n".encode())
                time.sleep(0.1)
        except OSError:
            pass


class StreamServer(Dual, socketserver.ThreadingTCPServer):
    pass


class Ok(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"x" * BIG if self.path == "/big" else b"ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class HttpServer(Dual, http.server.ThreadingHTTPServer):
    pass


if __name__ == "__main__":
    s = StreamServer(("::", 9000), Stream)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    HttpServer(("::", 8081), Ok).serve_forever()
