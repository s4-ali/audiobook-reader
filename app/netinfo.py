"""Network self-awareness for phone pairing: LAN address discovery, a QR-code renderer,
and mDNS/Bonjour advertising.

The desktop server can't easily tell the phone "connect to me" without the user hand-typing
the Mac's IP. This module lets the server figure out its own LAN address(es), hand the web UI
a scannable QR of that address, and advertise itself over mDNS so the app can auto-discover it.

Everything here is best-effort and fail-safe: no network, a missing optional dependency
(``qrcode`` / ``zeroconf``), or a resolver hiccup degrades to "nothing found" rather than an
error — the server never depends on any of it to run.
"""
from __future__ import annotations

import ipaddress
import socket
from typing import List, Optional

from . import config


# --------------------------------------------------------------------- LAN address
def _usable(ip: str) -> bool:
    """A private IPv4 another device on the same Wi-Fi could actually reach us on."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return a.version == 4 and a.is_private and not a.is_loopback and not a.is_link_local


def primary_lan_ip() -> Optional[str]:
    """The IP of the interface holding the default route (usually Wi-Fi/Ethernet).

    Opens a UDP socket "to" a public address — no packet is sent; the OS just picks the
    outbound interface, whose address we read back. Works offline in most setups.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        return ip if _usable(ip) else None
    except OSError:
        return None
    finally:
        s.close()


def _other_ips() -> List[str]:
    """Additional private IPv4s bound to this host (multi-homed machines, docker bridges…)."""
    out: List[str] = []
    try:
        for res in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = res[4][0]
            if _usable(ip):
                out.append(ip)
    except OSError:
        pass
    return out


def candidate_ips() -> List[str]:
    """Reachable LAN IPv4s, the default-route one first, deduped."""
    seen: set = set()
    out: List[str] = []
    for ip in [primary_lan_ip(), *_other_ips()]:
        if ip and ip not in seen:
            seen.add(ip)
            out.append(ip)
    return out


def friendly_name() -> str:
    """A human name for this computer for the app's discovery list (drops the .local suffix)."""
    return (socket.gethostname() or "computer").split(".")[0]


def server_info() -> dict:
    """What the web UI and the pairing endpoints report about this server's address."""
    port = config.PORT
    urls = [f"http://{ip}:{port}" for ip in candidate_ips()]
    return {
        "name": friendly_name(),
        "hostname": socket.gethostname(),
        "port": port,
        "bind_host": config.BIND_HOST,
        # True once the server listens on all interfaces (HOST=0.0.0.0) — until then a phone
        # can't reach it however it's addressed, so the UI warns instead of showing a dead QR.
        "lan_reachable": config.BIND_HOST in ("0.0.0.0", "::", ""),
        "primary": urls[0] if urls else None,
        "urls": urls,
    }


# --------------------------------------------------------------------- QR code (SVG)
def qr_svg(data: str, *, module: int = 10, border: int = 2, dark: str = "#11111b") -> str:
    """Render ``data`` as a self-contained SVG QR code.

    Uses only ``qrcode``'s pure-Python matrix builder (no Pillow, no lxml): we read the module
    grid and emit ``<rect>`` runs ourselves. Raises ImportError if ``qrcode`` isn't installed,
    which the caller turns into a graceful 503.
    """
    import qrcode  # optional dependency; ImportError bubbles up to the endpoint

    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=border)
    qr.add_data(data)
    qr.make(fit=True)
    matrix = qr.get_matrix()          # booleans, quiet-zone border already included
    n = len(matrix)
    dim = n * module
    rects: List[str] = []
    for r, row in enumerate(matrix):  # run-length encode dark runs per row into one rect each
        c = 0
        while c < n:
            if row[c]:
                start = c
                while c < n and row[c]:
                    c += 1
                rects.append(
                    f'<rect x="{start * module}" y="{r * module}" '
                    f'width="{(c - start) * module}" height="{module}"/>'
                )
            else:
                c += 1
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{dim}" height="{dim}" '
        f'viewBox="0 0 {dim} {dim}" shape-rendering="crispEdges">'
        f'<rect width="{dim}" height="{dim}" fill="#ffffff"/>'
        f'<g fill="{dark}">{"".join(rects)}</g></svg>'
    )


# --------------------------------------------------------------------- mDNS / Bonjour
# One advertiser per process. Held so the shutdown hook can unregister cleanly.
_zc = None
_service = None


def start_mdns():
    """Advertise this server as ``_audiobook._tcp`` so the mobile app auto-discovers it.

    No-ops (returns None) when disabled, when the server is localhost-only, when there's no LAN
    address, or when ``zeroconf`` isn't installed — never raises. Returns a handle for stop_mdns.
    """
    global _zc, _service
    if not config.MDNS_ENABLED:
        return None
    info = server_info()
    if not info["lan_reachable"] or not info["urls"]:
        return None  # nothing a phone could connect to — don't advertise a dead address
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except Exception:
        return None
    try:
        ip = candidate_ips()[0]
        instance = f"{info['name']} - Audiobook Reader.{config.MDNS_SERVICE_TYPE}"
        _service = ServiceInfo(
            config.MDNS_SERVICE_TYPE,
            instance,
            addresses=[socket.inet_aton(ip)],
            port=info["port"],
            properties={"path": "/", "name": info["name"]},
            server=f"{info['name'].lower()}-abk.local.",
        )
        _zc = Zeroconf()
        _zc.register_service(_service)
        return _zc
    except Exception:
        _zc = _service = None
        return None


def stop_mdns(handle=None) -> None:
    """Unregister the mDNS service and close zeroconf (best-effort)."""
    global _zc, _service
    zc = handle or _zc
    try:
        if zc is not None and _service is not None:
            zc.unregister_service(_service)
        if zc is not None:
            zc.close()
    except Exception:
        pass
    finally:
        _zc = _service = None


# --------------------------------------------------------------------- startup banner
def print_banner() -> None:
    """Print the reachable URLs at server startup (called from scripts/run.sh)."""
    info = server_info()
    port = info["port"]
    print(f"    Local:    http://127.0.0.1:{port}")
    if info["primary"]:
        tag = "   <- open this on your phone (same Wi-Fi)" if info["lan_reachable"] else ""
        print(f"    Network:  {info['primary']}{tag}")
        for u in info["urls"][1:]:
            print(f"              {u}")
    if not info["lan_reachable"]:
        print("    Phone pairing is OFF (listening on localhost only).")
        print("    Restart with:  HOST=0.0.0.0 ./scripts/run.sh")


if __name__ == "__main__":
    print_banner()
