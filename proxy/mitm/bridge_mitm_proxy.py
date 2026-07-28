#!/usr/bin/env python3
"""
Bridge MITM Proxy — intercepts VolumetricaBridge ↔ CQG WebAPI WebSocket.
Patches logon credentials and logs every protobuf message in both directions.
"""
# made by illnoobis
import asyncio
import os
import logging
import ssl
import struct
import sys
import time
from datetime import datetime, timezone, timedelta
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import config

# ─── Configuration ─────────────────────────────────────────────────────────────
# Auto-resolve upstream CQG IP. Handles all launch paths (VBS, PS1, Deepchart.exe).
import socket as _rs, subprocess as _sp
_CQG_UPSTREAM_IP = (os.environ.get("CQG_UPSTREAM_IP") or
    os.environ.get("REAL_CQG_HOST") or "")
if not _CQG_UPSTREAM_IP:
    try:
        _resolved = _rs.getaddrinfo(config.SNI_HOST, config.REAL_CQG_PORT, _rs.AF_INET)[0][4][0]
        if _resolved != "127.0.0.1":
            _CQG_UPSTREAM_IP = _resolved
    except Exception:
        pass
if not _CQG_UPSTREAM_IP or _CQG_UPSTREAM_IP == "127.0.0.1":
    try:
        _out = _sp.run(["nslookup", config.SNI_HOST, "8.8.8.8"], capture_output=True, text=True, timeout=5)
        for _l in _out.stdout.splitlines():
            _p = _l.strip()
            if "Address:" in _p:
                _ip = _p.split("Address:")[-1].strip()
                if _ip.count(".") == 3 and all(c.isdigit() for c in _ip.replace(".","")):
                    _CQG_UPSTREAM_IP = _ip; break
    except Exception:
        pass
if not _CQG_UPSTREAM_IP or _CQG_UPSTREAM_IP == "127.0.0.1":
    _CQG_UPSTREAM_IP = config.REAL_CQG_HOST

PROXY_PORT          = int(os.environ.get("BRIDGE_PROXY_PORT", str(config.BRIDGE_PROXY_PORT)))
REAL_CQG_HOST       = os.environ.get("CQG_UPSTREAM_IP", config.REAL_CQG_HOST)
REAL_CQG_PORT       = int(os.environ.get("REAL_CQG_PORT", str(config.REAL_CQG_PORT)))
SNI_HOST            = os.environ.get("SNI_HOST", config.SNI_HOST)

TARGET_PRIVATE_LABEL  = os.environ.get("TARGET_PRIVATE_LABEL", config.TARGET_PRIVATE_LABEL)
TARGET_CLIENT_APP_ID  = os.environ.get("TARGET_CLIENT_APP_ID", config.TARGET_CLIENT_APP_ID)
TARGET_CLIENT_VERSION = config.TARGET_CLIENT_VERSION
CQG_USERNAME          = config.CQG_USERNAME
CQG_PASSWORD          = config.CQG_PASSWORD

CA_DIR   = config.CA_DIR
CA_CERT  = config.CA_CERT
CA_KEY   = config.CA_KEY
CERT     = config.CERT
KEY      = config.KEY_ENV

log = logging.getLogger("bridge-mitm")

def cleanup_old_logs(log_dir: str, pattern: str, keep: int = 10):
    """Remove old log files, keeping only the most recent `keep` files."""
    try:
        files = sorted(
            (f for f in os.listdir(log_dir) if f.startswith(pattern.replace("*", ""))),
            key=lambda f: os.path.getmtime(os.path.join(log_dir, f)),
            reverse=True
        )
        for old in files[keep:]:
            try:
                os.remove(os.path.join(log_dir, old))
                log.info(f"[CLEANUP] Removed old log: {old}")
            except Exception as e:
                log.debug(f"[CLEANUP] Failed to remove {old}: {e}")
    except Exception as e:
        log.debug(f"[CLEANUP] Failed to clean old logs: {e}")

