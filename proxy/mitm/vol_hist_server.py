"""
vol_hist_server.py — Mock Volumetrica Historical Server

Listens on port 12010 via WebSocket, intercepts Deepchart.exe's connection.
Parses incoming TimeBarRequest protobufs and responds with synthetic OHLCV bar data
so the chart can initialize instead of staying in "building" state forever.
"""
import asyncio, logging, datetime, json, subprocess, zlib, os, random, struct, sys
import websockets
import config

def cleanup_old_logs(log_dir: str, pattern: str, keep: int = 10):
    try:
        files = sorted(
            (f for f in os.listdir(log_dir) if f.startswith(pattern.replace("*", ""))),
            key=lambda f: os.path.getmtime(os.path.join(log_dir, f)),
            reverse=True
        )
        for old in files[keep:]:
            try: os.remove(os.path.join(log_dir, old))
            except: pass
    except: pass

os.makedirs(config.LOG_DIR, exist_ok=True)
cleanup_old_logs(config.LOG_DIR, "vol_hist_", keep=10)
LOG_FILE = os.path.join(config.LOG_DIR, f"vol_hist_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.log")

logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL.upper(), logging.DEBUG),
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(), logging.FileHandler(LOG_FILE)],
)
log = logging.getLogger("vol-hist")

_sig_cache = {}

# ─── Protobuf imports (same strategy as bridge_mitm_proxy.py) ────────────
PROTOBUF_AVAILABLE = False
_meipass = getattr(sys, '_MEIPASS', None)
_try_search = [None]
if _meipass: _try_search.append(_meipass)
_try_search.append(os.path.dirname(os.path.abspath(__file__)))
for _try_path in _try_search:
    if _try_path and _try_path not in sys.path: sys.path.insert(0, _try_path)
    try:
        from WebAPI.webapi_2_pb2 import ClientMsg, ServerMsg
        from WebAPI.historical_2_pb2 import TimeBarRequest, TimeBarReport, TimeBar, TimeBarParameters
        from WebAPI.user_session_2_pb2 import LogonResult
        PROTOBUF_AVAILABLE = True
        log.info(f"[IMPORT] CQG protobufs loaded")
        break
    except Exception as _e:
        log.warning(f"[IMPORT] Failed from {_try_path}: {_e}")
        if _try_path and _try_path in sys.path: sys.path.remove(_try_path)

if not PROTOBUF_AVAILABLE:
    log.error("[!] CQG protobufs NOT found — returning only IsComplete responses (no bar data)")


def encode_varint(value):
    res = bytearray()
    while True:
        towrite = value & 0x7f
        value >>= 7
        if value:
            res.append(towrite | 0x80)
        else:
            res.append(towrite)
            break
    return bytes(res)


def get_powershell_signature(key):
    ps_script = f"""
$plainBytes = [System.Text.Encoding]::UTF8.GetBytes('-')
$salt = New-Object Byte[] 32
$iv = New-Object Byte[] 32
$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
$rng.GetBytes($salt)
$rng.GetBytes($iv)
$pbkdf2 = [System.Security.Cryptography.Rfc2898DeriveBytes]::new('{key}', $salt, 1230)
$keyBytes = $pbkdf2.GetBytes(32)
$rijndael = [System.Security.Cryptography.RijndaelManaged]::new()
$rijndael.KeySize = 256
$rijndael.BlockSize = 256
$rijndael.Mode = [System.Security.Cryptography.CipherMode]::CBC
$rijndael.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$rijndael.Key = $keyBytes
$rijndael.IV = $iv
$encryptor = $rijndael.CreateEncryptor()
$ms = [System.IO.MemoryStream]::new()
$cs = [System.Security.Cryptography.CryptoStream]::new($ms, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)
$cs.Write($plainBytes, 0, $plainBytes.Length)
$cs.FlushFinalBlock()
$encryptedBytes = $ms.ToArray()
$cs.Dispose()
$ms.Dispose()
$rijndael.Dispose()
$pbkdf2.Dispose()
$rng.Dispose()
$result = New-Object Byte[] (32 + 32 + $encryptedBytes.Length)
[System.Buffer]::BlockCopy($salt, 0, $result, 0, 32)
[System.Buffer]::BlockCopy($iv, 0, $result, 32, 32)
[System.Buffer]::BlockCopy($encryptedBytes, 0, $result, 64, $encryptedBytes.Length)
[System.Convert]::ToBase64String($result)
"""
    try:
        log.info(f"  [SIGN] Invoking PowerShell to encrypt '-' with session key...")
        res = subprocess.run(["powershell", "-Command", ps_script], capture_output=True, text=True, timeout=30)
        sig = res.stdout.strip()
        if sig:
            log.info(f"  [SIGN] Signature generated: {sig[:32]}...")
        else:
            log.error(f"  [SIGN] PowerShell returned empty")
        return sig
    except Exception as e:
        log.error(f"  [SIGN] Failed: {e}")
        return ""


