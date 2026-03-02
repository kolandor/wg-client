# awg-client — быстрый запуск AmneziaWG на Raspberry Pi

Цель: поднять AmneziaWG full-tunnel на Raspberry Pi 3B с Ubuntu Server 22.04 LTS (arm64)  
Клиенты выходят в интернет с домашнего IP.  
DDNS/Endpoint: `mindwave.dscloud.biz`  
Управление клиентами: скрипт `awg-client`

## Что будет в результате

- сервер AmneziaWG `awg0` с NAT через WAN-интерфейс
- автозапуск AmneziaWG
- удобное добавление/проверка клиентов через `awg-client`

## 0) Предпосылки и требования

- Raspberry Pi 3B (или лучше), стабильная сеть и питание
- белый IP (пусть динамический) + настроенный DDNS
- доступ к роутеру для проброса портов
- желательно подключение Pi по Ethernet

## 1) Установка ОС и базовая подготовка

Ставим Ubuntu Server 22.04 LTS (arm64).

Обновляем систему:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

После ребута проверяем:

```bash
lsb_release -a
ip -br a
```

## 2) Сетевые основы: выбрать WAN-интерфейс

Если подняты и `eth0`, и `wlan0`, определите, через что идёт интернет:

```bash
ip route get 1.1.1.1
```

В выводе будет `dev eth0` или `dev wlan0`. Это ваш WAN-интерфейс.

Рекомендация: оставьте один основной интерфейс (обычно `eth0`), Wi‑Fi можно выключить:

```bash
sudo nmcli radio wifi off
```

## 3) Включить IPv4 forwarding

```bash
sudo tee /etc/sysctl.d/99-amneziawg.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
EOF

sudo sysctl --system
sysctl net.ipv4.ip_forward
```

Должно быть:

```
net.ipv4.ip_forward = 1
```

## 4) NAT для full-tunnel

### 4.1 Установить сохранение правил iptables

```bash
sudo apt update
sudo apt install -y iptables-persistent
```

### 4.2 Добавить правила (пример WAN=`eth0`, VPN=`awg0`)

```bash
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i awg0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

Сохранить и включить:

```bash
sudo netfilter-persistent save
sudo systemctl enable --now netfilter-persistent
```

Проверки:

```bash
sudo iptables -t nat -S | grep MASQUERADE
sudo iptables -S FORWARD | grep -E 'awg0|eth0'
```

Примечание: установщик AmneziaWG тоже добавляет правила iptables через `awg-quick`.  
Иногда появляются дубли MASQUERADE — это не ломает работу.

## 5) Установка AmneziaWG (скрипт Varckin)

```bash
curl -O https://raw.githubusercontent.com/Varckin/amneziawg-install/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
sudo ./amneziawg-install.sh
```

### 5.1 Рекомендованные ответы мастера

- Public IPv4 or domain: ваш DDNS (пример: `mindwave.dscloud.biz`)
- Public interface: `eth0` (или ваш WAN)
- Interface name: `awg0`
- Server IPv4: `10.66.66.1` (Enter)
- Server IPv6: оставить предложенное (Enter)
- Port: случайный высокий UDP (пример: `42857`)
- DNS1/DNS2: например `9.9.9.9` и `1.0.0.1`
- AllowedIPs: `0.0.0.0/0,::/0` (full-tunnel)
- Jc/Jmin/Jmax/S1/S2/H1–H4: оставить как предлагает скрипт (Enter)
- Client name: латиница/цифры/_/-, до 15 символов, например `phone`

## 6) Проверка, что сервер работает

### 6.1 Сервис и интерфейс

```bash
sudo systemctl status awg-quick@awg0 --no-pager
sudo ip -br a | grep awg0
```

Важно: `awg-quick@awg0` может быть `active (exited)` — это нормально для quick-юнитов.

### 6.2 Порт слушается

```bash
sudo ss -lunp | grep 42857
```

### 6.3 Статус пиров/хэндшейка

```bash
sudo awg show
```

Смотрите:

- `latest handshake` должен обновляться
- `transfer` — растут байты

## 7) Роутер и DDNS

Закрепите за Raspberry Pi постоянный LAN‑IP (DHCP reservation), например `192.168.1.92`.

Port Forwarding:

```
UDP 42857 → 192.168.1.92:42857
```

Убедитесь, что DDNS указывает на текущий внешний IP.

## 8) Клиенты: подключение и “весь трафик через VPN”

Импортируйте конфиг/QR в Amnezia (или совместимый клиент, если он поддерживает AWG-параметры).

Проверьте, что внешний IP стал вашим домашним:

- откройте на клиенте сайт проверки IP

Если интернет не работает, чаще всего виновато:

- порт не проброшен / не тот IP / не тот порт
- `ip_forward` не включён
- NAT/iptables не применились
- у клиента конфликт подсетей

## 9) Типовые проблемы и быстрые решения

### 9.1 Есть handshake, но нет интернета

Проверить:

```bash
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S | grep MASQUERADE
sudo iptables -S FORWARD | grep awg0
```

Должно быть:

- `ip_forward=1`
- MASQUERADE на WAN-интерфейс
- FORWARD разрешён `awg0 → WAN`

### 9.2 Нет handshake вообще

Проверить:

- проброс UDP на роутере
- DDNS резолвится в ваш внешний IP
- провайдер не режет входящий UDP
- сервер слушает порт:

```bash
sudo ss -lunp | grep PORT
```

### 9.3 Дублируются правила iptables

Можно почистить вручную, но если всё работает — можно оставить.

## 10) Регламент обслуживания

Обновления раз в какое-то время:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

После обновления ядра DKMS-модуль пересоберётся автоматически.

Проверка после обновления:

```bash
sudo systemctl status awg-quick@awg0 --no-pager
sudo awg show
```

## 11) Шпаргалка команд

```bash
# Проверить WAN интерфейс
ip route get 1.1.1.1

