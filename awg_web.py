import re
import subprocess
from dataclasses import dataclass
from io import BytesIO
from typing import Dict, List, Optional, Tuple

import streamlit as st

# ========= AUTH (NO DB) =========
APP_USERNAME = "admin"
APP_PASSWORD = "change_me_strong_password"  # <-- поменяй

# ========= COMMAND SETTINGS =========
AWG_CLIENT_BIN = "/usr/local/bin/awg-client"
SUDO_BIN = "/usr/bin/sudo"

NAME_RE = re.compile(r"^[a-zA-Z0-9._-]+$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


@dataclass
class CmdResult:
    ok: bool
    code: int
    out: str
    err: str
    argv: List[str]


def valid_client_name(name: str) -> Tuple[bool, str]:
    name = (name or "").strip()
    if not name:
        return False, "Имя клиента пустое."
    if name.startswith("-"):
        return False, "Имя клиента не может начинаться с '-'."
    if not NAME_RE.match(name):
        return False, "Разрешены только буквы/цифры/._-"
    if len(name) > 15:
        return False, "Слишком длинное имя (макс 15 символов)."
    return True, ""


def run_awg(args: List[str], timeout: int = 60) -> CmdResult:
    argv = [SUDO_BIN, AWG_CLIENT_BIN] + args
    try:
        p = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return CmdResult(
            ok=(p.returncode == 0),
            code=p.returncode,
            out=p.stdout or "",
            err=p.stderr or "",
            argv=argv,
        )
    except subprocess.TimeoutExpired as e:
        return CmdResult(False, 124, e.stdout or "", "Timeout expired", argv)


def show_cmd_result(res: CmdResult):
    if res.ok:
        st.success(f"Успешно (code={res.code})")
    else:
        st.error(f"Ошибка (code={res.code})")

    if res.out.strip():
        with st.expander("stdout"):
            st.code(res.out, language="text")
    if res.err.strip():
        with st.expander("stderr"):
            st.code(res.err, language="text")
    with st.expander("argv"):
        st.code(" ".join(res.argv), language="text")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


# ---------- LIST parsing ----------
def parse_client_rows_from_list(out: str) -> List[Dict[str, str]]:
    """
    Надёжно парсим `awg-client list`.
    Берём только строки, где есть .../client-<name>.conf
    """
    rows: List[Dict[str, str]] = []
    for line in out.splitlines():
        m = re.search(r"(\/\S*client-([a-zA-Z0-9._-]{1,15})\.conf)\b", line)
        if not m:
            continue

        path = m.group(1)
        name = m.group(2)

        addr = ""
        m2 = re.match(rf"^\s*{re.escape(name)}\s+(.*?)\s+{re.escape(path)}\s*$", line)
        if m2:
            addr = m2.group(1).strip()

        rows.append({"name": name, "addr": addr, "path": path})

    uniq = {r["name"]: r for r in rows}
    return [uniq[k] for k in sorted(uniq.keys())]


def get_clients() -> Tuple[List[Dict[str, str]], CmdResult]:
    res = run_awg(["list"], timeout=30)
    if not res.ok:
        return [], res
    return parse_client_rows_from_list(res.out), res


# ---------- SHOW parsing ----------
def extract_config_from_show(out: str) -> str:
    """
    Вытаскиваем конфиг из вывода `awg-client show`:
    берём строки начиная с [Interface] до линии из дефисов.
    """
    lines = out.splitlines()
    collecting = False
    buf: List[str] = []

    for line in lines:
        s = line.rstrip("\n")
        if not collecting:
            if s.strip() == "[Interface]":
                collecting = True
                buf.append("[Interface]")
            continue

        if s.strip() == "------------------------------------------------------------":
            break
        if s.strip().startswith(("INFO:", "WARN:", "ERROR:")):
            break
        buf.append(s)

    return "\n".join(buf).strip()


def extract_qr_ansi_lines_from_show(out: str) -> List[str]:
    """
    Вытаскиваем ANSI QR (qrencode -t ansiutf8) из вывода `awg-client show`.
    """
    lines = out.splitlines()
    start = -1
    for i, line in enumerate(lines):
        if "QR" in line and ("scan" in line.lower() or "amnezia" in line.lower() or "QR (" in line):
            start = i + 1
            break

    if start == -1:
        return []

    qr_lines: List[str] = []
    for line in lines[start:]:
        clean = strip_ansi(line)
        if any(ch in clean for ch in ("█", "▀", "▄")):
            qr_lines.append(line)
            continue
        if qr_lines:
            break

    return qr_lines


def qr_ansi_to_png_bytes(qr_lines: List[str], scale: int = 6) -> bytes:
    """
    Конвертируем ANSI UTF-8 QR (qrencode -t ansiutf8) в PNG.
    Важно: в таком QR часто фон чёрный, символы белые — конвертируем в обычный ч/б.
    """
    from PIL import Image

    stripped = [strip_ansi(l) for l in qr_lines]
    if not stripped:
        raise ValueError("Empty QR")

    width = max(len(l) for l in stripped)
    height = len(stripped) * 2  # ▀/▄ кодируют 2 вертикальных модуля

    grid = [[255 for _ in range(width)] for _ in range(height)]  # 0=black, 255=white

    def set_cell(x: int, y: int, is_white: bool):
        grid[y][x] = 255 if is_white else 0

    for y_line, line in enumerate(stripped):
        line = line.ljust(width, " ")
        for x, ch in enumerate(line):
            top_y = y_line * 2
            bot_y = top_y + 1

            if ch == "█":
                set_cell(x, top_y, True)
                set_cell(x, bot_y, True)
            elif ch == " ":
                set_cell(x, top_y, False)
                set_cell(x, bot_y, False)
            elif ch == "▀":
                set_cell(x, top_y, True)
                set_cell(x, bot_y, False)
            elif ch == "▄":
                set_cell(x, top_y, False)
                set_cell(x, bot_y, True)
            else:
                set_cell(x, top_y, True)
                set_cell(x, bot_y, True)

    img = Image.new("L", (width, height), 255)
    px = img.load()
    for y in range(height):
        for x in range(width):
            px[x, y] = grid[y][x]

    img = img.resize((width * scale, height * scale), resample=Image.NEAREST)
    bio = BytesIO()
    img.save(bio, format="PNG")
    return bio.getvalue()


def config_to_qr_png_bytes_fallback(config_text: str, scale: int = 6) -> bytes:
    """
    Фоллбек: генерируем QR из текста конфига (может не влезть -> ValueError).
    """
    import qrcode
    from qrcode.constants import ERROR_CORRECT_L

    qr = qrcode.QRCode(
        version=None,
        error_correction=ERROR_CORRECT_L,
        box_size=scale,
        border=2,
    )
    qr.add_data(config_text)
    qr.make(fit=True)
    img = qr.make_image()
    bio = BytesIO()
    img.save(bio, format="PNG")
    return bio.getvalue()


def fetch_client_show(name: str) -> Tuple[Optional[str], Optional[bytes], CmdResult]:
    res = run_awg(["show", name], timeout=45)
    if not res.ok:
        return None, None, res

    config_text = extract_config_from_show(res.out)
    qr_png = None

    qr_lines = extract_qr_ansi_lines_from_show(res.out)
    if qr_lines:
        try:
            qr_png = qr_ansi_to_png_bytes(qr_lines, scale=6)
        except Exception:
            qr_png = None

    if qr_png is None and config_text:
        try:
            qr_png = config_to_qr_png_bytes_fallback(config_text, scale=6)
        except Exception:
            qr_png = None

    return config_text, qr_png, res


# ---------- Auth ----------
def ensure_auth_state():
    if "auth" not in st.session_state:
        st.session_state.auth = False


def login_view():
    st.title("AmneziaWG менеджер")
    st.write("Вход")

    # Enter в пароле сабмитит форму
    with st.form("login_form", clear_on_submit=False):
        u = st.text_input("Логин")
        p = st.text_input("Пароль", type="password")
        submitted = st.form_submit_button("Войти")

    if submitted:
        if u == APP_USERNAME and p == APP_PASSWORD:
            st.session_state.auth = True
            st.rerun()
        else:
            st.error("Неверный логин или пароль")


# ---------- Clients UI ----------
def ensure_cache():
    if "clients_list_cache" not in st.session_state:
        st.session_state.clients_list_cache = None
    if "client_cache" not in st.session_state:
        st.session_state.client_cache = {}  # name -> {config, qr_png, show_res}


def load_clients(force: bool = False) -> Tuple[List[Dict[str, str]], CmdResult]:
    if force or st.session_state.clients_list_cache is None:
        rows, res = get_clients()
        st.session_state.clients_list_cache = (rows, res)
    return st.session_state.clients_list_cache


@st.dialog("Добавить клиента")
def add_client_dialog():
    st.write("Создание нового клиента")

    name = st.text_input("Имя клиента (до 15 символов)")
    mode = st.selectbox("Режим", ["full (весь трафик через VPN)", "split (VPN+LAN через VPN)"])
    lan_cidr = ""
    if mode.startswith("split"):
        lan_cidr = st.text_input("LAN CIDR (например 192.168.1.0/24)")

    col1, col2 = st.columns([1, 1])
    with col1:
        if st.button("Создать", use_container_width=True):
            ok, msg = valid_client_name(name)
            if not ok:
                st.error(msg)
                return

            args = ["add", name.strip()]
            if mode.startswith("split"):
                if not lan_cidr.strip():
                    st.error("Для split нужен LAN CIDR.")
                    return
                args += ["--split", lan_cidr.strip()]

            res_add = run_awg(args, timeout=90)
            show_cmd_result(res_add)
            # обновим список после закрытия
            st.session_state.clients_list_cache = None
            st.rerun()

    with col2:
        if st.button("Отмена", use_container_width=True):
            st.rerun()


def clients_view():
    st.header("Clients")
    ensure_cache()

    # Top controls
    c1, c2, c3 = st.columns([1, 1, 3])
    with c1:
        if st.button("🔄 Обновить", use_container_width=True):
            st.session_state.clients_list_cache = None
    with c2:
        if st.button("➕ Добавить", use_container_width=True):
            add_client_dialog()

    rows, res = load_clients(force=False)
    if not res.ok:
        st.error("Не удалось получить список клиентов.")
        show_cmd_result(res)
        return

    left, right = st.columns([1, 2], vertical_alignment="top")

    # -------- Left: list/search/select
    with left:
        st.subheader("Список")
        q = st.text_input("Поиск", placeholder="alex / test / ...")

        filtered = rows
        if q.strip():
            qq = q.strip().lower()
            filtered = [r for r in rows if qq in r["name"].lower()]

        if not filtered:
            st.info("Клиенты не найдены.")
            st.session_state.selected_client = None
            return

        # компактная табличка
        st.dataframe(
            [{"name": r["name"], "addr": r["addr"]} for r in filtered],
            use_container_width=True,
            hide_index=True,
        )

        names = [r["name"] for r in filtered]
        default_idx = 0
        prev = st.session_state.get("selected_client")
        if prev in names:
            default_idx = names.index(prev)

        selected = st.selectbox("Выбранный клиент", names, index=default_idx)
        st.session_state.selected_client = selected

    # -------- Right: selected client panel
    with right:
        name = st.session_state.get("selected_client")
        if not name:
            st.info("Выбери клиента слева.")
            return

        meta = next((r for r in rows if r["name"] == name), None)
        st.subheader(f"👤 {name}")
        if meta:
            st.caption(f"{meta.get('addr','')}")
            st.caption(f"{meta.get('path','')}")

        cache: Dict[str, Dict] = st.session_state.client_cache
        entry = cache.get(name, {})

        btn_col, view_col = st.columns([1, 3], vertical_alignment="top")

        with btn_col:
            if st.button("Показать / Обновить", use_container_width=True):
                cfg, qr_png, res_show = fetch_client_show(name)
                cache[name] = {"config": cfg, "qr_png": qr_png, "show_res": res_show}
                st.session_state.client_cache = cache
                st.rerun()

            cfg = entry.get("config")
            if cfg:
                st.download_button(
                    "⬇️ Скачать конфиг",
                    data=cfg.encode("utf-8"),
                    file_name=f"client-{name}.conf",
                    mime="text/plain",
                    use_container_width=True,
                )
            else:
                st.caption("Скачивание появится после «Показать»")

            st.divider()
            confirm = st.checkbox("Подтверждаю удаление")
            if st.button("Удалить", use_container_width=True):
                if not confirm:
                    st.error("Подтверди удаление чекбоксом.")
                else:
                    res_del = run_awg(["delete", name], timeout=90)
                    show_cmd_result(res_del)
                    cache.pop(name, None)
                    st.session_state.client_cache = cache
                    st.session_state.clients_list_cache = None
                    st.session_state.selected_client = None
                    st.rerun()

        with view_col:
            show_res: Optional[CmdResult] = entry.get("show_res")
            cfg = entry.get("config")
            qr_png = entry.get("qr_png")

            if show_res and not show_res.ok:
                show_cmd_result(show_res)

            if cfg:
                st.text_area("Конфиг", cfg, height=420)
            else:
                st.info("Нажми «Показать / Обновить», чтобы загрузить конфиг и QR.")

            if qr_png:
                st.write("QR:")
                st.image(qr_png)
            elif cfg:
                st.warning(
                    "QR не удалось отобразить. "
                    "Возможные причины: qrencode не установлен, либо конфиг слишком большой для QR. "
                    "Скачай конфиг и импортируй в приложение из файла."
                )


# ---------- Settings UI ----------
def settings_view():
    st.header("Settings")
    st.write("Обслуживание сервера и системные операции.")

    st.subheader("Reload")
    if st.button("♻️ Reload (sysctl + restart awg-quick + netfilter-persistent)"):
        res = run_awg(["reload"], timeout=180)
        show_cmd_result(res)

    st.divider()
    st.subheader("Maintenance")
    with st.form("maint_form"):
        dry = st.checkbox("dry-run")
        yes = st.checkbox("--yes (без подтверждения)")
        reboot = st.checkbox("--reboot")
        submitted = st.form_submit_button("▶️ Запустить maintenance")
    if submitted:
        args = ["maint"]
        if dry:
            args.append("--dry-run")
        if yes:
            args.append("--yes")
        if reboot:
            args.append("--reboot")
        res = run_awg(args, timeout=1200)
        show_cmd_result(res)

    st.divider()
    st.subheader("Restore")
    if st.button("Показать список бэкапов"):
        res = run_awg(["restore", "list"], timeout=60)
        show_cmd_result(res)

    with st.form("restore_form"):
        target = st.text_input("Номер (N) или путь к backup-файлу")
        dry = st.checkbox("dry-run", key="restore_dry")
        yes = st.checkbox("--yes", key="restore_yes")
        submitted = st.form_submit_button("↩️ Restore")
    if submitted:
        if not target.strip():
            st.error("Укажи номер или путь к файлу.")
        else:
            args = ["restore", target.strip()]
            if dry:
                args.append("--dry-run")
            if yes:
                args.append("--yes")
            res = run_awg(args, timeout=300)
            show_cmd_result(res)

    st.divider()
    st.subheader("Clean")
    with st.form("clean_form"):
        dry = st.checkbox("dry-run", key="clean_dry")
        yes = st.checkbox("--yes", key="clean_yes")
        submitted = st.form_submit_button("🧹 Clean")
    if submitted:
        args = ["clean"]
        if dry:
            args.append("--dry-run")
        if yes:
            args.append("--yes")
        res = run_awg(args, timeout=300)
        show_cmd_result(res)


# ================== APP START ==================
st.set_page_config(page_title="AmneziaWG Manager", layout="wide")

ensure_auth_state()
if not st.session_state.auth:
    login_view()
    st.stop()

st.sidebar.title("Навигация")
section = st.sidebar.radio("Раздел", ["Clients", "Settings", "Выход"])

if section == "Выход":
    st.session_state.auth = False
    st.rerun()
elif section == "Clients":
    clients_view()
else:
    settings_view()