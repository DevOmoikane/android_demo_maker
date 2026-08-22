"""Entry point: version guard, token, port pick, browser open, serve."""
import argparse
import secrets
import socket
import sys
import threading
import webbrowser

MIN_PYTHON = (3, 8)

if sys.version_info < MIN_PYTHON:
    print("error: Python %d.%d+ is required (found %s)"
          % (*MIN_PYTHON, sys.version.split()[0]), file=sys.stderr)
    sys.exit(1)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main(argv=None):
    from . import __version__
    parser = argparse.ArgumentParser(
        prog="demo_maker", description="Demo Maker Web Studio")
    parser.add_argument("--port", type=int, default=0,
                        help="port to bind on 127.0.0.1 (default: random)")
    parser.add_argument("--no-browser", action="store_true",
                        help="do not open the browser automatically")
    parser.add_argument("--debug", action="store_true",
                        help="verbose request logging and tracebacks")
    parser.add_argument("--version", action="version",
                        version="demo-maker " + __version__)
    args = parser.parse_args(argv)

    from . import server
    port = args.port or free_port()
    token = secrets.token_urlsafe(12)
    url = "http://127.0.0.1:%d/%s/" % (port, token)

    httpd = server.make_server(port, token, debug=args.debug)
    print("Demo Maker Web Studio %s" % __version__)
    print("  listening on %s" % url)
    print("  Ctrl+C to quit")
    if not args.no_browser:
        # give the server a beat before the browser hits it
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
