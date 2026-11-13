#!/usr/bin/env python3
"""Checks an installation from ANOTHER network, like a visitor or a volunteer on the internet would see it
(tests/suite.sh --outside HOST copies this file there with SwitchBoardChat's tests/e2e/lib.py and runs it).
Python standard library only. Real certificate validation (the system's trust store).

    outside.py public                       DNS, TLS, redirects, discovery, federation, exposure
    outside.py visitor                      a web chat from here, answered by the respondent running on the server
Environment: MATRIX_HOST SB_HOST SBCHAT_HOST ORIGIN [NONCE for visitor]
"""
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request

# Cloudflare's Browser Integrity Check blocks the default "Python-urllib" user agent (error 1010):
# every request of these checks (and of lib.py's Visitor) goes out as sbcomposer-check instead.
_opener = urllib.request.build_opener()
_opener.addheaders = [("User-Agent", "sbcomposer-check/1.0")]
urllib.request.install_opener(_opener)

E = os.environ
M, SB, SBC = E["MATRIX_HOST"], E["SB_HOST"], E["SBCHAT_HOST"]
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("PASS  " if ok else "FAIL  ") + "[outside] " + name + ("" if ok or not detail else f"  ({str(detail)[:250]})"), flush=True)
    if not ok:
        failures += 1
    return ok


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def get(url, headers=None, method="GET", body=None, follow=True, timeout=20):
    opener = urllib.request.build_opener() if follow else urllib.request.build_opener(NoRedirect)
    opener.addheaders = [("User-Agent", "sbcomposer-check/1.0")]
    req = urllib.request.Request(url, headers=headers or {}, method=method, data=body)
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except Exception as e:
        return 0, {}, repr(e).encode()


def cert_info(host):
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=15) as s:
        with ctx.wrap_socket(s, server_hostname=host) as t:
            c = t.getpeercert()
    return c


def public():
    for h in (M, SB, SBC):
        try:
            addrs = sorted({a[4][0] for a in socket.getaddrinfo(h, 443, proto=socket.IPPROTO_TCP)})
            check(f"{h} resolves", bool(addrs), "")
        except Exception as e:
            check(f"{h} resolves", False, repr(e)); continue
        try:
            c = cert_info(h)
            days = (ssl.cert_time_to_seconds(c["notAfter"]) - time.time()) / 86400
            check(f"{h}: valid public certificate ({int(days)} days left)", days > 7, c.get("notAfter"))
        except Exception as e:
            check(f"{h}: valid public certificate", False, repr(e))
        st, hd, _ = get(f"http://{h}/", follow=False)
        check(f"http://{h} redirects to https", st in (301, 302, 307, 308) and hd.get("Location", "").startswith("https://"), f"{st} {hd.get('Location')}")

    st, _, b = get(f"https://{M}/.well-known/matrix/client")
    try:
        wk = json.loads(b)
    except Exception:
        wk = {}
    check("Matrix client discovery (.well-known/matrix/client)", wk.get("m.homeserver", {}).get("base_url") == f"https://{M}", b[:200])
    st, _, b = get(f"https://{M}/.well-known/matrix/server")
    check("Matrix federation discovery (.well-known/matrix/server)", st == 200 and M in b.decode(errors="replace"), b[:200])
    st, _, b = get(f"https://{M}/_matrix/client/versions")
    check("Matrix client API answers", st == 200 and b'"versions"' in b, f"{st}")
    st, _, b = get(f"https://{M}/_matrix/client/v1/auth_metadata")
    check("Synapse delegates login to MAS (auth_metadata)", st == 200 and f"https://{M}/auth/".encode() in b, f"{st} {b[:150]}")
    st, _, b = get(f"https://{M}/auth/.well-known/openid-configuration")
    check("MAS OpenID discovery", st == 200 and b'"authorization_endpoint"' in b, f"{st}")
    st, _, b = get(f"https://{M}/auth/login")
    check("MAS login page", st == 200 and b"<html" in b.lower(), f"{st}")
    st, _, b = get(f"https://{M}/_matrix/key/v2/server")
    check("federation: server signing keys published", st == 200 and b'"verify_keys"' in b, f"{st}")
    st, _, b = get(f"https://{M}/_matrix/client/v3/login")
    check("password login flow offered (for Element and the bridge)", st == 200 and b"m.login.password" in b, f"{st} {b[:150]}")
    st, _, _ = get(f"https://{M}/_synapse/admin/v1/server_version")
    check("Synapse admin API is NOT reachable from the internet", st in (403, 404), str(st))
    st, _, _ = get(f"https://{M}/auth/api/admin/v1/users")
    check("MAS admin API refuses a request without token", st in (400, 401, 403), str(st))
    st, _, _ = get(f"https://{M}/")
    check("nothing else is served on the Matrix host", st == 404, str(st))

    st, _, b = get(f"https://{SB}/SwitchBoard/SwitchBoard/src/managementportal.php")
    check("SwitchBoard portal (login page)", st == 200 and (b'name="username"' in b or b"createormodifyusername" in b), f"{st}")
    st, _, b = get(f"https://{SB}/SwitchBoard/SwitchBoard/config/config.php")
    check("SwitchBoard's config folder is not downloadable", st in (403, 404) or b"dbpassword" not in b, str(st))
    st, _, _ = get(f"https://{SBC}/voip_api")
    check("SMS webhook refuses a request without key (403)", st == 403, str(st))
    st, _, _ = get(f"https://{SBC}/sbchat_api", method="POST", body=b"{}", headers={"Content-Type": "application/json"})
    check("SBChat API refuses a request without token", st in (400, 401, 403), str(st))
    st, hd, _ = get(f"https://{SB}/web/session", method="OPTIONS",
                    headers={"Origin": E["ORIGIN"], "Access-Control-Request-Method": "POST",
                             "Access-Control-Request-Headers": "content-type"})
    check("web chat CORS preflight allows the configured website", hd.get("access-control-allow-origin", hd.get("Access-Control-Allow-Origin")) == E["ORIGIN"], f"{st} {hd}")
    st, hd, _ = get(f"https://{SB}/web/session", method="OPTIONS",
                    headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"})
    check("web chat refuses another website (CORS)", 0 < st < 500 and
          (hd.get("access-control-allow-origin") or hd.get("Access-Control-Allow-Origin")) != "https://evil.example", f"{st} {hd}")


def visitor():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import lib  # SwitchBoardChat tests/e2e/lib.py, copied next to this file
    lib.BRIDGE = "https://" + SB
    nonce = E["NONCE"]
    v = lib.Visitor(origin=E["ORIGIN"]).start()
    check("visitor from the outside network opens a web chat", v.token is not None)
    v.open_stream()
    st, body = v.say(f"ping {nonce}")
    check("visitor's message accepted", st == 200, f"{st} {body}")
    check("the respondent's answer arrives (streamed through Cloudflare/NPM/nginx)", v.wait_text(f"pong {nonce}", 180) is not None, str(v.texts()))
    v.close_stream()
    st, _ = v.end()
    check("visitor ends the chat", st == 200, str(st))


for arg in sys.argv[1:]:
    {"public": public, "visitor": visitor}[arg]()
sys.exit(1 if failures else 0)
