"""Conversation scenarios of the full test suite (tests/suite.sh), with SwitchBoardChat's own e2e helpers
(tests/e2e/lib.py: Visitor speaks the website widget's protocol, Sim is a real Matrix device with end-to-end
encryption, logged in through MAS). Runs inside the sbcomposer-sim image.

    python3 suite.py <scenario>...      scenarios: accounts webchat sms responder
Environment (from tests/suite.sh): MATRIX_HOST SB_HOST SBCHAT_HOST ORIGIN RESP_A RESP_B RESP_PW SBUSER SBUSER_PW
CC_TOKEN DID WELCOME MERCI NONCE (responder). Prints PASS/FAIL lines, and "ROOM <scenario> <room id>" lines
for the checks done afterwards on the host (Law 25 purge).
"""
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, "/e2e")
import lib  # noqa: E402

# Cloudflare's Browser Integrity Check blocks the default "Python-urllib" user agent (error 1010):
# every request of these checks (and of lib.py's Visitor) goes out as sbcomposer-check instead.
_opener = urllib.request.build_opener()
_opener.addheaders = [("User-Agent", "sbcomposer-check/1.0")]
urllib.request.install_opener(_opener)

E = os.environ
lib.SYNAPSE = "https://" + E["MATRIX_HOST"]
lib.BRIDGE = "https://" + E["SB_HOST"]
lib.ORIGIN = E["ORIGIN"]
lib.PASSWORD = E["RESP_PW"]
lib.SIM = Path("/usr/local/bin/respondent-sim")
lib.WORK = Path("/tmp/work")
lib.WORK.mkdir(parents=True, exist_ok=True)

failures = 0
SIMS = {}


def check(name, ok, detail=""):
    global failures
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok or not detail else f"  ({str(detail)[:300]})"), flush=True)
    if not ok:
        failures += 1
    return ok


def sim(key):
    if key not in SIMS:
        user = E["RESP_A"] if key == "a" else E["RESP_B"]
        try:
            SIMS[key] = lib.Sim(user, f"suite-{key}-{uuid.uuid4().hex[:4]}", cross_sign=(key == "a"), settle=6)
        except RuntimeError:
            # most likely MAS's per-address login limit (all test logins share one address): wait it out once
            print(f"(respondent {key}: login refused, retrying after MAS's rate-limit window)", flush=True)
            time.sleep(65)
            SIMS[key] = lib.Sim(user, f"suite-{key}-{uuid.uuid4().hex[:4]}", cross_sign=(key == "a"), settle=6)
    return SIMS[key]


def http_json(url, body=None, headers=None, method=None, timeout=30):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                 method=method or ("POST" if body is not None else "GET"),
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except Exception:
            return e.code, {}


def host_step(name, info=""):
    """Lets tests/suite.sh check something on the server (its database) at this exact point: prints
    WAIT <name>, then waits for the host to create /sync/<name>."""
    print(f"WAIT {name} {info}".rstrip(), flush=True)
    for _ in range(120):
        if os.path.exists(f"/sync/{name}"):
            return
        time.sleep(1)
    print(f"(host step {name} timed out)", flush=True)


def say(s, room, text):
    """Sends as a respondent and returns the result; retries when the homeserver refuses for a moment
    (e.g. Synapse's per-user message rate limit when the tests type faster than people)."""
    for attempt in range(4):
        sent = s.send(room, text)
        if sent and sent.get("ok"):
            return sent
        print(f"(send of {text[:20]!r} refused: {sent}; retry {attempt + 1})", flush=True)
        time.sleep(10)
    return sent


def utd_in(s, room):
    return [e for e in s.events if e["event"] == "utd" and e.get("room") == room]


# ------------------------------------------------------------------------------------------ scenarios
def login(user, password):
    return http_json(lib.SYNAPSE + "/_matrix/client/v3/login", {
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": user},
        "password": password, "initial_device_display_name": "sbcomposer suite"})


