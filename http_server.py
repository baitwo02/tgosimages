#!/usr/bin/env python3
"""Minimal background HTTP file server manager (description intentionally brief; use 'help' subcommand for full text)."""
from __future__ import annotations
import argparse
import http.server
import os
import sys
import time
import urllib.request
import signal
from pathlib import Path
import contextlib

HELP_TEXT = """
Simple background HTTP file server manager for the SERVE_DIR directory.

Subcommands:
    start     Start server in background (daemon style) serving SERVE_DIR
    stop      Stop running server
    status    Show server status (running? pid? listening? test fetch)
    restart   Stop then start
    help      Show this extended help or a subcommand help

Features:
    - Configurable port & bind address (bind defaults 0.0.0.0 all interfaces)
    - Log file redirection
    - Health check via HTTP GET on root path
    - Duplicate start protection via /proc detection of listening socket
    - Environment override SERVE_DIR selects served directory

Examples:
    python3 http_server.py start -p 9000 # uses default 8000
    python3 http_server.py status
    python3 http_server.py restart -p 9000 -b 127.0.0.1
    python3 http_server.py stop
    python3 http_server.py help start

Security Note:
    Binding to 0.0.0.0 exposes contents to the network. Consider firewall
    restrictions or binding to a specific host/IP if needed.
""".strip()

DEFAULT_PORT = 8000
DEFAULT_BIND = '0.0.0.0'
DEFAULT_SERVE_DIR = Path(os.environ.get('SERVE_DIR', 'IMAGES'))
DEFAULT_LOG = DEFAULT_SERVE_DIR / '.images_http.log'
SUBCOMMANDS = ("start", "stop", "status", "restart", "help")

class Color:
    if sys.stdout.isatty():
        G='\033[32m'; R='\033[31m'; Y='\033[33m'; C='\033[36m'; B='\033[34m'; M='\033[35m'; N='\033[0m'
    else:
        G=R=Y=C=B=M=N=''

def cprint(msg: str, color: str=''):
    print(f"{color}{msg}{Color.N}")

def _add_common_arguments(parser: argparse.ArgumentParser):
    """Attach arguments shared by operational subcommands."""
    parser.add_argument('-p','--port', type=int, default=None, help=f'Listen port (default {DEFAULT_PORT} if omitted)')
    parser.add_argument('-b','--bind', default=DEFAULT_BIND, help=f'Bind address (default {DEFAULT_BIND} - all interfaces)')
    parser.add_argument('--dir', default=str(DEFAULT_SERVE_DIR), help='Directory to serve (from DEFAULT_SERVE_DIR env or IMAGES)')
    parser.add_argument('--log-file', default=str(DEFAULT_LOG), help='Log file path')
    parser.add_argument('--no-color', action='store_true', help='Disable colored output')
    parser.add_argument('--timeout', type=float, default=3.0, help='Health check timeout seconds')

def parse_args(argv=None):
    """Parse CLI arguments.

    Design decisions:
      - Custom root -h/--help to always show full extended help (HELP_TEXT)
      - Dedicated 'help' subcommand (mirrors many CLI tools) for consistency
      - Shared argument set extracted to _add_common_arguments() for reuse
    """
    short_desc = "Background HTTP server manager for the IMAGES directory"

    class FullHelpAction(argparse.Action):  # prints extended help and exits
        def __call__(self, parser, namespace, values, option_string=None):
            print(HELP_TEXT)
            parser.exit()

    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=short_desc,
        epilog="Use 'help' subcommand for extended help.",
        add_help=False)
    parser.add_argument('-h','--help', action=FullHelpAction, nargs=0, help='Show extended help and exit')
    subparsers = parser.add_subparsers(dest='cmd')  # manual validation allows no-arg help

    # Operational subcommands
    for name, help_text in (
        ('start','Start server'),
        ('restart','Restart server'),
        ('status','Show status'),
        ('stop','Stop server'),
    ): _add_common_arguments(subparsers.add_parser(name, help=help_text))

    # Help subcommand (topic-specific)
    help_p = subparsers.add_parser('help', help='Show extended or topic help')
    help_p.add_argument('topic', nargs='?', help='Optional subcommand')

    args = parser.parse_args(argv)

    # No subcommand: show extended help
    if args.cmd is None:
        print(HELP_TEXT)
        sys.exit(0)

    # 'help' subcommand logic
    if args.cmd == 'help':
        if not args.topic:
            print(HELP_TEXT)
            sys.exit(0)
        topic = args.topic
        if topic not in SUBCOMMANDS:
            cprint(f"Unknown topic: {topic}", Color.R)
            sys.exit(2)
        if topic == 'help':
            print("Usage: http_server.py help [subcommand]\nSubcommands: " + ", ".join(SUBCOMMANDS))
            sys.exit(0)
        # Build ephemeral parser for topic-specific help
        topic_parser = argparse.ArgumentParser(prog=f"http_server.py {topic}")
        _add_common_arguments(topic_parser)
        topic_parser.print_help(sys.stdout)
        sys.exit(0)

    return args

