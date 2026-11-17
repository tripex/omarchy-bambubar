"""Tests for bin/bambubar-bridge. Run with: python3 -m unittest discover -s tests"""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import queue
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bin", "bambubar-bridge")


def load_bridge():
    loader = importlib.machinery.SourceFileLoader("bambubar_bridge", BRIDGE)
    spec = importlib.util.spec_from_loader("bambubar_bridge", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


bridge = load_bridge()


class PacketTests(unittest.TestCase):
    def test_remaining_length_round_trip(self):
        for size in (0, 1, 127, 128, 16383, 16384, 300000):
            buf = bytearray(bridge.mqtt_packet(0x30, b"x" * size))
            packets = bridge.take_packets(buf)
            self.assertEqual(len(packets), 1)
            self.assertEqual(len(packets[0][1]), size)
            self.assertEqual(buf, b"")

    def test_partial_packets_wait_for_more_data(self):
        whole = bridge.publish_packet("a/b", b"{}") + bridge.mqtt_packet(0xD0, b"")
        buf = bytearray()
        got = []
        for i in range(len(whole)):
            buf.append(whole[i])
            got += bridge.take_packets(buf)
        self.assertEqual([p[0] for p in got], [0x30, 0xD0])
        self.assertEqual(bridge.parse_publish(*got[0]), ("a/b", b"{}"))

    def test_malformed_length_is_an_error(self):
        with self.assertRaises(bridge.ProtocolError):
            bridge.take_packets(bytearray(b"\x30\xff\xff\xff\xff\x01"))

    def test_qos1_publish_skips_packet_id(self):
        body = bridge.mqtt_string("t") + b"\x00\x07" + b"payload"
        self.assertEqual(bridge.parse_publish(0x32, body), ("t", b"payload"))


class ReportTests(unittest.TestCase):
    def test_partial_updates_only_touch_present_keys(self):
        s = bridge.new_printer_state()
        bridge.apply_report(s, {"gcode_state": "RUNNING", "mc_percent": 12, "subtask_name": "Benchy"})
        bridge.apply_report(s, {"mc_percent": 13, "nozzle_temper": 219.64})
        self.assertEqual((s["gcodeState"], s["percent"], s["job"], s["nozzle"]), ("RUNNING", 13, "Benchy", 219.6))

    def test_untrusted_values_are_bounded(self):
        s = bridge.new_printer_state()
        bridge.apply_report(s, {
            "gcode_state": "<b>x</b>", "mc_percent": 900, "layer_num": True,
            "bed_temper": "60", "subtask_name": "a\nb\x00c" + "x" * 500,
        })
        self.assertEqual(s["gcodeState"], "")
        self.assertEqual(s["percent"], 100)
        self.assertEqual(s["layer"], 0)
        self.assertEqual(s["bed"], 0.0)
        self.assertEqual(s["job"][:5], "a b c")
        self.assertEqual(len(s["job"]), 120)

    def test_ams_units_merge_and_sort(self):
        s = bridge.new_printer_state()
        bridge.apply_report(s, {"ams": {"ams": [{"id": "1", "humidity": "2"}, {"id": "0", "humidity": "4", "humidity_raw": "24"}]}})
        bridge.apply_report(s, {"ams": {"ams": [{"id": "1", "humidity_raw": "61"}, {"id": "../x", "humidity": "1"}]}})
        self.assertEqual(s["ams"], [
            {"id": "0", "level": 4, "percent": 24, "trays": []},
            {"id": "1", "level": 2, "percent": 61, "trays": []},
        ])


class FakePrinter:
    """A TLS MQTT broker that behaves like a Bambu Lab printer."""

    def __init__(self, certdir, code="12345678", serial="01P00A123456789"):
        self.code = code
        self.serial = serial
        self.received = queue.Queue()
        self.use_cert(certdir)
        self.server = socket.create_server(("127.0.0.1", 0))
        self.port = self.server.getsockname()[1]
        self.connections = 0
        threading.Thread(target=self.serve, daemon=True).start()

    def use_cert(self, certdir):
        """New connections present this certificate (a reset printer, or another device)."""
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.path.join(certdir, "cert.pem"), os.path.join(certdir, "key.pem"))
        self.ctx = ctx

    def serve(self):
        while True:
            try:
                raw, _ = self.server.accept()
            except OSError:
                return
            self.connections += 1
            threading.Thread(target=self.session, args=(raw,), daemon=True).start()

    def session(self, raw):
        try:
            self.converse(self.ctx.wrap_socket(raw, server_side=True))
        except (OSError, ssl.SSLError):
            pass  # the bridge hung up

    def converse(self, conn):
        buf = bytearray()
        with conn:
            while True:
                data = conn.recv(65536)
                if not data:
                    return
                buf.extend(data)
                for first, body in bridge.take_packets(buf):
                    kind = first >> 4
                    if kind == 1:
                        password = self.connect_password(body)
                        self.received.put(("connect", password))
                        ok = password == self.code
                        conn.sendall(bytes([0x20, 0x02, 0x00, 0x00 if ok else 0x05]))
                        if not ok:
                            return
                    elif kind == 8:
                        topic = body[4:4 + int.from_bytes(body[2:4], "big")].decode()
                        self.received.put(("subscribe", topic))
                        conn.sendall(bytes([0x90, 0x03]) + body[0:2] + b"\x00")
                    elif kind == 3:
                        topic, payload = bridge.parse_publish(first, body)
                        self.received.put(("publish", topic, payload))
                        report = {"print": {"gcode_state": "RUNNING", "mc_percent": 42, "subtask_name": "Benchy",
                                            "ams": {"ams": [{"id": "0", "humidity": "4", "humidity_raw": "24"}]}}}
                        conn.sendall(bridge.publish_packet("device/%s/report" % self.serial, json.dumps(report).encode()))

    @staticmethod
    def connect_password(body):
        i = 10  # past protocol name, level, flags and keepalive
        fields = []
        for _ in range(3):  # client id, user, password
            n = int.from_bytes(body[i:i + 2], "big")
            fields.append(body[i + 2:i + 2 + n].decode())
            i += 2 + n
        return fields[2]

    def close(self):
        self.server.close()