def sc_accounts():
    print("== Accounts", flush=True)
    a = sim("a")
    check(f"respondent A ({E['RESP_A']}) logs in through MAS with end-to-end encryption", a.device is not None)
    b = sim("b")
    check(f"respondent B ({E['RESP_B']}) logs in through MAS", b.device is not None)
    # MAS limits password logins per address (default: a burst of 3, then 3 per minute); every test login
    # comes from the same address, so leave the window before the next ones.
    time.sleep(65)
    status, body = login(E["SBUSER"], E["SBUSER_PW"])
    ok = check("an account created by SwitchBoard (through MAS) logs in", status == 200 and "access_token" in body, f"{status} {body}")
    if ok:
        token = body["access_token"]
        status, who = http_json(lib.SYNAPSE + "/_matrix/client/v3/account/whoami", headers={"Authorization": "Bearer " + token})
        check("whoami returns @" + E["SBUSER"] + ":" + E["MATRIX_HOST"],
              who.get("user_id") == f"@{E['SBUSER']}:{E['MATRIX_HOST']}", str(who))
        status, _ = http_json(lib.SYNAPSE + "/_matrix/client/v3/logout", {}, headers={"Authorization": "Bearer " + token})
        check("logout", status == 200, str(status))
    status, body = login(E["SBUSER"], "wrong-password-123")
    check("a wrong password is refused", status in (401, 403), f"{status} {body}")
    time.sleep(65)   # the respondents of the next scenarios may log in again


def sc_webchat():
    print("== Web chat", flush=True)
    a, b = sim("a"), sim("b")
    nonce = uuid.uuid4().hex[:8]
    ma, mb = a.mark(), b.mark()
    v = lib.Visitor(origin=lib.ORIGIN).start()
    v.open_stream()
    status, body = v.say(f"Allo, j'ai besoin de parler {nonce}")
    check("visitor's first message accepted", status == 200, f"{status} {body}")
    room = a.wait_room(ma, 90)
    room_b = b.wait_room(mb, 90)
    check("a room is created and both respondents are in it", room is not None and room == room_b, f"{room} {room_b}")
    if room:
        print(f"ROOM webchat {room}", flush=True)
    check("respondent A reads the visitor's message", a.wait_message(nonce, ma, 90) is not None)
    check("respondent B reads the visitor's message", b.wait_message(nonce, mb, 90) is not None)
    check("no undecryptable message in the room", not utd_in(a, room) and not utd_in(b, room),
          str(utd_in(a, room) + utd_in(b, room)))
    check("the welcome macro (newcomerweb, set through SwitchBoard) reaches the visitor",
          v.wait_text(E["WELCOME"], 40) is not None, str(v.texts()))
    if not room:
        return
    m = a.mark()
    say(a, room, "!aide")
    check("!aide is answered in the room", a.wait_message("ommandes", m, 30) is not None)
    m = a.mark()
    say(a, room, "!nimportequoi")
    check("an unknown command is answered", a.wait_message("inconnue", m, 30) is not None or a.wait_message("Unknown", m, 30) is not None)
    m = a.mark()
    say(a, room, "#merci")
    check("a macro typed by a respondent (#merci) reaches the visitor", v.wait_text(E["MERCI"], 40) is not None, str(v.texts()))
    sent = say(a, room, f"Bonjour, je suis là {nonce}")
    check("respondent A's answer is sent", bool(sent and sent.get("ok")), str(sent))
    check("the visitor receives the answer (server-sent events)", v.wait_text(f"je suis là {nonce}", 60) is not None, str(v.texts()))
    sent = say(b, room, f"Et moi aussi {nonce}")
    check("respondent B can also answer", v.wait_text(f"Et moi aussi {nonce}", 60) is not None, str(v.texts()))
    status, hist = v.history()
    texts = json.dumps(hist, ensure_ascii=False)
    check("the history (page reload) has the whole conversation", status == 200 and nonce in texts and "je suis là" in texts, f"{status}")
    v.close_stream()
    status, _ = v.end()
    check("the visitor ends the chat", status == 200, str(status))
    check("the room is closed for respondent A", a.wait(lambda e: e["event"] == "removed" and e.get("room") == room, 60, m) is not None)
    check("the room is closed for respondent B", b.wait(lambda e: e["event"] == "removed" and e.get("room") == room, 60, mb) is not None)