def setup_logging():
    """Initialize logging at runtime (not import time)."""
    os.makedirs(config.LOG_DIR, exist_ok=True)
    
    # Cleanup old logs (keep last 10 sessions)
    cleanup_old_logs(config.LOG_DIR, "bridge_mitm_", keep=10)
    
    LOGFILE = os.path.join(config.LOG_DIR, f"bridge_mitm_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.log")

    log_level = getattr(logging, config.LOG_LEVEL.upper(), logging.DEBUG)
    _file_handler = logging.FileHandler(LOGFILE, encoding="utf-8")
    _file_handler.setLevel(logging.DEBUG)
    _stream_handler = logging.StreamHandler(sys.stdout)
    _stream_handler.setLevel(logging.INFO)

    _fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    _file_handler.setFormatter(_fmt)
    _stream_handler.setFormatter(_fmt)

    log.setLevel(log_level)
    log.addHandler(_file_handler)
    log.addHandler(_stream_handler)
    log.propagate = False
    return LOGFILE

# ─── Protobuf imports ──────────────────────────────────────────────────────────
PROTOBUF_AVAILABLE = False

_meipass = getattr(sys, '_MEIPASS', None)
_try_search = [None]
if _meipass:
    _try_search.append(_meipass)
_try_search.append(os.path.dirname(os.path.abspath(__file__)))
for _try_path in _try_search:
    if _try_path and _try_path not in sys.path:
        sys.path.insert(0, _try_path)
    try:
        from WebAPI.webapi_2_pb2 import ClientMsg, ServerMsg, InformationReport
        from WebAPI.user_session_2_pb2 import LogonResult, Ping, Pong
        from WebAPI.historical_2_pb2 import TimeBarReport, TimeBarRequest
        from WebAPI.market_data_2_pb2 import (
            MarketDataSubscription, MarketDataSubscriptionStatus, RealTimeMarketData, Quote
        )
        PROTOBUF_AVAILABLE = True
        log.info(f"[IMPORT] CQG protobufs loaded successfully")
        break
    except ImportError as _imp_err:
        if _try_path and _try_path in sys.path:
            sys.path.remove(_try_path)
        log.warning(f"[IMPORT] ImportError from {_try_path}: {_imp_err}")
    except Exception as _exc_err:
        if _try_path and _try_path in sys.path:
            sys.path.remove(_try_path)
        log.warning(f"[IMPORT] Error from {_try_path}: {_exc_err}")

# Fallback: try repo-relative paths from __file__
if not PROTOBUF_AVAILABLE:
    _reporoot = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for _path in [os.path.join(_reporoot, "proxy", "cqg"), os.path.join(_reporoot, "cqg_test")]:
        if os.path.isdir(_path):
            sys.path.insert(0, os.path.abspath(_path))
            try:
                from WebAPI.webapi_2_pb2 import ClientMsg, ServerMsg, InformationReport
                from WebAPI.user_session_2_pb2 import LogonResult, Ping, Pong
                from WebAPI.historical_2_pb2 import TimeBarReport, TimeBarRequest
                from WebAPI.market_data_2_pb2 import (
                    MarketDataSubscription, MarketDataSubscriptionStatus, RealTimeMarketData, Quote
                )
                PROTOBUF_AVAILABLE = True
                log.info(f"[IMPORT] CQG protobufs loaded from: {_path}")
                break
            except Exception as _e:
                log.warning(f"[IMPORT] Failed from {_path}: {_e}")
                if os.path.abspath(_path) in sys.path:
                    sys.path.remove(os.path.abspath(_path))

if not PROTOBUF_AVAILABLE:
    log.error("[!] CQG protobufs NOT found — patching and decoding will NOT work!")




