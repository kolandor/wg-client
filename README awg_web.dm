# awg_web — веб‑панель AmneziaWG на Streamlit

Цель: развернуть Streamlit‑панель для управления AmneziaWG на новой системе  
и избежать типовых ошибок (pip, рабочая директория, права, sudoers, автозапуск).

## Что будет в результате

- отдельный пользователь `awgweb` для веб‑панели
- безопасный `sudo` только для `awg-client`
- изолированная виртуальная среда Python
- корректная рабочая директория для Streamlit
- автозапуск через `systemd`

## 1) Проверки перед началом

Убедитесь, что `awg-client` есть и работает от root:

```bash
sudo /usr/local/bin/awg-client help | head -n 20
```

Если файл не там — найдите его:

```bash
which awg-client || sudo find / -maxdepth 3 -name awg-client 2>/dev/null
```

Запомните путь — он нужен для `sudoers` и в скрипте.

## 2) Создаём пользователя для веб‑панели (не root)

```bash
sudo adduser --disabled-password --gecos "" awgweb
```

## 3) Настраиваем sudo без пароля только для `awg-client`

Открыть:

```bash
sudo visudo -f /etc/sudoers.d/awgweb-awgclient
```

Вставить (путь должен совпадать с реальным):

```
awgweb ALL=(root) NOPASSWD: /usr/local/bin/awg-client
```

Проверка:

```bash
sudo -u awgweb -H sudo /usr/local/bin/awg-client list
```

Должно отработать без запроса пароля.

## 4) Ставим pip и venv

На новой системе часто нет pip:

```bash
sudo apt update
sudo apt install -y python3-pip python3-venv
python3 -m pip --version
```

## 5) Создаём venv и ставим зависимости

Важно: многострочные команды в кавычках могут “подвисать”.  
Делаем по шагам.

### 5.1 Создать venv

```bash
sudo -u awgweb -H python3 -m venv /home/awgweb/venv
```

### 5.2 Обновить pip в venv

```bash
sudo -u awgweb -H /home/awgweb/venv/bin/pip install --upgrade pip
```

### 5.3 Установить зависимости

```bash
sudo -u awgweb -H /home/awgweb/venv/bin/pip install streamlit qrcode[pil] pillow
```

Проверка:

```bash
sudo -u awgweb -H /home/awgweb/venv/bin/streamlit --version
```

## 6) Подготовить конфиг Streamlit для awgweb

Создаём домашнюю директорию Streamlit именно для `awgweb`:

```bash
sudo -u awgweb -H bash -lc '
mkdir -p /home/awgweb/.streamlit
touch /home/awgweb/.streamlit/secrets.toml
chmod 700 /home/awgweb/.streamlit
chmod 600 /home/awgweb/.streamlit/secrets.toml
'
```

Опционально выключить сбор статистики:

```bash
sudo -u awgweb -H bash -lc 'cat > /home/awgweb/.streamlit/config.toml <<EOF
[browser]
gatherUsageStats = false
EOF
chmod 600 /home/awgweb/.streamlit/config.toml'
```

## 7) Сохраняем скрипт

Файл: `/home/awgweb/awg_web.py`

```bash
sudo nano /home/awgweb/awg_web.py
```

Вставьте финальный код и сохраните.

Права:

```bash
sudo chown awgweb:awgweb /home/awgweb/awg_web.py
chmod 600 /home/awgweb/awg_web.py
```

## 8) Правильный ручной запуск (ключевой момент: рабочая директория)

Ошибка, которую мы уже ловили:

```
PermissionError: /home/<твой_юзер>/.streamlit/secrets.toml
```

Причина: Streamlit ищет `.streamlit` относительно **текущей директории**.

Правило №1: **всегда запускать из `/home/awgweb`**.

Правильная команда запуска:

```bash
sudo -u awgweb -H bash -lc 'cd /home/awgweb && /home/awgweb/venv/bin/streamlit run /home/awgweb/awg_web.py --server.address 0.0.0.0 --server.port 8501'
```

## 9) Открыть порт (если включён firewall)

