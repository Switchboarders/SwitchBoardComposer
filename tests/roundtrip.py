"""One real web chat through the installed stack, with SwitchBoardChat's own e2e helpers (tests/e2e/lib.py):
a website visitor writes through https://<sb host>/web/, a simulated respondent (respondent-sim: a real Matrix
device, end-to-end encryption, logged in through MAS) is invited, reads the message and answers, and the
visitor receives the answer. Runs inside the sbcomposer-sim image on the "web" Docker network.

Environment: SB_HOST, MATRIX_HOST, RESPONDENT, RESPONDENT_PASSWORD, ORIGIN. Prints PASS/FAIL lines.
"""
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, "/e2e")
import lib  # noqa: E402  (SwitchBoardChat tests/e2e/lib.py)

lib.SYNAPSE = "https://" + os.environ["MATRIX_HOST"]
lib.BRIDGE = "https://" + os.environ["SB_HOST"]
lib.ORIGIN = os.environ["ORIGIN"]
lib.PASSWORD = os.environ["RESPONDENT_PASSWORD"]
lib.SIM = Path("/usr/local/bin/respondent-sim")
lib.WORK = Path("/tmp/work")
lib.WORK.mkdir(parents=True, exist_ok=True)

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok or not detail else f"  ({detail[:300]})"), flush=True)
    if not ok:
        failures += 1
    return ok


nonce = uuid.uuid4().hex[:8]
sim = None
visitor = None
try:
    sim = lib.Sim(os.environ["RESPONDENT"], "sbcomposer-respondent", cross_sign=True, settle=5)
    check("respondent logs in through MAS and syncs (end-to-end encryption ready)", True)
    mark = sim.mark()
    visitor = lib.Visitor(origin=lib.ORIGIN).start()
    visitor.open_stream()
    status, body = visitor.say(f"Bonjour, test d'installation {nonce}")
    check("visitor's message accepted by the bridge (https://<sb host>/web/)", status == 200, f"{status} {body}")
    room = sim.wait_room(mark, 90)
    check("the bridge creates a room and invites the respondent", room is not None)
    got = sim.wait_message(nonce, mark, 90)
    check("the respondent reads (decrypts) the visitor's message", got is not None,
          f"events={[e['event'] for e in sim.events[mark:]]}")
    utd = [e for e in sim.events if e["event"] == "utd"]
    check("no undecryptable message in the chat room", not [e for e in utd if e.get("room") == room],
          str([e for e in utd if e.get("room") == room]))
    older = [e for e in utd if e.get("room") != room]
    if older:
        # This device is new: messages sent before it existed (e.g. the bridge's earlier notes in the
        # respondent's own room) cannot be decrypted by it, exactly as for a new Element session.
        print(f"INFO  {len(older)} older message(s) in other rooms, sent before this device existed", flush=True)
    if room:
        sent = sim.send(room, f"Réponse du répondant {nonce}")
        check("the respondent's answer is sent", bool(sent and sent.get("ok")), str(sent))
        check("the visitor receives the answer", visitor.wait_text(f"Réponse du répondant {nonce}", 60) is not None,
              str(visitor.texts()))
    status, _ = visitor.end()
    check("the visitor ends the chat", status == 200, str(status))
    if room:
        removed = sim.wait(lambda e: e["event"] == "removed" and e.get("room") == room, 60, mark)
        check("the room is closed for the respondent", removed is not None)
except Exception as e:  # a crash is a failure, never a skip
    check("round trip ran to the end", False, repr(e))
finally:
    if visitor:
        visitor.close_stream()
    if sim:
        sim.quit()
    time.sleep(1)

sys.exit(1 if failures else 0)
