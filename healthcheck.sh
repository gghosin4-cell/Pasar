#!/bin/bash

# Health check script that adapts to different binding scenarios:
# 1. Unix socket (UDS)
# 2. Reverse proxy (Caddy) - health checks through localhost
# 3. Direct HTTP binding
# 4. Direct HTTPS binding
#
# The probe is implemented with the Python standard library that the image
# already ships, so the runtime image does not need to install an extra HTTP
# client (curl) just to answer a loopback health check.

PORT=${UVICORN_PORT:-8000}
CERTFILE=${UVICORN_SSL_CERTFILE}
KEYFILE=${UVICORN_SSL_KEYFILE}
UDS=${UVICORN_UDS}
DEBUG=${DEBUG:-false}

HEALTHCHECK_HTTPS="false"
if [ -n "$CERTFILE" ] && [ -n "$KEYFILE" ] && [ -f "$CERTFILE" ] && [ -f "$KEYFILE" ]; then
    # SSL certificates provided - probe over HTTPS
    HEALTHCHECK_HTTPS="true"
fi

export HEALTHCHECK_PORT="$PORT"
export HEALTHCHECK_UDS="$UDS"
export HEALTHCHECK_HTTPS

exec python3 - <<'PY'
import http.client
import os
import socket
import ssl
import sys

port = int(os.environ.get("HEALTHCHECK_PORT") or "8000")
uds = os.environ.get("HEALTHCHECK_UDS") or ""
https = os.environ.get("HEALTHCHECK_HTTPS") == "true"
timeout = 5.0


class UnixSocketConnection(http.client.HTTPConnection):
    """HTTP connection over a Unix domain socket."""

    def __init__(self, socket_path, timeout=timeout):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._socket_path)
        self.sock = sock


def build_connection():
    if uds:
        return UnixSocketConnection(uds)
    if https:
        # Self-signed certificates are expected on the loopback interface.
        context = ssl._create_unverified_context()
        return http.client.HTTPSConnection("127.0.0.1", port, timeout=timeout, context=context)
    return http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)


def main():
    if uds and not os.path.exists(uds):
        return 1

    connection = build_connection()
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        response.read()
        return 0 if response.status == 200 else 1
    except Exception:
        return 1
    finally:
        try:
            connection.close()
        except Exception:
            pass


sys.exit(main())
PY