# Включить forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-amneziawg.conf
sudo sysctl --system

# NAT (WAN=eth0)
sudo apt install -y iptables-persistent
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i awg0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo netfilter-persistent save

# AmneziaWG install
curl -O https://raw.githubusercontent.com/Varckin/amneziawg-install/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
sudo ./amneziawg-install.sh

# Проверки
sudo systemctl status awg-quick@awg0 --no-pager
sudo ss -lunp | grep 42857
sudo awg show
```

## 12) Установка `awg-client`

Создайте файл:

```bash
sudo nano /usr/local/bin/awg-client
```

Вставьте в него весь скрипт (от `#!/usr/bin/env bash` до `main "$@"`).

Сделайте исполняемым и проверьте:

```bash
sudo chmod +x /usr/local/bin/awg-client
sudo awg-client help
sudo awg-client list
```

## 13) Важные отличия от WireGuard

- В клиентском конфиге AmneziaWG обязательно добавляются параметры `Jc/Jmin/Jmax/S1/S2/H1–H4` в секцию `[Interface]`.
- Установщик использует `### Client <name>` как маркер и `awg syncconf ... <(awg-quick strip ...)` для применения.  
  Мы делаем так же, чтобы всё было совместимо с тем, что уже стоит.
AmneziaWG на Raspberry Pi (Ubuntu 22.04 LTS, DDNS, full-tunnel)
0) Предпосылки и требования
Raspberry Pi 3B (или лучше), питание и стабильная сеть.


Белый IP (пусть динамический) + настроенный DDNS (у вас: mindwave.dscloud.biz).


Доступ к роутеру для проброса портов.


Желательно: подключение Pi по Ethernet (стабильнее, меньше сюрпризов).



1) Установка ОС и базовая подготовка
Ставим Ubuntu Server 22.04 LTS (arm64).


Логинимся по SSH/консоли и обновляем систему:


sudo apt update
sudo apt full-upgrade -y
sudo reboot
После ребута проверяем:


lsb_release -a
ip -br a

2) Сетевые основы: выбрать “внешний” интерфейс
Если у вас и eth0, и wlan0 подняты — определите, через что реально идёт интернет:
ip route get 1.1.1.1
В выводе будет dev eth0 или dev wlan0. Это ваш WAN-интерфейс.
Рекомендация: оставьте один основной интерфейс (обычно eth0), Wi-Fi можно выключить:
sudo nmcli radio wifi off

3) Включить IPv4 forwarding (обязательно для full-tunnel)
sudo tee /etc/sysctl.d/99-amneziawg.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
EOF

sudo sysctl --system
sysctl net.ipv4.ip_forward
Должно быть:
net.ipv4.ip_forward = 1

4) NAT (чтобы клиенты выходили в интернет через ваш IP)
4.1 Установить сохранение правил iptables
sudo apt update
sudo apt install -y iptables-persistent
4.2 Добавить правила (пример для WAN=eth0, VPN=awg0)
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i awg0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
Сохранить:
sudo netfilter-persistent save
sudo systemctl enable --now netfilter-persistent
Проверка:
sudo iptables -t nat -S | grep MASQUERADE
sudo iptables -S FORWARD | grep -E 'awg0|eth0'
Примечание: установщик AmneziaWG тоже добавляет правила iptables через wg-quick/awg-quick. Поэтому иногда появляются дубли MASQUERADE. Это не ломает работу, но можно чистить.

5) Установка AmneziaWG (скрипт Varckin)
curl -O https://raw.githubusercontent.com/Varckin/amneziawg-install/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
sudo ./amneziawg-install.sh
5.1 Как отвечать на вопросы мастера (рекомендованный профиль)
Public IPv4 or domain: ваш DDNS (пример: mindwave.dscloud.biz)