Если `ufw` активен:

```bash
sudo ufw allow 8501/tcp
sudo ufw status
```

Открыть в браузере:

```
http://<IP_сервера>:8501
```

## 10) Автозапуск при перезагрузке (systemd)

### 10.1 Создать unit

```bash
sudo nano /etc/systemd/system/awgweb.service
```

Вставьте:

```
[Unit]
Description=AWG Streamlit Web Panel
After=network-online.target
Wants=network-online.target

[Service]
User=awgweb
Group=awgweb
WorkingDirectory=/home/awgweb
Environment=HOME=/home/awgweb
ExecStart=/home/awgweb/venv/bin/streamlit run /home/awgweb/awg_web.py --server.address 0.0.0.0 --server.port 8501 --server.headless true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Ключевой параметр:

```
WorkingDirectory=/home/awgweb
```

### 10.2 Включить и запустить

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now awgweb
sudo systemctl status awgweb
```

### 10.3 Логи если не стартует

```bash
journalctl -u awgweb -n 200 --no-pager
```

## 11) Проверка после перезагрузки

```bash
sudo reboot
```

После входа:

```bash
sudo systemctl status awgweb
ss -lntp | grep 8501 || true
```

## 12) Известные проблемы и быстрые решения

### “No module named pip”

```bash
sudo apt install -y python3-pip python3-venv
```

### Терминал “ждёт закрытия кавычки”

Не использовать многострочные команды в кавычках. Делать по шагам (как в разделе 5).

### Streamlit лезет в `/home/<твой_юзер>/.streamlit/...`

- ручной запуск: `cd /home/awgweb && streamlit run ...`
- `systemd`: `WorkingDirectory=/home/awgweb`

### В списке клиентов “INFO/WARN/Managed”

Решено в финальном скрипте: парсится только то, где есть `/client-<name>.conf`.

### QR “не влезает” или падает по версии

Решено в финальном скрипте: QR берётся из ANSI‑вывода `qrencode` и парсится в картинку;  
fallback может не влезть — тогда показывается предупреждение.
инструкция, как развернуть и запускать наш Streamlit-скрипт на новой системе так, чтобы не повторить все ошибки, которые мы уже ловили: отсутствие pip, зависание многострочных команд, неправильная рабочая директория (из-за чего Streamlit лез в /home/<твой_юзер>/.streamlit/secrets.toml), права, sudoers, автозапуск.

1) Проверки перед началом
1.1 Убедись, что awg-client есть и работает от root
sudo /usr/local/bin/awg-client help | head -n 20

Если файл не там — найди:

which awg-client || sudo find / -maxdepth 3 -name awg-client 2>/dev/null

Запомни путь — он понадобится в sudoers и в скрипте.

2) Создаём пользователя для веб-панели (не root)
sudo adduser --disabled-password --gecos "" awgweb
3) Настраиваем sudo без пароля ТОЛЬКО для awg-client

Открыть:

sudo visudo -f /etc/sudoers.d/awgweb-awgclient

Вставить (путь должен совпадать с реальным):

awgweb ALL=(root) NOPASSWD: /usr/local/bin/awg-client

Проверка:

sudo -u awgweb -H sudo /usr/local/bin/awg-client list

✅ Должно отработать без запроса пароля.

4) Ставим pip и venv (ошибка “No module named pip”)

На новой системе часто нет pip — ставим:

sudo apt update
sudo apt install -y python3-pip python3-venv
python3 -m pip --version

✅ Должно показать версию pip.

5) Создаём venv и ставим зависимости (без многострочных команд)

⚠️ Мы уже ловили проблему, что многострочную команду в кавычках неудобно вставлять/терминал “ждёт закрытия кавычки”. Поэтому делаем по шагам.

5.1 Создать venv
sudo -u awgweb -H python3 -m venv /home/awgweb/venv
5.2 Обновить pip в venv
sudo -u awgweb -H /home/awgweb/venv/bin/pip install --upgrade pip
5.3 Установить зависимости
sudo -u awgweb -H /home/awgweb/venv/bin/pip install streamlit qrcode[pil] pillow