def make_cert(directory, common_name):
    """A certificate shaped like a printer's: issued by a "BBL CA", naming the serial."""
    os.makedirs(directory)
    p = lambda name: os.path.join(directory, name)

    def run(*args):
        subprocess.run(["openssl", *args], check=True, capture_output=True)

    run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/O=BBL Technologies Co., Ltd/CN=BBL CA", "-keyout", p("ca.key"), "-out", p("ca.pem"))
    run("req", "-newkey", "rsa:2048", "-nodes", "-subj", "/C=CN/O=BBL/CN=" + common_name,
        "-keyout", p("key.pem"), "-out", p("req.csr"))
    run("x509", "-req", "-in", p("req.csr"), "-CA", p("ca.pem"), "-CAkey", p("ca.key"),
        "-CAcreateserial", "-days", "1", "-out", p("cert.pem"))
    return directory


SERIAL = "01P00A123456789"


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class CertificateTests(unittest.TestCase):
    def test_reads_the_subject_not_the_issuer(self):
        tmp = tempfile.mkdtemp()
        try:
            make_cert(os.path.join(tmp, "c"), SERIAL)
            with open(os.path.join(tmp, "c", "cert.pem")) as f:
                der = ssl.PEM_cert_to_DER_cert(f.read())
            self.assertEqual(bridge.cert_common_name(der), SERIAL)
        finally:
            shutil.rmtree(tmp)

    def test_garbage_has_no_name(self):
        for der in (b"", b"\x30", b"\x30\x84\xff\xff\xff\xff", b"\x30\x03\x02\x01\x00"):
            self.assertEqual(bridge.cert_common_name(der), "")


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.printer = FakePrinter(make_cert(os.path.join(self.tmp, "printer"), SERIAL), serial=SERIAL)
        self.events = queue.Queue()
        self.keyring = {}
        self.saved = dict(PORT=bridge.PORT, CONFIG_FILE=bridge.CONFIG_FILE, STATS_FILE=bridge.STATS_FILE,
                          emit=bridge.emit, keyring_lookup=bridge.keyring_lookup, keyring_store=bridge.keyring_store)
        bridge.PORT = self.printer.port
        bridge.CONFIG_FILE = os.path.join(self.tmp, "config", "printer.json")
        bridge.STATS_FILE = os.path.join(self.tmp, "state", "stats.json")
        bridge.emit = self.events.put
        bridge.keyring_lookup = lambda serial: self.keyring.get(serial, "")
        bridge.keyring_store = lambda serial, code: self.keyring.__setitem__(serial, code) or True
        self.stop = threading.Event()
        self.commands = queue.Queue()

    def tearDown(self):
        self.stop.set()
        self.commands.put({"op": "wake"})
        if hasattr(self, "thread"):
            self.thread.join(5)
        self.printer.close()
        for name, value in self.saved.items():
            setattr(bridge, name, value)
        shutil.rmtree(self.tmp)

    def start(self):
        self.thread = threading.Thread(target=bridge.Bridge(self.stop, self.commands).run, daemon=True)
        self.thread.start()

    def wait_for(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=0.2)
            except queue.Empty:
                continue
            if predicate(event):
                return event
        self.fail("event did not arrive")

    def configure(self, code):
        self.commands.put({"op": "configure", "host": "127.0.0.1", "serial": self.printer.serial.lower(), "accessCode": code})

    def test_unconfigured_then_configure_connects_and_reports(self):
        self.start()
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "notConfigured")
        self.configure("12345678")
        self.assertTrue(self.wait_for(lambda e: e.get("ev") == "saved")["ok"])
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "connected")
        state = self.wait_for(lambda e: e.get("ev") == "state" and e["gcodeState"] == "RUNNING")
        self.assertEqual((state["percent"], state["job"]), (42, "Benchy"))
        self.assertEqual(state["ams"], [{"id": "0", "level": 4, "percent": 24, "trays": []}])

        seen = [self.printer.received.get(timeout=5) for _ in range(3)]
        self.assertEqual(seen[0], ("connect", "12345678"))
        self.assertEqual(seen[1], ("subscribe", "device/01P00A123456789/report"))
        self.assertEqual(seen[2][:2], ("publish", "device/01P00A123456789/request"))
        self.assertEqual(json.loads(seen[2][2])["pushing"]["command"], "pushall")

        # Saved for the next start: serial and pinned certificate in the config
        # file, the code only in the keyring.
        with open(bridge.CONFIG_FILE) as f:
            self.assertEqual(json.load(f), {"host": "127.0.0.1", "serial": SERIAL,
                                            "fingerprint": self.cert_fingerprint("printer")})
        self.assertEqual(self.keyring, {SERIAL: "12345678"})

    def test_wrong_code_is_denied_without_retrying(self):
        self.start()
        self.configure("wrong")
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "denied")
        time.sleep(bridge.RECONNECT_SEC + 1)
        self.assertEqual(self.printer.connections, 1)

    def test_rejects_serial_that_would_change_the_topic(self):
        self.start()
        self.commands.put({"op": "configure", "host": "127.0.0.1", "serial": "#", "accessCode": "x"})
        self.assertEqual(self.wait_for(lambda e: e.get("ev") == "saved")["error"], "invalid-serial")

    def test_empty_code_keeps_the_stored_one(self):
        self.keyring["01P00A123456789"] = "12345678"
        self.start()
        self.configure("")
        self.assertTrue(self.wait_for(lambda e: e.get("ev") == "saved")["ok"])
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "connected")


    # -- certificate pinning

    def cert_fingerprint(self, name):
        with open(os.path.join(self.tmp, name, "cert.pem")) as f:
            return hashlib.sha256(ssl.PEM_cert_to_DER_cert(f.read())).hexdigest()

    def codes_sent(self):
        sent = []
        while True:
            try:
                item = self.printer.received.get_nowait()
            except queue.Empty:
                return sent
            if item[0] == "connect":
                sent.append(item[1])

    def connect_and_pin(self):
        self.start()
        self.configure("12345678")
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "connected")
        self.assertEqual(self.codes_sent(), ["12345678"])

    def test_changed_certificate_gets_no_code_until_trusted(self):
        self.connect_and_pin()
        self.printer.use_cert(make_cert(os.path.join(self.tmp, "reset"), SERIAL))
        self.configure("")  # reconnect
        status = self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "untrusted")
        self.assertEqual(status["detail"], SERIAL)
        self.assertEqual(self.codes_sent(), [])

        self.commands.put({"op": "trust"})
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "connected")
        self.assertEqual(self.codes_sent(), ["12345678"])
        with open(bridge.CONFIG_FILE) as f:
            self.assertEqual(json.load(f)["fingerprint"], self.cert_fingerprint("reset"))

    def test_other_device_at_the_address_gets_no_code(self):
        self.printer.use_cert(make_cert(os.path.join(self.tmp, "other"), "01P00A999999999"))
        self.start()
        self.configure("12345678")
        status = self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "wrongPrinter")
        self.assertEqual(status["detail"], "01P00A999999999")
        self.commands.put({"op": "trust"})  # trusting can't override the serial check
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "wrongPrinter")
        time.sleep(1)
        self.assertEqual(self.codes_sent(), [])

    def test_new_address_keeps_the_pin(self):
        self.connect_and_pin()
        self.commands.put({"op": "configure", "host": "localhost", "serial": SERIAL, "accessCode": ""})
        config = self.wait_for(lambda e: e.get("ev") == "config" and e["host"] == "localhost")
        self.assertEqual(config["fingerprint"], self.cert_fingerprint("printer"))
        self.wait_for(lambda e: e.get("ev") == "status" and e["status"] == "connected")