Public interface: eth0 (или wlan0, если у вас WAN по Wi-Fi)


Interface name: awg0


Server IPv4: 10.66.66.1 (Enter)


Server IPv6: оставить предложенное (Enter)


Port: случайный высокий UDP (пример: 42857)


DNS1/DNS2: например 9.9.9.9 и 1.0.0.1


AllowedIPs: 0.0.0.0/0,::/0 (full-tunnel)


Jc/Jmin/Jmax/S1/S2/H1–H4: оставить как предлагает скрипт (Enter)


В конце введите Client name (латиница/цифры/_/-, до 15 символов), например phone.

6) Проверка, что сервер работает
6.1 Сервис и интерфейс
sudo systemctl status awg-quick@awg0 --no-pager
sudo ip -br a | grep awg0
Важно: awg-quick@awg0 может быть active (exited) — это нормально для quick-юнитов.
6.2 Порт слушается
(для вашего примера порта 42857)
sudo ss -lunp | grep 42857
6.3 Статус пиров/хэндшейка
sudo awg show
Смотрите:
latest handshake должен обновляться


transfer — растут байты



7) Настройка роутера (самое важное для доступа извне)
Закрепите за Raspberry Pi постоянный LAN-IP (DHCP reservation), например 192.168.1.92.


Port Forwarding:


UDP 42857 → 192.168.1.92:42857


Убедитесь, что DDNS указывает на текущий внешний IP.



8) Клиенты: подключение и “весь трафик через VPN”
Импортируете конфиг/QR в Amnezia (или совместимый клиент, если он поддерживает AWG параметры).


Проверяете, что “IP наружу” стал вашим:


откройте на клиенте сайт проверки IP


Если интернет не работает, чаще всего виновато:


порт не проброшен/не тот IP/не тот порт,


ip_forward не включён,


NAT/iptables не применились,


у клиента конфликт подсетей.



9) Типовые проблемы и быстрые решения
9.1 Есть handshake, но нет интернета
Проверить:
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S | grep MASQUERADE
sudo iptables -S FORWARD | grep awg0
Должно быть:
ip_forward=1


MASQUERADE на WAN интерфейс


FORWARD разрешён awg0→WAN


9.2 Нет handshake вообще
Проверить:
проброс UDP на роутере


DDNS резолвится в ваш внешний IP


провайдер не режет входящий UDP


сервер слушает порт: ss -lunp | grep PORT


9.3 Дублируются правила iptables
Можно почистить вручную (аккуратно), но если всё работает — можно оставить.

10) Регламент обслуживания
Обновления раз в какое-то время:


sudo apt update
sudo apt full-upgrade -y
sudo reboot
После обновления ядра DKMS-модуль пересоберётся автоматически.


Проверка после обновления:


sudo systemctl status awg-quick@awg0 --no-pager
sudo awg show

11) Шпаргалка команд “на один лист”
# Проверить WAN интерфейс
ip route get 1.1.1.1

# Включить forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-amneziawg.conf
sudo sysctl --system

# NAT (WAN=eth0)
sudo apt install -y iptables-persistent
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i awg0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo netfilter-persistent save

# AmneziaWG install
curl -O https://raw.githubusercontent.com/Varckin/amneziawg-install/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
sudo ./amneziawg-install.sh

# Проверки
sudo systemctl status awg-quick@awg0 --no-pager
sudo ss -lunp | grep 42857
sudo awg show

11) Установка awg-client через nano
1️⃣ Открываем новый файл
sudo nano /usr/local/bin/awg-client
2️⃣ Вставляем туда весь скрипт
Скопируйте весь скрипт, который я прислал выше (от #!/usr/bin/env bash до main "$@")


Вставьте в nano
 (в терминале обычно: ПКМ → Paste или Shift+Insert)


3️⃣ Сохраняем файл
В nano:
Нажмите Ctrl + O


Нажмите Enter


Затем Ctrl + X


4️⃣ Делаем файл исполняемым
sudo chmod +x /usr/local/bin/awg-client
5️⃣ Проверяем
sudo awg-client help
Если всё правильно — увидите справку.
🔎 Проверим сразу работу
Попробуйте:
sudo awg-client list
Если всё корректно подключено к вашему установленному AmneziaWG — он покажет существующих клиентов.


Важные отличия от твоего WireGuard-скрипта
В клиентском конфиге AmneziaWG обязательно добавляются параметры Jc/Jmin/Jmax/S1/S2/H1–H4 в секцию [Interface] — иначе клиент будет “обычным WG” и может не цепляться там, где AWG нужен.


Установщик использует ### Client <name> как маркер и awg syncconf … <(awg-quick strip …) для применения. Мы делаем так же, чтобы всё было совместимо с тем, что уже стоит.