def build_keepalive():
    inner_bytes = b'\x20\x01\x2a\x00'
    outer_bytes = b'\x0a' + encode_varint(len(inner_bytes)) + inner_bytes
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
    return compressor.compress(outer_bytes) + compressor.flush()


def build_signed_response(sig: str, bar_data: bytes = b""):
    """
    Build a ServerMsg protobuf with the time_bar_reports populated.
    If protobuf is unavailable, fall back to raw wire format with
    IsComplete + signature (no bar data).
    """
    if bar_data and PROTOBUF_AVAILABLE:
        try:
            report = TimeBarReport()
            report.ParseFromString(bar_data)
            sm = ServerMsg()
            sm.time_bar_reports.append(report)
            payload = sm.SerializeToString()
            compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
            return compressor.compress(payload) + compressor.flush()
        except Exception as e:
            log.warning(f"  [RESPOND] Failed to build proper ServerMsg: {e}")

    # Fallback: raw wire format with IsComplete + signature
    parts = [b'\x20\x01']  # field 4 = true
    sig_bytes = sig.encode('ascii') if sig else b""
    if sig_bytes:
        parts.append(b'\x2a' + encode_varint(len(sig_bytes)) + sig_bytes)
    if bar_data and not PROTOBUF_AVAILABLE:
        parts.append(b'\x6a' + encode_varint(len(bar_data)) + bar_data)

    inner_bytes = b"".join(parts)
    outer_bytes = b'\x0a' + encode_varint(len(inner_bytes)) + inner_bytes
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
    return compressor.compress(outer_bytes) + compressor.flush()


def generate_synthetic_bars(request_id: int, contract_id: int,
                            from_utc_ms: int, to_utc_ms: int,
                            bar_size_ms: int = 300000):
    """
    Generate synthetic OHLCV TimeBarReport protobuf for the requested range.
    Returns serialized bytes or empty bytes on failure.
    """
    if not PROTOBUF_AVAILABLE:
        return b""
    try:
        report = TimeBarReport()
        report.request_id = request_id
        report.status_code = 0  # RESULT_CODE_SUCCESS
        report.is_report_complete = True
        report.up_to_utc_time = to_utc_ms

        now_ms = int(datetime.datetime.now().timestamp() * 1000)
        base_price = 19500.0 if contract_id == 1 else 17500.0
        o, h, l, c, v = base_price, base_price, base_price, base_price, 0

        t = from_utc_ms if from_utc_ms > 0 else (now_ms - 86400000 * 5)
        end = to_utc_ms if to_utc_ms > 0 else now_ms

        bar_count = 0
        while t < end and bar_count < 5000:
            o = c + random.uniform(-8, 8)
            h = max(o, c) + random.uniform(0.5, 15)
            l = min(o, c) - random.uniform(0.5, 15)
            c = random.uniform(l, h)
            v += random.randint(1, 100)
            if v > 10000000: v = random.randint(100, 5000)

            bar = report.time_bars.add()
            bar.bar_utc_time = t
            bar.scaled_open_price = int(o * 10000)
            bar.scaled_high_price = int(h * 10000)
            bar.scaled_low_price = int(l * 10000)
            bar.scaled_close_price = int(c * 10000)
            bar.scaled_volume = v * 10000

            t += bar_size_ms
            bar_count += 1

        log.info(f"  [BARS] Generated {bar_count} bars for request_id={request_id} "
                 f"contract={contract_id} ({from_utc_ms} → {to_utc_ms}, "
                 f"bar_size={bar_size_ms}ms) price_range={o:.1f}–{c:.1f}")
        return report.SerializeToString()
    except Exception as e:
        log.warning(f"  [BARS] Failed to generate bars: {e}")
        return b""


def extract_timebar_request(decompressed: bytes):
    """
    Try to parse the decompressed client data as a ClientMsg.
    If it contains TimeBarRequests, extract the first one's parameters.
    Returns (request_id, contract_id, from_utc_ms, to_utc_ms, bar_size_ms) or None.
    """
    if not PROTOBUF_AVAILABLE:
        return None
    try:
        msg = ClientMsg()
        msg.ParseFromString(decompressed)
        if len(msg.time_bar_requests) > 0:
            req = msg.time_bar_requests[0]
            params = req.time_bar_parameters
            log.info(f"  [CLIENT] TimeBarRequest: id={req.request_id} "
                     f"contract={params.contract_id} "
                     f"bar_unit={params.bar_unit} unit_number={params.unit_number} "
                     f"from={params.from_utc_time} to={params.to_utc_time}")

            # Bar size in ms: unit_number * unit_multiplier
            unit_map = {0: 60000, 1: 3600000, 2: 86400000}  # MINUTE, HOUR, DAY
            bar_ms = params.unit_number * unit_map.get(params.bar_unit, 60000)
            if bar_ms < 1000: bar_ms = 300000  # default 5 min

            return (req.request_id, params.contract_id,
                    params.from_utc_time, params.to_utc_time, bar_ms)
        else:
            log.info(f"  [CLIENT] No TimeBarRequests in msg ({len(decompressed)} bytes)")
            return None
    except Exception as e:
        log.debug(f"  [CLIENT] Not a ClientMsg protobuf: {e}")
        return None


