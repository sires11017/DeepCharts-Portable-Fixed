import os

# ─── Load .env file ────────────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))

dotenv_path = os.path.join(SCRIPT_DIR, ".env")
if os.path.isfile(dotenv_path):
    with open(dotenv_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip().strip("\"'")
            if key not in os.environ:
                os.environ[key] = val

LOG_LEVEL = os.environ.get("LOG_LEVEL", "DEBUG")


VOL_HIST_HOST = os.environ.get("VOL_HIST_HOST", "0.0.0.0")
VOL_HIST_PORT = int(os.environ.get("VOL_HIST_PORT", "12010"))
VOL_HIST_HOSTS_ENTRY = os.environ.get(
    "VOL_HIST_HOSTS_ENTRY",
    "127.0.0.1  depth-it.historical.deepcharts.com",
)

BRIDGE_DEFAULT_PORT = int(os.environ.get("BRIDGE_DEFAULT_PORT", "10050"))
BRIDGE_PORT_SCAN_RANGE = int(os.environ.get("BRIDGE_PORT_SCAN_RANGE", "10"))
BRIDGE_FAST_SCAN_COUNT = int(os.environ.get("BRIDGE_FAST_SCAN_COUNT", "3"))
BRIDGE_PROCESS_NAME = os.environ.get("BRIDGE_PROCESS_NAME", "VolumetricaBridge.exe")
BRIDGE_EXE = os.environ.get(
    "BRIDGE_EXE",
    os.path.join(REPO_ROOT, "app", "bridge", "VolumetricaBridge.exe"),
)
BRIDGE_DIR = os.environ.get(
    "BRIDGE_DIR",
    os.path.join(REPO_ROOT, "app", "bridge"),
)
BRIDGE_PORT_FILE = os.environ.get(
    "BRIDGE_PORT_FILE",
    os.path.join(
        os.environ.get("APPDATA", os.path.expanduser("~")),
        "Volumetrica",
        "bridge.port",
    ),
)

IPC_MITM_PROXY_PORT = int(os.environ.get("IPC_MITM_PROXY_PORT", "19876"))
IPC_MITM_LISTENER_TIMEOUT = int(os.environ.get("IPC_MITM_LISTENER_TIMEOUT", "120"))
IPC_MITM_CONNECT_TIMEOUT = int(os.environ.get("IPC_MITM_CONNECT_TIMEOUT", "5"))
IPC_MITM_WAIT_BRIDGE_TIMEOUT = int(os.environ.get("IPC_MITM_WAIT_BRIDGE_TIMEOUT", "120"))
IPC_MITM_LISTENER_WAIT_TIMEOUT = int(os.environ.get("IPC_MITM_LISTENER_WAIT_TIMEOUT", "15"))
IPC_MITM_SYNC_WAIT_TIMEOUT = int(os.environ.get("IPC_MITM_SYNC_WAIT_TIMEOUT", "15"))
IPC_MITM_BRIDGE_KILL_DELAY = int(os.environ.get("IPC_MITM_BRIDGE_KILL_DELAY", "2"))
IPC_MITM_PORT_FLUSH_DELAY = float(os.environ.get("IPC_MITM_PORT_FLUSH_DELAY", "0.5"))
IPC_MITM_LISTEN_HOST = os.environ.get("IPC_MITM_LISTEN_HOST", "127.0.0.1")
IPC_MITM_BRIDGE_HOST = os.environ.get("IPC_MITM_BRIDGE_HOST", "127.0.0.1")
IPC_MITM_READ_SIZE = int(os.environ.get("IPC_MITM_READ_SIZE", "65536"))

DEEPCHART_EXE = os.environ.get(
    "DEEPCHART_EXE",
    os.path.join(REPO_ROOT, "app", "Deepchart.exe"),
)
DEEPCHART_DIR = os.environ.get(
    "DEEPCHART_DIR",
    os.path.join(REPO_ROOT, "app"),
)

BRIDGE_PROXY_PORT = int(os.environ.get("BRIDGE_PROXY_PORT", "443"))
REAL_CQG_HOST = os.environ.get("REAL_CQG_HOST", "208.48.16.22")
REAL_CQG_PORT = int(os.environ.get("REAL_CQG_PORT", "443"))
SNI_HOST = os.environ.get("SNI_HOST", "demoapi.cqg.com")
ADDITIONAL_SNI = os.environ.get("ADDITIONAL_SNI", "api.cqg.com")

TARGET_PRIVATE_LABEL = os.environ.get("TARGET_PRIVATE_LABEL", "AMPConnect")
TARGET_CLIENT_APP_ID = os.environ.get("TARGET_CLIENT_APP_ID", "AMPConnect")
TARGET_CLIENT_VERSION = os.environ.get("TARGET_CLIENT_VERSION", "7.0.238")

# CQG login credentials - the bridge uses demo18040 by default which may expire.
# Set these env vars to use your own CQG demo/real account credentials.
CQG_USERNAME = os.environ.get("CQG_USERNAME", "")
CQG_PASSWORD = os.environ.get("CQG_PASSWORD", "")

_LOCAL_APP_DATA = os.environ.get("LOCALAPPDATA", os.path.expanduser("~"))
_APP_DATA = os.environ.get("APPDATA", os.path.expanduser("~"))
_PROGRAM_DATA = os.environ.get("PROGRAMDATA", os.path.expanduser("~/ProgramData"))

_CA_SEARCH = [
    os.path.join(REPO_ROOT, "certs", "mitm_ca"),
    os.path.join(_PROGRAM_DATA, "DeepCharts", "certs", "mitm_ca"),
]
CA_DIR = os.environ.get("CA_DIR", next((d for d in _CA_SEARCH if os.path.isdir(d)), _CA_SEARCH[0]))
CA_CERT = os.environ.get("CA_CERT", os.path.join(CA_DIR, "ca.pem"))
CA_KEY = os.environ.get("CA_KEY", os.path.join(CA_DIR, "ca.key"))
CERT = os.environ.get("CERT", os.path.join(CA_DIR, "cert.pem"))
KEY_ENV = os.environ.get("MITM_CA_KEY", os.path.join(CA_DIR, "key.pem"))

_LOG_SEARCH = [
    os.path.join(_LOCAL_APP_DATA, "DeepCharts", "logs"),
    os.path.join(REPO_ROOT, "logs"),
]
LOG_DIR = os.environ.get("LOG_DIR", next((d for d in _LOG_SEARCH if os.path.isdir(d)), _LOG_SEARCH[0]))

BRIDGE_THREAD_POOL_WORKERS = int(os.environ.get("BRIDGE_THREAD_POOL_WORKERS", "4"))
BRIDGE_LOCAL_MOCK_HOST = os.environ.get("BRIDGE_LOCAL_MOCK_HOST", "127.0.0.1")
BRIDGE_LOCAL_MOCK_PORT = int(os.environ.get("BRIDGE_LOCAL_MOCK_PORT", "12010"))
BRIDGE_PROXY_BIND_HOST = os.environ.get("BRIDGE_PROXY_BIND_HOST", "0.0.0.0")
BRIDGE_HTTP_TIMEOUT = float(os.environ.get("BRIDGE_HTTP_TIMEOUT", "2.0"))
BRIDGE_READ_SIZE = int(os.environ.get("BRIDGE_READ_SIZE", "65536"))

# Symbols to auto-subscribe after CQG login (comma-separated)
# Disabled: bridge handles symbol resolution on its own.
# Injection of wrong symbol format (e.g. "NQ-CME" vs CQG's "F.US.ENQU26") causes
# "Requested symbol was not found" errors that Deepchart.Core shows as notifications.
DEFAULT_SYMBOLS = os.environ.get("CQG_SYMBOLS", "")
SYMBOLS = [s.strip() for s in DEFAULT_SYMBOLS.split(",") if s.strip()]

# Market data subscription level (3=LEVEL_TRADES_BBA_VOLUMES)
MARKET_DATA_LEVEL = int(os.environ.get("CQG_MARKET_DATA_LEVEL", "3"))
