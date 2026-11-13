#!/usr/bin/env python3
"""Creates (or updates) the single Nginx Proxy Manager proxy host for an install made with
`install.sh --behind-proxy`: the three names -> http://synapse-nginx:8080, websockets, a Let's Encrypt
certificate, Force SSL, HTTP/2.

    tools/npm-proxy-host.py --names matrix.example.org,sb.example.org,sbchat.example.org --email you@example.org
                            [--npm http://127.0.0.1:81] [--credentials ~/.config/sbcomposer/npm.env]

The credentials file holds NPM_EMAIL=... and NPM_PASSWORD=... (an NPM admin login); nothing is printed
from it. Safe to re-run: an existing host for these names is updated, an existing certificate reused.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--names", required=True)
ap.add_argument("--email", required=True)
ap.add_argument("--npm", default="http://127.0.0.1:81")
ap.add_argument("--credentials", default=os.path.expanduser("~/.config/sbcomposer/npm.env"))
ap.add_argument("--upstream", default="synapse-nginx")
ap.add_argument("--port", type=int, default=8080)
a = ap.parse_args()
names = sorted(n.strip().lower() for n in a.names.split(",") if n.strip())

cred = {}
for line in open(a.credentials):
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.rstrip("\n").split("=", 1)
        cred[k.strip()] = v.strip().strip('"').strip("'")


def api(method, path, body=None, token=None, timeout=60):
    req = urllib.request.Request(a.npm + "/api" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        sys.exit(f"NPM API {method} {path}: HTTP {e.code} {e.read()[:400].decode(errors='replace')}")


token = api("POST", "/tokens", {"identity": cred["NPM_EMAIL"], "secret": cred["NPM_PASSWORD"]})["token"]
print("logged in to Nginx Proxy Manager")

# Certificate: reuse one covering exactly these names, else request it (HTTP-01 through NPM itself)
cert = next((c for c in api("GET", "/nginx/certificates", token=token)
             if sorted(d.lower() for d in c.get("domain_names", [])) == names), None)
if cert:
    print(f"reusing certificate #{cert['id']}")
else:
    print("requesting a Let's Encrypt certificate for " + ", ".join(names) + " (up to a few minutes)")
    cert = api("POST", "/nginx/certificates", {
        "provider": "letsencrypt", "nice_name": names[0], "domain_names": names,
        "meta": {"dns_challenge": False},   # recent NPM: the account email is used, no agree flag
    }, token=token, timeout=600)
    print(f"certificate #{cert['id']} issued")

host = {
    "domain_names": names, "forward_scheme": "http", "forward_host": a.upstream, "forward_port": a.port,
    "certificate_id": cert["id"], "ssl_forced": True, "http2_support": True, "hsts_enabled": False,
    "hsts_subdomains": False, "allow_websocket_upgrade": True, "block_exploits": False,
    "caching_enabled": False, "access_list_id": 0, "advanced_config": "", "locations": [], "meta": {},
}
existing = next((h for h in api("GET", "/nginx/proxy-hosts", token=token)
                 if set(d.lower() for d in h.get("domain_names", [])) & set(names)), None)
if existing:
    api("PUT", f"/nginx/proxy-hosts/{existing['id']}", host, token=token)
    print(f"proxy host #{existing['id']} updated -> http://{a.upstream}:{a.port}")
else:
    created = api("POST", "/nginx/proxy-hosts", host, token=token)
    print(f"proxy host #{created['id']} created -> http://{a.upstream}:{a.port}")