def sc_sms():
    print("== SMS (voip.ms webhook; outgoing SMS muted)", flush=True)
    a, b = sim("a"), sim("b")
    nonce = uuid.uuid4().hex[:8]
    ma, mb = a.mark(), b.mark()
    # a new caller every run (555-01xx numbers are reserved for fiction): always a new conversation
    caller = "51455501" + str(int(nonce, 16) % 100).zfill(2)
    q = urllib.parse.urlencode({"to": E["DID"], "from": caller, "message": f"Bonjour par texto {nonce}",
                                "id": str(int(time.time())), "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                                # the key in SwitchBoard's hook URL: sha256 of the call center's token
                                "sbchatapikey": hashlib.sha256(E["CC_TOKEN"].encode()).hexdigest()})
    try:
        with urllib.request.urlopen(f"https://{E['SBCHAT_HOST']}/voip_api?{q}", timeout=30) as r:
            status, text = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        status, text = e.code, ""
    check("the SMS webhook accepts a message with the call center key", status == 200, f"{status} {text[:100]}")
    try:
        urllib.request.urlopen(f"https://{E['SBCHAT_HOST']}/voip_api?" + q.replace(hashlib.sha256(E["CC_TOKEN"].encode()).hexdigest(), "wrongkey"), timeout=30)
        bad = 200
    except urllib.error.HTTPError as e:
        bad = e.code
    check("a wrong key is refused (403)", bad == 403, str(bad))
    room = a.wait_room(ma, 90)
    b.wait_room(mb, 90)
    check("an SMS room is created for the respondents", room is not None)
    if room:
        print(f"ROOM sms {room}", flush=True)
    check("respondent A reads the SMS", a.wait_message(nonce, ma, 90) is not None)
    check("respondent B reads the SMS", b.wait_message(nonce, mb, 90) is not None)
    check("the caller's number is not shown in clear to respondents",
          not [e for e in a.events[ma:] if caller in json.dumps(e)], "number visible")
    if room:
        m = a.mark()
        sent = say(a, room, f"Réponse par texto {nonce}")
        check("respondent's SMS answer is accepted by the bridge", bool(sent and sent.get("ok")), str(sent))
        time.sleep(5)
        # the host checks the voip.ms queue now (before !oubli erases everything about this caller)
        host_step("sms_queue", f"CALLER {caller}")
        m = a.mark()
        say(a, room, "!fin")
        check("!fin in an SMS room explains it is for web chats (use !stop / !oubli)",
              a.wait_message("seulement à un clavardage web", m, 30) is not None or a.wait_message("only applies to a web chat", m, 30) is not None)
        say(a, room, "!oubli")
        check("!oubli (right to erasure) erases the caller and closes the SMS room",
              a.wait(lambda e: e["event"] == "removed" and e.get("room") == room, 90, m) is not None)
        time.sleep(5)
        host_step("sms_erased", f"CALLER {caller}")


def sc_responder():
    """Answers a visitor driven from ANOTHER network (tests/suite.sh --outside): waits for the nonce, replies."""
    nonce = E["NONCE"]
    a = sim("a")
    print("READY", flush=True)
    m = 0
    got = a.wait_message(nonce, m, 240)
    check("respondent reads the message of the visitor from the outside network", got is not None)
    if got:
        room = got.get("room")
        print(f"ROOM outside {room}", flush=True)
        sent = say(a, room, f"pong {nonce}")
        check("respondent answers the outside visitor", bool(sent and sent.get("ok")), str(sent))
        a.wait(lambda e: e["event"] == "removed" and e.get("room") == room, 120, m)