Проверка:

sudo -u awgweb -H /home/awgweb/venv/bin/streamlit --version
6) Подготовить конфиг Streamlit для awgweb (важно для наших PermissionError)

Создаём домашнюю директорию Streamlit именно для awgweb:

sudo -u awgweb -H bash -lc '
mkdir -p /home/awgweb/.streamlit
touch /home/awgweb/.streamlit/secrets.toml
chmod 700 /home/awgweb/.streamlit
chmod 600 /home/awgweb/.streamlit/secrets.toml
'

Опционально выключить сбор статистики:

sudo -u awgweb -H bash -lc 'cat > /home/awgweb/.streamlit/config.toml <<EOF
[browser]
gatherUsageStats = false
EOF
chmod 600 /home/awgweb/.streamlit/config.toml'
7) Сохраняем скрипт

Файл: /home/awgweb/awg_web.py

sudo nano /home/awgweb/awg_web.py

Вставь туда финальный код (который мы собрали), сохрани и выйди.

Права:

sudo chown awgweb:awgweb /home/awgweb/awg_web.py
chmod 600 /home/awgweb/awg_web.py
8) Правильный ручной запуск (ключевой момент: рабочая директория)
Почему это важно

Мы уже поймали ошибку:
PermissionError: /home/kolandor/.streamlit/secrets.toml

Причина была не в HOME, а в том, что Streamlit ищет .streamlit относительно текущей директории (cwd).
Если запускать из /home/kolandor, он полезет в /home/kolandor/.streamlit.

✅ Поэтому правило №1: всегда запускать из /home/awgweb.

Правильная команда запуска:
sudo -u awgweb -H bash -lc 'cd /home/awgweb && /home/awgweb/venv/bin/streamlit run /home/awgweb/awg_web.py --server.address 0.0.0.0 --server.port 8501'
9) Открыть порт (если включён firewall)

Если ufw активен:

sudo ufw allow 8501/tcp
sudo ufw status

Открыть в браузере:
http://<IP_сервера>:8501

10) Автозапуск при перезагрузке (systemd) — правильный, повторяемый способ
10.1 Создай unit
sudo nano /etc/systemd/system/awgweb.service

Вставь:

[Unit]
Description=AWG Streamlit Web Panel
After=network-online.target
Wants=network-online.target

[Service]
User=awgweb
Group=awgweb
WorkingDirectory=/home/awgweb
Environment=HOME=/home/awgweb
ExecStart=/home/awgweb/venv/bin/streamlit run /home/awgweb/awg_web.py --server.address 0.0.0.0 --server.port 8501 --server.headless true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

Здесь самый важный параметр:
✅ WorkingDirectory=/home/awgweb — именно он предотвращает повтор “/home/kolandor/.streamlit”.

10.2 Включить и запустить
sudo systemctl daemon-reload
sudo systemctl enable --now awgweb
sudo systemctl status awgweb
10.3 Логи если не стартует
journalctl -u awgweb -n 200 --no-pager
11) Проверка после перезагрузки

Перезагрузить:

sudo reboot

После входа:

sudo systemctl status awgweb
ss -lntp | grep 8501 || true
12) Список “известных проблем” и быстрые решения
✅ “No module named pip”
sudo apt install -y python3-pip python3-venv
✅ Терминал не запускает “многострочную команду”

Не использовать многострочные команды в кавычках. Делать по шагам (как в разделе 5).

✅ Streamlit лезет в /home/<твой_юзер>/.streamlit/... и падает

Запускать только так:

ручной запуск: cd /home/awgweb && streamlit run ...

systemd: WorkingDirectory=/home/awgweb

✅ В списке клиентов появлялись “INFO/WARN/Managed”

Решено в финальном скрипте: парсится только то, где есть /client-<name>.conf.

✅ QR “не влезает” или падает по версии

Решено в финальном скрипте: QR берётся из ANSI-вывода qrencode и парсится в картинку; fallback может не влезть — тогда показывается предупреждение.