# Trimmed from a real X2D report (greghesp/ha-bambulab, MOCK-X2D.json).
X2D_REPORT = {
    "gcode_state": "RUNNING", "mc_percent": 98, "nozzle_temper": 250.0, "nozzle_target_temper": 250.0,
    "ams": {"tray_now": "1", "ams": [{"id": "0", "humidity": "5", "humidity_raw": "12", "tray": [
        {"id": "0", "tray_type": "PLA", "tray_sub_brands": "", "tray_color": "161616FF", "cols": ["161616FF"]},
        {"id": "1", "tray_type": "PETG", "tray_sub_brands": "", "tray_color": "161616FF", "cols": ["161616FF"]},
        {"id": "2", "tray_type": "PLA", "tray_sub_brands": "", "tray_color": "FFFFFFFF", "cols": ["FFFFFFFF"]},
        {"id": "3"},
    ]}]},
    "vir_slot": [{"id": "254", "tray_type": "", "tray_color": "00000000"},
                 {"id": "255", "tray_type": "", "tray_color": "00000000"}],
    "device": {"extruder": {"state": 33042, "info": [
        {"id": 0, "snow": 65535, "temp": 50},
        {"id": 1, "snow": 1, "temp": 16384250},
    ]}},
}


class DualNozzleAndSpoolTests(unittest.TestCase):
    def test_x2d_report(self):
        s = bridge.apply_report(bridge.new_printer_state(), X2D_REPORT)
        self.assertEqual([(n["id"], n["temp"], n["target"]) for n in s["nozzles"]], [(0, 50, 0), (1, 250, 250)])
        self.assertEqual(s["activeNozzle"], 1)
        self.assertEqual(bridge.active_spool(s), {"ams": "0", "tray": "1"})
        trays = s["ams"][0]["trays"]
        self.assertEqual([(t["type"], t["colors"], t["empty"]) for t in trays], [
            ("PLA", ["#161616"], False), ("PETG", ["#161616"], False),
            ("PLA", ["#FFFFFF"], False), ("", [], True),
        ])
        self.assertEqual([(t["id"], t["empty"]) for t in s["external"]], [("254", True), ("255", True)])

    def test_switching_nozzles_keeps_the_last_active_one(self):
        s = bridge.apply_report(bridge.new_printer_state(), X2D_REPORT)
        bridge.apply_report(s, {"device": {"extruder": {"state": 0xF2}}})
        self.assertEqual(s["activeNozzle"], 1)
        bridge.apply_report(s, {"device": {"extruder": {"state": 0x02, "info": [{"id": 0, "snow": 0x0102}]}}})
        self.assertEqual(bridge.active_spool(s), {"ams": "1", "tray": "2"})

    def test_single_nozzle_tray_now(self):
        for now, expected in (("255", None), ("254", {"external": "254"}), ("5", {"ams": "1", "tray": "1"}),
                              ("128", {"ams": "128", "tray": "0"})):
            s = bridge.apply_report(bridge.new_printer_state(), {"ams": {"tray_now": now}})
            self.assertEqual(bridge.active_spool(s), expected, now)

    def test_tray_updates_merge_and_bound(self):
        s = bridge.new_printer_state()
        bridge.apply_report(s, {"vt_tray": {"id": "254", "tray_type": "TPU", "cols": ["FF0000FF", "0000FFFF", "nope"]}})
        bridge.apply_report(s, {"vt_tray": {"id": "254", "tray_sub_brands": "<b>Flex</b>" + "x" * 50}})
        t = s["external"][0]
        self.assertEqual((t["type"], t["colors"], t["empty"]), ("TPU", ["#FF0000", "#0000FF"], False))
        self.assertEqual(len(t["name"]), 24)
        bridge.apply_report(s, {"vt_tray": {"id": "254"}})
        self.assertTrue(s["external"][0]["empty"])


if __name__ == "__main__":
    unittest.main()