def discover_servers() -> list[tuple[int,int]]:
    """Return list of (pid, port) for running http_server.py processes (listening state)."""
    inode_map = {}
    for table in ("/proc/net/tcp","/proc/net/tcp6"):
        try:
            with open(table,'r') as f:
                next(f)
                for line in f:
                    parts=line.split()
                    if len(parts)<10: continue
                    local=parts[1]; st=parts[3]; inode=parts[9]
                    if st!='0A': continue
                    try:
                        _ip,phex=local.split(':')
                        port=int(phex,16); inode_i=int(inode)
                    except ValueError:
                        continue
                    inode_map[inode_i]=port
        except (FileNotFoundError,PermissionError):
            continue
    if not inode_map:
        return []
    results=[]
    for d in Path('/proc').iterdir():
        if not d.name.isdigit(): continue
        pid=int(d.name)
        try: cmdline=(d/'cmdline').read_bytes().split(b'\0')
        except Exception: continue
        texts=[c.decode('utf-8','ignore') for c in cmdline if c]
        if not any('http_server.py' in t for t in texts): continue
        fd_dir=d/'fd'; seen=set()
        try:
            for fd in fd_dir.iterdir():
                try: target=os.readlink(fd)
                except OSError: continue
                if target.startswith('socket:['):
                    try: inode_i=int(target[8:-1])
                    except ValueError: continue
                    port=inode_map.get(inode_i)
                    if port: seen.add(port)
        except Exception:
            pass
        for p in seen:
            results.append((pid,p))
    return sorted(results)

def server_start(args):
    if args.port is None:
        args.port = DEFAULT_PORT
    # Normalize paths to absolute before chdir
    log_file = Path(args.log_file).expanduser().resolve()
    serve_dir = Path(args.dir).expanduser().resolve()

    # Backward compatibility migrations (legacy log file relocation only)
    # 1. If old root-level log file exists (.images_http.log) and new target absent, migrate
    old_root_log = Path('.images_http.log').resolve()
    if not Path(args.log_file).expanduser().resolve().exists() and old_root_log.exists() and old_root_log != log_file:
        try:
            log_file.parent.mkdir(parents=True, exist_ok=True)
            old_root_log.replace(log_file)
        except Exception:
            pass

    if not serve_dir.is_dir():
        cprint(f"Directory not found: {serve_dir}", Color.R)
        sys.exit(1)

    # Existing running via detection (filter by port if user specified)
    existing=[(pid,port) for pid,port in discover_servers() if (args.port is None or port==args.port)]
    if existing and (args.port is None or any(port==args.port for _,port in existing)):
        msg_port = args.port if args.port is not None else '/'.join(sorted({str(p) for _,p in existing}))
        cprint(f"Server already running (PID {existing[0][0]}) on port {msg_port}.", Color.Y)
        return

    # Fork style background (POSIX only)
    # Pre-check port availability (best effort)
    import socket
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.settimeout(0.2)
        in_use = (s.connect_ex((args.bind, args.port)) == 0)
    if in_use:
        cprint(f"Port {args.port} already in use on {args.bind}. Abort start.", Color.R)
        cprint("Suggestion: use 'ss -lntp | grep :%d' to find process or choose --port." % args.port, Color.Y)
        return

    if args.bind == '0.0.0.0':
        cprint("WARNING: Serving on 0.0.0.0 (all interfaces). Ensure this is intended; consider firewalling or using --bind specific IP.", Color.Y)
    cprint(f"Starting HTTP server on {args.bind}:{args.port} serving {serve_dir}", Color.C)
    pid = os.fork()
    if pid > 0:
        for _ in range(30):
            servers = discover_servers()
            match = [spid for spid,port in servers if port==args.port]
            if match:
                cprint(f"Started (PID {match[0]})", Color.G); break
            time.sleep(0.1)
        else:
            cprint(f"Started (child PID {pid}) but listener not confirmed", Color.Y)
        return

    # child becomes session leader
    os.setsid()
    # second fork not strictly needed here

    os.chdir(str(serve_dir))
    # Redirect stdio
    with open(log_file, 'ab', buffering=0) as lf:
        os.dup2(lf.fileno(), 1)
        os.dup2(lf.fileno(), 2)
        # Close stdin
        sys.stdin.close()
        sys.stdin = open(os.devnull, 'r')

    # Ensure parent directory for log exists
        log_file.parent.mkdir(parents=True, exist_ok=True)
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, format, *args):  # reduce noise; already in log
                sys.stdout.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format%args))

        try:
            httpd = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
        except OSError as e:
            sys.stdout.write(f"Failed to bind {args.bind}:{args.port} -> {e}\n")
            sys.exit(1)

        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            httpd.server_close()
            sys.exit(0)