def sc_devices():
    print("== Second device, !ok (private room)" + (", ban" if E.get("BAN_TEST") == "1" else ""), flush=True)
    a, b = sim("a"), sim("b")
    a2 = SIMS.get("a2") or lib.Sim(E["RESP_A"], f"suite-a2-{uuid.uuid4().hex[:4]}", settle=8)
    SIMS["a2"] = a2
    check("respondent A on a second device (phone + computer) logs in", a2.device is not None)
    nonce = uuid.uuid4().hex[:8]
    ma, mb, m2 = a.mark(), b.mark(), a2.mark()
    v = lib.Visitor(origin=lib.ORIGIN).start()
    v.open_stream()
    v.say(f"Deuxième conversation {nonce}")
    room = a2.wait_room(m2, 90)
    check("the second device is invited to the new chat", room is not None)
    check("the second device reads the message", a2.wait_message(nonce, m2, 90) is not None)
    check("the first device reads it too", a.wait_message(nonce, ma, 90) is not None)
    if not room:
        return
    sent = say(a2, room, f"Réponse depuis l'ordinateur {nonce}")
    check("the visitor receives the second device's answer", v.wait_text(f"depuis l'ordinateur {nonce}", 60) is not None, str(v.texts()))
    b.wait_room(mb, 30)
    mb = b.mark()
    m = a.mark()
    say(a, room, "!ok")
    check("!ok is acknowledged (private room)", a.wait_message("Salle privée", m, 30) is not None or a.wait_message("Private room", m, 30) is not None)
    check("!ok removes the other respondents", b.wait(lambda e: e["event"] == "removed" and e.get("room") == room, 60, mb) is not None)
    sent = say(a, room, f"Seulement moi {nonce}")
    check("the visitor can still be answered after !ok", v.wait_text(f"Seulement moi {nonce}", 60) is not None, str(v.texts()))
    if E.get("BAN_TEST") == "1":
        m = a.mark()
        say(a, room, "!bloquer 1")
        check("!bloquer ends the chat for the abusive visitor", v.wait_event("closed", 60), str(v.events[-3:]))
        status, body = lib.Visitor(origin=lib.ORIGIN)._req("POST", "/web/session", {})
        check("a banned visitor cannot open a new chat", status in (403, 429), f"{status} {body}")
        status, body = http_json(f"https://{E['SBCHAT_HOST']}/sbchat_api", {"command": "web_unban", "ip": "all"},
                                 headers={"Authorization": "Bearer " + E["ADMIN_TOKEN"]})
        check("SwitchBoard's web_unban lifts the ban", status == 200 and str(body.get("querystatus", "")).startswith("Success"), f"{status} {body}")
        check("the visitor can chat again", lib.Visitor(origin=lib.ORIGIN).start().token is not None)
    else:
        v.close_stream()
        v.end()


def user_room(s):
    for _ in range(10):
        for r in s.rooms():
            if "Salle Utilisateur" in (r.get("name") or "") and r.get("state") == "Joined":
                return r["room"]
        time.sleep(3)
    return None


def sc_team():
    """Agreement + messages from SwitchBoard; tests/suite.sh acts as SwitchBoard when it reads SIGNED."""
    print("== Agreement (Law 25) and messages from SwitchBoard", flush=True)
    a, b = sim("a"), sim("b")
    ra, rb = user_room(a), user_room(b)
    check("each respondent has a user room with the bridge", ra is not None and rb is not None, f"{ra} {rb}")
    if not ra:
        print("SIGNED", flush=True)
        return
    m = a.mark()
    say(a, ra, "!entente")
    text = a.wait(lambda e: e["event"] == "message" and "ENTENTE DE CONFIDENTIALITÉ" in e.get("body", ""), 60, m)
    check("!entente shows the confidentiality agreement", text is not None)
    check("the privacy officer is written into it", text is not None and E["PRIVACY_OFFICER"] in text["body"])
    m = a.mark()
    say(a, ra, "!signer Répondant Test")
    rec = a.wait(lambda e: e["event"] == "message" and "Entente de confidentialité signée" in e.get("body", ""), 120, m)
    check("!signer gives a receipt with the name and the account", rec is not None and "Répondant Test" in rec["body"] and E["RESP_A"] in rec["body"],
          (rec or {}).get("body", "")[:300])
    mb_ = b.mark()
    ma_ = a.mark()
    print("SIGNED", flush=True)
    check("SwitchBoard's 'send now' delivers the agreement to respondent B (not signed)",
          b.wait(lambda e: e["event"] == "message" and "ENTENTE DE CONFIDENTIALITÉ" in e.get("body", ""), 120, mb_) is not None)
    check("respondent A, who signed, does not get it again",
          not a.wait(lambda e: e["event"] == "message" and "Merci de lire et de signer" in e.get("body", ""), 10, ma_))
    note = E["NOTIFY"]
    check("a message from SwitchBoard reaches respondent A", a.wait_message(note, ma_, 120) is not None)
    check("a message from SwitchBoard reaches respondent B", b.wait_message(note, mb_, 120) is not None)


SCENARIOS = {"accounts": sc_accounts, "webchat": sc_webchat, "sms": sc_sms, "responder": sc_responder,
             "devices": sc_devices, "team": sc_team}
try:
    for name in sys.argv[1:]:
        try:
            SCENARIOS[name]()
        except Exception as e:  # a crash is a failure, never a skip
            check(f"scenario {name} ran to the end", False, repr(e))
finally:
    for s in SIMS.values():
        s.quit()
sys.exit(1 if failures else 0)