# ─── CA / Certificate management ───────────────────────────────────────────────
def ensure_ca():
    os.makedirs(CA_DIR, exist_ok=True)
    ca_exists  = os.path.exists(CA_CERT) and os.path.exists(CA_KEY)
    srv_exists = os.path.exists(CERT)    and os.path.exists(KEY)

    if ca_exists and srv_exists:
        log.info("[CA] Using existing CA and server certificates.")
        return

    now = datetime.now(timezone.utc)

    if ca_exists:
        log.info("[CA] Loading existing CA …")
        try:
            with open(CA_CERT, "rb") as f: ca_cert = x509.load_pem_x509_certificate(f.read())
            with open(CA_KEY,  "rb") as f: ca_key  = serialization.load_pem_private_key(f.read(), password=None)
        except Exception as e:
            log.warning(f"[CA] Failed to load existing CA ({e}), regenerating …")
            ca_exists = False

    if not ca_exists:
        log.info("[CA] Generating new CA …")
        ca_key  = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Bridge MITM CA")])
        ca_cert = (
            x509.CertificateBuilder()
            .subject_name(ca_name).issuer_name(ca_name)
            .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=3650))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(ca_key, hashes.SHA256())
        )
        with open(CA_CERT, "wb") as f: f.write(ca_cert.public_bytes(serialization.Encoding.PEM))
        with open(CA_KEY,  "wb") as f: f.write(ca_key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
        log.info(f"[CA] CA saved to {CA_CERT}")

    if not srv_exists:
        log.info("[CA] Generating server certificate …")
        srv_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        csr = (
            x509.CertificateSigningRequestBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, SNI_HOST)]))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(SNI_HOST), x509.DNSName(config.ADDITIONAL_SNI)]), critical=False)
            .sign(srv_key, hashes.SHA256())
        )
        srv_cert = (
            x509.CertificateBuilder()
            .subject_name(csr.subject).issuer_name(ca_cert.subject)
            .public_key(csr.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=3650))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(SNI_HOST), x509.DNSName(config.ADDITIONAL_SNI)]), critical=False)
            .sign(ca_key, hashes.SHA256())
        )
        with open(CERT, "wb") as f: f.write(srv_cert.public_bytes(serialization.Encoding.PEM))
        with open(KEY,  "wb") as f: f.write(srv_key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
        log.info("[CA] Server certificate generated.")


# ─── WebSocket frame builder ────────────────────────────────────────────────────
def build_ws_frame(opcode: int, payload: bytes, fin: int = 1, mask: bool = True) -> bytes:
    hdr = bytearray([(0x80 if fin else 0) | opcode])
    mask_bit = 0x80 if mask else 0
    plen = len(payload)
    if plen < 126:
        hdr.append(mask_bit | plen)
    elif plen < 65536:
        hdr.extend([mask_bit | 126, (plen >> 8) & 0xFF, plen & 0xFF])
    else:
        hdr.extend([mask_bit | 127] + list(struct.pack(">Q", plen)))
    if mask:
        mk = os.urandom(4)
        hdr.extend(mk)
        return bytes(hdr) + bytes(b ^ mk[i % 4] for i, b in enumerate(payload))
    return bytes(hdr) + payload


# ─── WebSocket frame extractor ──────────────────────────────────────────────────
class FrameBuffer:
    def __init__(self): self.buf = bytearray()
    def feed(self, data: bytes): self.buf.extend(data)

    def extract_frame(self):
        if len(self.buf) < 2: return None
        b0, b1  = self.buf[0], self.buf[1]
        fin     = (b0 >> 7) & 1
        opcode  = b0 & 0x0F
        masked  = (b1 >> 7) & 1
        plen    = b1 & 0x7F
        pos     = 2
        if plen == 126:
            if len(self.buf) < pos + 2: return None
            plen = struct.unpack(">H", self.buf[pos:pos+2])[0]; pos += 2
        elif plen == 127:
            if len(self.buf) < pos + 8: return None
            plen = struct.unpack(">Q", self.buf[pos:pos+8])[0]; pos += 8
        mask_key = None
        if masked:
            if len(self.buf) < pos + 4: return None
            mask_key = bytes(self.buf[pos:pos+4]); pos += 4
        if len(self.buf) < pos + plen: return None
        payload   = bytes(self.buf[pos : pos + plen])
        raw_frame = bytes(self.buf[:pos + plen])
        self.buf  = self.buf[pos + plen:]
        return opcode, masked, mask_key, payload, raw_frame, fin


# ─── Protobuf decoders ──────────────────────────────────────────────────────────
def log_client_msg(payload: bytes, mask_key: bytes):
    """Decode and log a ClientMsg (client→CQG direction). Always returns None."""
    if not PROTOBUF_AVAILABLE: return None
    try:
        raw = bytearray(payload)
        for i in range(len(raw)): raw[i] ^= mask_key[i % 4]
        msg = ClientMsg()
        msg.ParseFromString(bytes(raw))

        if msg.HasField("logon"):
            g = msg.logon
            log.info(f"  [C->S] LOGON: user='{g.user_name}' private_label='{g.private_label}' "
                     f"client_app_id='{g.client_app_id}' version='{g.client_version}'")

        if msg.HasField("logoff"):
            log.info("  [C->S] LOGOFF requested by client")

        if msg.HasField("ping"):
            log.debug("  [C->S] PING")

        if msg.HasField("pong"):
            log.debug("  [C->S] PONG")

        for req in msg.market_data_subscriptions:
            log.info(f"  [C->S] MARKET_DATA_SUBSCRIBE: contract_id={req.contract_id} "
                     f"request_id={req.request_id} level={req.level}")

        for req in msg.time_bar_requests:
            p = req.time_bar_parameters if req.HasField("time_bar_parameters") else None
            if p:
                log.info(f"  [C->S] TIME_BAR_REQUEST: request_id={req.request_id} "
                         f"contract_id={p.contract_id} bar_unit={p.bar_unit} "
                         f"unit_number={p.unit_number} "
                         f"from={p.from_utc_time} to={p.to_utc_time} "
                         f"request_type={req.request_type}")
            else:
                log.info(f"  [C->S] TIME_BAR_REQUEST: request_id={req.request_id} (no params)")

        for req in msg.non_timed_bar_requests:
            log.info(f"  [C->S] NON_TIMED_BAR_REQUEST: request_id={req.request_id}")

        for req in msg.time_and_sales_requests:
            log.info(f"  [C->S] TIME_AND_SALES_REQUEST: request_id={req.request_id}")

        for req in msg.information_requests:
            log.info(f"  [C->S] INFORMATION_REQUEST: id={req.id} subscribe={req.subscribe}")

        for req in msg.trade_subscriptions:
            log.info(f"  [C->S] TRADE_SUBSCRIPTION: id={req.id}")

        for req in msg.order_requests:
            log.info(f"  [C->S] ORDER_REQUEST: id={req.request_id}")

    except Exception as e:
        unmasked = bytearray(payload)
        for i in range(len(unmasked)): unmasked[i] ^= mask_key[i % 4]
        log.warning(f"  [C->S] Could not decode ClientMsg: {e}")
        log.warning(f"  [C->S]   masked_hex={payload.hex()}")
        log.warning(f"  [C->S]   unmasked_hex={bytes(unmasked[:48]).hex()}")


def build_pong_response(payload: bytes, mask_key: bytes):
    """
    Parse a client binary frame and if it contains a Ping (field 107),
    build a ServerMsg Pong response frame. Returns the frame bytes, or None.
    """
    if not PROTOBUF_AVAILABLE:
        return None
    try:
        raw = bytearray(payload)
        for i in range(len(raw)): raw[i] ^= mask_key[i % 4]
        msg = ClientMsg()
        msg.ParseFromString(bytes(raw))
        if not msg.HasField("ping"):
            return None
        ping = msg.ping
        now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        sm = ServerMsg()
        sm.pong.token = ping.token if ping.HasField("token") else ""
        sm.pong.ping_utc_time = ping.ping_utc_time
        sm.pong.pong_utc_time = now_ms
        log.debug("  [PATCH] Injecting local PONG for client PING")
        return build_ws_frame(2, sm.SerializeToString(), fin=1, mask=False)
    except Exception as e:
        log.error(f"  [PATCH] Failed to build PONG response: {e}")
        return None


LOGON_MIN_INTERVAL = 15
_last_logon_time = [0.0]

# ─── Base-time tracker (for TimeBar fix) ──────────────────────────────────────
_base_time_epoch_ms = [0]
_logon_captured = [False]

def _parse_base_time(base_time_str: str) -> int:
    """Parse CQG base_time string like '2026-07-15T01:52:50' into epoch ms."""
    try:
        dt = datetime.fromisoformat(base_time_str.replace("Z", "+00:00"))
        return int(dt.timestamp() * 1000)
    except Exception:
        return 0

# ─── Logon patcher ─────────────────────────────────────────────────────────────
def patch_logon_protobuf(payload: bytes, mask_key: bytes, fin: int, opcode: int):
    raw = bytearray(payload)
    for i in range(len(raw)): raw[i] ^= mask_key[i % 4]
    msg = ClientMsg()
    try:
        msg.ParseFromString(bytes(raw))
        if msg.HasField("logon"):
            old_pl = msg.logon.private_label
            old_ci = msg.logon.client_app_id
            old_un = msg.logon.user_name
            old_pw = msg.logon.password
            msg.logon.private_label  = TARGET_PRIVATE_LABEL
            msg.logon.client_app_id  = TARGET_CLIENT_APP_ID
            if msg.logon.client_version:
                msg.logon.client_version = TARGET_CLIENT_VERSION
            if CQG_USERNAME:
                msg.logon.user_name = CQG_USERNAME
            if CQG_PASSWORD:
                msg.logon.password = CQG_PASSWORD
            log.info("  [PATCH] *** LOGON INTERCEPTED AND PATCHED ***")
            log.info(f"  [PATCH] private_label : '{old_pl}' -> '{TARGET_PRIVATE_LABEL}'")
            log.info(f"  [PATCH] client_app_id : '{old_ci}' -> '{TARGET_CLIENT_APP_ID}'")
            log.info(f"  [PATCH] client_version: -> '{TARGET_CLIENT_VERSION}'")
            if CQG_USERNAME:
                log.info(f"  [PATCH] user_name    : '{old_un}' -> '{CQG_USERNAME}'")
            if CQG_PASSWORD:
                log.info(f"  [PATCH] password     : (patched)")
            return build_ws_frame(opcode, msg.SerializeToString(), fin=fin, mask=True)
    except Exception as e:
        log.error(f"  [PATCH] Failed to parse/patch logon: {e}")
    return None


# ─── TimeBar timestamp fixer ──────────────────────────────────────────────────
def patch_timebar_request(payload: bytes, mask_key: bytes, fin: int, opcode: int):
    """Fix TimeBarRequest timestamps that are way too large (> elapsed since base_time)."""
    if not PROTOBUF_AVAILABLE or _base_time_epoch_ms[0] == 0:
        return None
    raw = bytearray(payload)
    for i in range(len(raw)): raw[i] ^= mask_key[i % 4]
    msg = ClientMsg()
    try:
        msg.ParseFromString(bytes(raw))
        if not msg.time_bar_requests:
            return None
        now_ms = int(time.time() * 1000)
        elapsed_ms = now_ms - _base_time_epoch_ms[0]
        if elapsed_ms <= 0 or elapsed_ms > 30 * 86400000:
            return None
        patched = False
        for req in msg.time_bar_requests:
            p = req.time_bar_parameters
            old_from = p.from_utc_time
            old_to = p.to_utc_time
            if p.from_utc_time > elapsed_ms:
                p.from_utc_time = elapsed_ms
                patched = True
            if p.to_utc_time <= 0 or p.to_utc_time > elapsed_ms:
                p.to_utc_time = elapsed_ms
                patched = True
            if p.to_utc_time <= p.from_utc_time and p.from_utc_time < elapsed_ms:
                p.to_utc_time = elapsed_ms
                patched = True
            if patched:
                log.info(f"  [TIMEBAR] FIXED request_id={req.request_id}: "
                         f"from {old_from}->{p.from_utc_time} to {old_to}->{p.to_utc_time} "
                         f"(elapsed={elapsed_ms})")
        if patched:
            return build_ws_frame(opcode, msg.SerializeToString(), fin=fin, mask=True)
    except Exception as e:
        log.error(f"  [TIMEBAR] Failed to patch: {e}")
    return None


# ─── Client → CQG forwarder ────────────────────────────────────────────────────
async def forward_client_to_cqg(client_r, cqg_w, client_w, initial_remaining=b"", http_done=False, is_historical=False):
    buf = FrameBuffer()
    if initial_remaining:
        buf.feed(initial_remaining)
    try:
        while True:
            while True:
                frame = buf.extract_frame()
                if not frame: break
                opcode, masked, mask_key, payload, raw_frame, fin = frame

                if opcode == 8:
                    log.info("  [C->S] WebSocket CLOSE frame — client is disconnecting.")
                    cqg_w.write(raw_frame)
                    await cqg_w.drain()
                    return
                elif opcode == 9:
                    log.debug("  [C->S] PING — responding locally with PONG")
                    pong_frame = build_ws_frame(10, payload, fin=1, mask=False)
                    client_w.write(pong_frame)
                    await client_w.drain()
                    continue
                elif opcode == 10:
                    log.debug("  [C->S] PONG")
                    cqg_w.write(raw_frame); await cqg_w.drain(); continue

                if opcode == 2 and masked:
                    if not is_historical:
                        log_client_msg(payload, mask_key)
                        pong_frame = build_pong_response(payload, mask_key)
                        if pong_frame:
                            client_w.write(pong_frame)
                            await client_w.drain()
                        patched = patch_logon_protobuf(payload, mask_key, fin, opcode)
                        if patched:
                            _now_lr = time.time()
                            elapsed = _now_lr - _last_logon_time[0]
                            _last_logon_time[0] = _now_lr
                            if elapsed < LOGON_MIN_INTERVAL:
                                wait_sec = LOGON_MIN_INTERVAL - elapsed
                                wait_sec = min(wait_sec, 30)
                                log.info(f"  [RATE LIMIT] Waiting {wait_sec:.0f}s before forwarding logon (last was {elapsed:.0f}s ago)")
                                await asyncio.sleep(wait_sec)
                            log.info("  [RATE LIMIT] Forwarding logon to CQG now")
                            cqg_w.write(patched)
                        else:
                            tb_patched = patch_timebar_request(payload, mask_key, fin, opcode)
                            cqg_w.write(tb_patched if tb_patched else raw_frame)
                    else:
                        cqg_w.write(raw_frame)
                else:
                    cqg_w.write(raw_frame)

            chunk = await client_r.read(65536)
            if not chunk:
                log.info("  [C->S] Client closed connection.")
                break
            buf.feed(chunk)

            if not http_done:
                if b"\r\n\r\n" not in buf.buf:
                    continue
                idx = buf.buf.find(b"\r\n\r\n") + 4
                http_part = bytes(buf.buf[:idx])
                log.info(f"  [C->S] HTTP Upgrade: {http_part.splitlines()[0].decode(errors='replace')}")
                cqg_w.write(http_part)
                await cqg_w.drain()
                buf.buf = buf.buf[idx:]
                http_done = True
                log.info("  [CLIENT->CQG] HTTP handshake forwarded.")

            await cqg_w.drain()

    except Exception as e:
        log.error(f"  [C->S] Error: {e}")





# ─── CQG → Client forwarder ────────────────────────────────────────────────────
async def forward_cqg_to_client(cqg_r, client_w, is_historical=False, last_msg_time=None):
    http_done = False
    buf = FrameBuffer()
    try:
        while True:
            chunk = await cqg_r.read(65536)
            if not chunk:
                log.info("  [S->C] CQG server closed connection.")
                break
            buf.feed(chunk)
            if last_msg_time is not None:
                last_msg_time[0] = time.monotonic()

            if not http_done:
                if b"\r\n\r\n" not in buf.buf:
                    continue
                idx = buf.buf.find(b"\r\n\r\n") + 4
                http_part = bytes(buf.buf[:idx])
                log.info(f"  [S->C] HTTP Response: {http_part.splitlines()[0].decode(errors='replace')}")
                client_w.write(http_part)
                await client_w.drain()
                buf.buf = buf.buf[idx:]
                http_done = True
                log.info("  [CQG->CLIENT] HTTP response forwarded.")

            while True:
                frame = buf.extract_frame()
                if not frame:
                    break
                opcode, masked, mask_key, payload, raw_frame, fin = frame

                if opcode == 8:
                    log.warning("  [S->C] WebSocket CLOSE frame from CQG.")
                    client_w.write(raw_frame)
                    await client_w.drain()
                    return
                elif opcode == 9:
                    log.debug("  [S->C] PING from server")
                    client_w.write(raw_frame)
                    await client_w.drain()
                    continue
                elif opcode == 10:
                    log.debug("  [S->C] PONG from server")
                    client_w.write(raw_frame)
                    await client_w.drain()
                    continue

                if opcode == 2:
                    if not _logon_captured[0] and is_historical is False:
                        _try_capture_logon_result(payload)
                    else:
                        log.debug(f"  [S->C] Binary frame ({len(payload)} bytes) forwarded")
                    client_w.write(raw_frame)
                else:
                    client_w.write(raw_frame)

            await client_w.drain()

    except Exception as e:
        log.error(f"  [S->C] Error: {e}")


def _try_capture_logon_result(payload: bytes):
    """Parse only the first server message to extract base_time for TimeBar patching."""
    if _logon_captured[0] or not PROTOBUF_AVAILABLE:
        return
    try:
        msg = ServerMsg()
        msg.ParseFromString(payload)
        if msg.HasField("logon_result"):
            r = msg.logon_result
            log.info(f"  [LOGON] Result code={r.result_code} base_time='{r.base_time}'")
            if r.result_code == 0 and r.base_time:
                _base_time_epoch_ms[0] = _parse_base_time(r.base_time)
                log.info(f"  [TIMEBAR] Captured base_time epoch: {_base_time_epoch_ms[0]}")
        else:
            # First server message has no logon_result — bizarre
            log.info(f"  [LOGON] First server msg has no logon_result field ({len(payload)} bytes)")
    except Exception as e:
        log.warning(f"  [LOGON] Failed to parse first server msg: {e}")
    finally:
        _logon_captured[0] = True


# ─── Server PING watchdog ──────────────────────────────────────────────────────
async def server_ping_watchdog(client_w, last_msg_time, stop_event):
    """
    Periodically inject WebSocket PING frames to the client if no server message
    has been received for 45 seconds. This prevents the client from timing out
    if the real CQG server stops sending data.
    """
    PING_INTERVAL = 30.0
    TIMEOUT = 45.0
    while not stop_event.is_set():
        await asyncio.sleep(PING_INTERVAL)
        elapsed = time.monotonic() - last_msg_time[0]
        if elapsed > TIMEOUT:
            log.info(f"  [WATCHDOG] No server message for {elapsed:.0f}s — injecting server PING frame to client")
            try:
                client_w.write(build_ws_frame(9, b"", fin=1, mask=False))
                await client_w.drain()
            except Exception as e:
                log.warning(f"  [WATCHDOG] Failed to inject PING: {e}")
                break


# ─── Connection handler ─────────────────────────────────────────────────────────
def is_historical_route(sni, path):
    """Determine if this connection should be routed to the local mock historical server."""
    if sni and ("historical" in sni or "deepcharts" in sni):
        return True
    if path == "/":
        return True
    return False


async def handle(client_r, client_w):
    peer = client_w.get_extra_info("peername")
    log.info(f"[+] Client connected from {peer}")

    sslobj = client_w.get_extra_info("ssl_object")
    sni = sslobj.server_hostname if sslobj else None
    log.info(f"[SNI] Requested SNI server_hostname: '{sni}'")

    handshake, remaining = b"", b""
    path = ""
    http_done = False
    try:
        initial_buf = bytearray()
        while b"\r\n\r\n" not in initial_buf and len(initial_buf) < 8192:
            chunk = await asyncio.wait_for(client_r.read(4096), timeout=config.BRIDGE_HTTP_TIMEOUT)
            if not chunk:
                break
            initial_buf.extend(chunk)
        if b"\r\n\r\n" in initial_buf:
            idx = initial_buf.find(b"\r\n\r\n") + 4
            handshake = bytes(initial_buf[:idx])
            remaining = bytes(initial_buf[idx:])
            http_done = True
            first_line = handshake.splitlines()[0].decode(errors='replace')
            log.info(f"[+] Client request line: {first_line}")
            parts = first_line.split()
            if len(parts) > 1:
                path = parts[1]
    except Exception as e:
        log.warning(f"[-] Failed to read HTTP handshake: {e}")
        if initial_buf:
            remaining = bytes(initial_buf)

    is_historical = is_historical_route(sni, path)

    try:
        if is_historical:
            log.info(f"[+] Routing '{sni or 'None'}' locally to mock Volumetrica Historical Server on port {config.BRIDGE_LOCAL_MOCK_PORT} (path='{path}')")
            cqg_r, cqg_w = await asyncio.open_connection(config.BRIDGE_LOCAL_MOCK_HOST, config.BRIDGE_LOCAL_MOCK_PORT, ssl=None)
            log.info(f"[+] Local Volumetrica mock connection established ({config.BRIDGE_LOCAL_MOCK_HOST}:{config.BRIDGE_LOCAL_MOCK_PORT})")
        else:
            log.info(f"[+] Routing '{sni or 'None'}' upstream to CQG ({REAL_CQG_HOST}:{REAL_CQG_PORT}) (path='{path}')")
            cqg_r, cqg_w = await asyncio.open_connection(
                REAL_CQG_HOST, REAL_CQG_PORT, ssl=client_ctx, server_hostname=SNI_HOST)
            log.info(f"[+] Upstream CQG connection established ({REAL_CQG_HOST}:{REAL_CQG_PORT})")
    except Exception as e:
        log.error(f"[!] Cannot establish upstream/mock connection: {e}")
        client_w.close()
        return

    if handshake:
        cqg_w.write(handshake)
        await cqg_w.drain()

    # Shared mutable state for watchdog
    last_server_msg_time = [time.monotonic()]
    stop_event = asyncio.Event()

    t1 = asyncio.create_task(forward_client_to_cqg(client_r, cqg_w, client_w, initial_remaining=remaining, http_done=http_done, is_historical=is_historical))
    t2 = asyncio.create_task(forward_cqg_to_client(cqg_r, client_w, is_historical=is_historical, last_msg_time=last_server_msg_time))

    # Start watchdog if this is a CQG (non-historical) connection
    t3 = None
    if not is_historical:
        t3 = asyncio.create_task(server_ping_watchdog(client_w, last_server_msg_time, stop_event))

    all_tasks = [t1, t2]
    if t3:
        all_tasks.append(t3)

    done, pending = await asyncio.wait(all_tasks, return_when=asyncio.FIRST_COMPLETED)
    stop_event.set()
    for p in pending:
        p.cancel()
    await asyncio.gather(*all_tasks, return_exceptions=True)

    for w in (client_w, cqg_w):
        try: w.close(); await w.wait_closed()
        except: pass

    log.info(f"[-] Disconnected {peer}")


# ─── Server factory ──────────────────────────────────────────────────────────────
async def create_server():
    """Create and return the MITM proxy server. Does not start serving."""
    global client_ctx
    LOGFILE = setup_logging()
    ensure_ca()

    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(CERT, KEY)

    client_ctx = ssl.create_default_context()
    client_ctx.check_hostname = False
    client_ctx.verify_mode    = ssl.CERT_NONE

    server = await asyncio.start_server(handle, config.BRIDGE_PROXY_BIND_HOST, PROXY_PORT, ssl=server_ctx)
    log.info("=" * 60)
    log.info(f"[*] Bridge MITM Proxy listening on {config.BRIDGE_PROXY_BIND_HOST}:{PROXY_PORT}")
    log.info(f"[*] Upstream: {REAL_CQG_HOST}:{REAL_CQG_PORT} (SNI={SNI_HOST})")
    log.info(f"[*] Full log: {LOGFILE}")
    log.info("=" * 60)

    return server


async def main():
    server = await create_server()
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("[*] Shutdown")