def server_stop(args):
    servers=discover_servers()
    if not servers:
        cprint("No running server detected", Color.Y); return
    if args.port is not None:
        servers=[s for s in servers if s[1]==args.port]
        if not servers:
            cprint("No server on specified port", Color.Y); return
    # Group by pid
    grouped={}
    for spid,port in servers:
        grouped.setdefault(spid, []).append(port)
    if len(grouped)>1:
        cprint("Multiple servers detected (ambiguous stop):", Color.Y)
        for spid,pl in grouped.items():
            cprint(f"  PID {spid} ports {','.join(map(str,sorted(pl)))}", Color.Y)
        if args.port is None:
            cprint("Hint: specify --port to target a specific one.", Color.C)
        return
    pid,ports=next(iter(grouped.items()))
    cprint(f"Stopping server PID {pid} (ports={','.join(map(str,sorted(ports)))})", Color.C)
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
    for _ in range(30):
        try:
            os.kill(pid, 0)
        except OSError:
            break
        time.sleep(0.1)
    else:
        # still alive
        try:
            os.kill(pid, 0)
            still_alive = True
        except OSError:
            still_alive = False
        if not still_alive:
            cprint("Stopped", Color.G); return
        # If here, force kill path
        cprint("Force killing...", Color.Y)
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
    cprint("Stopped", Color.G)

def server_status(args):
    servers=discover_servers()
    if not servers:
        cprint("Not running", Color.R); return
    if args.port is not None:
        servers=[s for s in servers if s[1]==args.port]
        if not servers:
            cprint("Not running on specified port", Color.R); return
    grouped={}
    for spid,port in servers:
        grouped.setdefault(spid, []).append(port)
    if len(grouped)>1 and args.port is None:
        cprint("Multiple servers detected:", Color.Y)
        for spid,pl in grouped.items():
            cprint(f"  PID {spid} ports {','.join(map(str,sorted(pl)))}", Color.Y)
        cprint("Specify --port for detailed health check.", Color.C)
        return
    pid,ports=next(iter(grouped.items())) if len(grouped)==1 else (list(grouped.keys())[0], grouped[list(grouped.keys())[0]])
    cprint(f"Running (PID {pid}) (ports={','.join(map(str,sorted(ports)))})", Color.G)
    if len(ports)==1:
        url = f"http://{args.bind}:{ports[0]}/"
        time.sleep(0.1)
        try:
            with urllib.request.urlopen(url, timeout=args.timeout) as r:
                cprint(f"Health OK HTTP {r.status}", Color.G)
        except Exception as e:
            cprint(f"Health check failed: {e}", Color.R)
            cprint("Possible causes: server still starting, port/firewall blocked, wrong bind/port used.", Color.Y)

def server_restart(args):
    server_stop(args)
    server_start(args)

def main(argv=None):
    args = parse_args(argv)
    if args.no_color:
        Color.G = Color.R = Color.Y = Color.C = Color.B = Color.M = Color.N = ''

    if args.cmd == 'start':
        server_start(args)
    elif args.cmd == 'stop':
        server_stop(args)
    elif args.cmd == 'status':
        server_status(args)
    elif args.cmd == 'restart':
        server_restart(args)
    else:
        print('Unknown command')
        sys.exit(2)

if __name__ == '__main__':
    main()