async def handle_client(ws):
    addr = ws.remote_address
    log.info(f"[+] WS client connected from {addr}")
    use_compression = False

    last_activity = asyncio.get_event_loop().time()
    last_session_key = None
    keepalive_interval = 15

    async def keepalive_loop():
        nonlocal last_activity
        while True:
            await asyncio.sleep(keepalive_interval)
            idle = asyncio.get_event_loop().time() - last_activity
            if idle >= keepalive_interval:
                try:
                    ka = build_keepalive()
                    await ws.send(ka)
                    log.info(f"  [KEEPALIVE] Sent keepalive ({len(ka)} bytes, idle={idle:.0f}s)")
                except websockets.ConnectionClosed:
                    break
                except Exception as e:
                    log.warning(f"  [KEEPALIVE] Send failed: {e}")
                    break

    async def respond(session_key, bar_data=b""):
        if session_key:
            if session_key in _sig_cache:
                sig = _sig_cache[session_key]
            else:
                sig = get_powershell_signature(session_key)
                if sig:
                    _sig_cache[session_key] = sig

            if not sig:
                log.warning("  [RESPOND] Signature generation failed")
                compressed = build_keepalive()
                await ws.send(compressed)
                return

            compressed = build_signed_response(sig, bar_data)
            log.info(f"  [SEND] Response ({len(compressed)} bytes, bars={len(bar_data) > 0})")
            await ws.send(compressed)
        else:
            compressed = build_keepalive()
            await ws.send(compressed)

    try:
        keepalive_task = asyncio.create_task(keepalive_loop())

        try:
            async for message in ws:
                last_activity = asyncio.get_event_loop().time()

                if isinstance(message, bytes):
                    log.info(f"  [BINARY] Received {len(message)} bytes")
                    try:
                        decompressed = zlib.decompress(message, -15)
                        log.info(f"  [BINARY] Decompressed: {len(decompressed)} bytes")
                    except Exception as ex:
                        log.error(f"  [BINARY] Failed to decompress: {ex}")
                        continue

                    session_key = None
                    idx = decompressed.find(b'\x42\x5f')
                    if idx != -1:
                        session_key = decompressed[idx+2 : idx+2+95].decode('ascii', errors='ignore')
                        log.info(f"  [SESSION KEY] '{session_key[:16]}...'")
                    else:
                        log.warning("  [SESSION KEY] Marker 0x425f not found")

                    if session_key:
                        last_session_key = session_key

                    # Strip session key marker to get clean protobuf data
                    clean_data = decompressed
                    marker = b'\x42\x5f'
                    m_idx = decompressed.find(marker)
                    if m_idx != -1:
                        key_end = m_idx + 2 + 95
                        if len(decompressed) > key_end:
                            clean_data = decompressed[:m_idx] + decompressed[key_end:]
                        else:
                            clean_data = decompressed[:m_idx]

                    bar_data = b""
                    tb = extract_timebar_request(clean_data)
                    if tb:
                        req_id, cid, frm, to_, bsz = tb
                        bar_data = generate_synthetic_bars(req_id, cid, frm, to_, bsz)

                    await respond(session_key or last_session_key, bar_data)

                else:
                    log.info(f"  [TEXT] Received: {message[:500]}")
                    if message.strip() == "compress":
                        use_compression = True
                        log.info("  [COMPRESSION] Enabled")
                        continue

        except websockets.ConnectionClosed as e:
            log.info(f"  [CLOSED] {e.code} {e.reason}")
        finally:
            keepalive_task.cancel()
            try: await keepalive_task
            except asyncio.CancelledError: pass

    except Exception as e:
        log.error(f"  [ERROR] {e}")
    finally:
        log.info(f"[-] {addr} disconnected")


async def process_request(connection, request):
    return None


async def main():
    log.info("=" * 60)
    log.info(f"[*] Volumetrica Historical Mock Server on ws://{config.VOL_HIST_HOST}:{config.VOL_HIST_PORT}")
    log.info(f"[*] Full log: {LOG_FILE}")
    log.info("=" * 60)
    log.info("Make sure hosts file has:")
    log.info(f"  {config.VOL_HIST_HOSTS_ENTRY}")
    log.info("=" * 60)

    logging.getLogger("websockets.server").setLevel(logging.WARNING)

    async with websockets.serve(
        handle_client,
        config.VOL_HIST_HOST,
        config.VOL_HIST_PORT,
        process_request=process_request,
        ping_interval=10,
        ping_timeout=5,
        close_timeout=30,
    ):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
