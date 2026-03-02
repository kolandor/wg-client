# wg-client — быстрый запуск WireGuard на Raspberry Pi

Цель: поднять WireGuard full-tunnel на Raspberry Pi 3B с Raspberry Pi OS Lite 64-bit  
Клиенты выходят в интернет с домашнего IP.  
DDNS/Endpoint: `mindwave.dscloud.biz`  
Управление клиентами: скрипт `wg-client`

## Что будет в результате

- сервер WireGuard `wg0` с NAT через `eth0`
- автозапуск WireGuard
- удобное добавление/экспорт клиентов через `wg-client`

## 1) Подготовка Raspberry Pi OS

### 1.1 Обновление системы

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

### 1.2 Установка пакетов

```bash
sudo apt install -y wireguard wireguard-tools iptables qrencode
```

Проверки:

```bash
wg --version
iptables --version
```

## 2) Базовая сеть (желательно только Ethernet)

Проверьте, что интернет идёт через Ethernet:

```bash
ip route get 1.1.1.1
```

В ответе должно быть `dev eth0`.

MAC Ethernet (для DHCP reservation на роутере):

```bash
cat /sys/class/net/eth0/address
```

## 3) Настройка WireGuard сервера (`wg0`)

### 3.1 Включить IP forwarding

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system
sudo sysctl net.ipv4.ip_forward
```

Должно быть `= 1`.

### 3.2 Ключи сервера

```bash
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

umask 077
wg genkey | sudo tee /etc/wireguard/server.key > /dev/null
sudo cat /etc/wireguard/server.key | wg pubkey | sudo tee /etc/wireguard/server.pub > /dev/null

sudo cat /etc/wireguard/server.pub
```

### 3.3 Конфиг сервера `/etc/wireguard/wg0.conf`

Создаём full-tunnel с NAT через `eth0`:

```bash
SERVER_PRIV=$(sudo cat /etc/wireguard/server.key)

sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV

# Full-tunnel: NAT, чтобы клиенты выходили в интернет через ваш дом
PostUp   = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF
```

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

Если у вас интерфейс называется не `eth0`, посмотрите:

```bash
ip route show default
```

и замените `-o eth0` на нужное имя.

### 3.4 Запуск WireGuard и автозапуск

```bash
sudo systemctl enable --now wg-quick@wg0
sudo systemctl status wg-quick@wg0 --no-pager -l
```

Проверки:

```bash
sudo wg show
ip a show wg0
```

## 4) Роутер и DDNS

### 4.1 Проброс порта на роутере

Сделайте Port Forward:

```
UDP 51820 → LAN IP Raspberry (например 192.168.1.92) : 51820
```

### 4.2 DDNS

DDNS: `mindwave.dscloud.biz`.  
Проверьте, что он указывает на ваш текущий внешний IP (обычно в панели DDNS/роутера).

## 5) Скрипт `wg-client`

### 5.1 Установка `wg-client`

Создайте файл:

```bash
sudo nano /usr/local/bin/wg-client
```

Вставьте в него вашу финальную версию `wg-client` (ту, что мы довели до `add/list/show/export/delete`).

Сделайте исполняемым:

```bash
sudo chmod +x /usr/local/bin/wg-client
```

Проверка:

```bash
sudo wg-client help
```

## 6) Создание клиентов через `wg-client`

### 6.1 Создать клиента full-tunnel (весь интернет через дом)

```bash
sudo wg-client add phone
```

### 6.2 Посмотреть конфиг + QR (удобно для Android)

```bash
sudo wg-client show phone
```

В терминале вы увидите полный конфиг `client-phone.conf`.  
Ниже будет QR (если установлен `qrencode`).

### 6.3 Список клиентов

```bash
sudo wg-client list
```

## 7) Передача конфига на Windows

Есть 2 удобных способа.

### Способ A: Copy/Paste из `show` (без скачивания)

На Raspberry:

```bash
sudo wg-client show phone
```

Скопируйте блок конфигурации из терминала и вставьте в Блокнот.  
Сохраните как `client-phone.conf`.

В WireGuard for Windows: **Add Tunnel → Import from file** и выберите файл.

### Способ B: `export` + `scp`

На Raspberry:

```bash
sudo wg-client export phone
```

Скрипт создаст копию в `/home/<user>/client-phone.conf` и распечатает команду `scp`.

На Windows PowerShell (пример):

```powershell
scp kolandor@192.168.1.92:client-phone.conf ".\client-phone.conf"
```

После скачивания (по желанию) удалите экспортированный файл на Pi:

```bash
rm -f /home/kolandor/client-phone.conf
```

## 8) Подключение клиентов

### 8.1 Windows

Установите WireGuard for Windows.  
**Import tunnel(s) from file →** `client-xxx.conf`  
Активируйте туннель.

### 8.2 Android

Установите WireGuard.  
**Add → Scan from QR**  
Отсканируйте QR из `sudo wg-client show <name>`.

## 9) Проверка работы (самое важное)

### 9.1 На сервере (Raspberry)

Смотрим handshake:

```bash
sudo wg show
```

Должен появиться `latest handshake` у peer.

### 9.2 На клиенте

Откройте сайт “what is my ip” — должен показывать ваш домашний внешний IP.

## 10) Удаление клиента

Удалить клиента и его доступ:

```bash
sudo wg-client delete phone
```

Проверить, что в `wg0.conf` его нет:

```bash
sudo grep -n "phone" /etc/wireguard/wg0.conf || echo "phone not found"
sudo wg show
```

## 11) Типовые проблемы и быстрые решения

### 11.1 Handshake не появляется

- проверьте проброс UDP `51820` на роутере
- проверьте, что DDNS указывает на правильный внешний IP
- возможен CGNAT у провайдера (тогда прямое подключение “с улицы” не заработает)

### 11.2 Handshake есть, но интернета нет

Обычно:

- не включён `ip_forward`
- нет NAT (`MASQUERADE`)
- отсутствует `iptables`

Проверки:

```bash
sudo sysctl net.ipv4.ip_forward
sudo iptables -t nat -S | grep MASQUERADE
```

## 12) Важные замечания по безопасности

`client-*.conf` содержит приватный ключ клиента. Не публикуйте его и не отправляйте “куда попало”.

Если приватный ключ случайно “засветили” — проще всего:

```bash
sudo wg-client delete <name>
sudo wg-client add <name>
```

и заменить конфиг на клиенте.
Ниже — цельная инструкция “от нуля до рабочего VPN”, рассчитанная на вашу текущую схему:
Raspberry Pi 3B + Raspberry Pi OS Lite 64-bit


VPN: WireGuard full-tunnel (клиент выходит в интернет с домашнего IP)


Endpoint/DDNS: mindwave.dscloud.biz


Управление клиентами через скрипт wg-client



1) Подготовка Raspberry Pi OS
1.1 Обновление системы
sudo apt update
sudo apt full-upgrade -y
sudo reboot

1.2 Установка пакетов
sudo apt install -y wireguard wireguard-tools iptables qrencode

Проверки:
wg --version
iptables --version


2) Базовая настройка сети (желательно только Ethernet)
Проверить, что интернет идёт через Ethernet:
ip route get 1.1.1.1

должно быть dev eth0.
MAC Ethernet (для DHCP reservation на роутере):
cat /sys/class/net/eth0/address


3) Настройка WireGuard сервера (wg0)
3.1 Включить IP forwarding
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system
sudo sysctl net.ipv4.ip_forward

Должно быть = 1.
3.2 Ключи сервера
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

umask 077
wg genkey | sudo tee /etc/wireguard/server.key > /dev/null
sudo cat /etc/wireguard/server.key | wg pubkey | sudo tee /etc/wireguard/server.pub > /dev/null

sudo cat /etc/wireguard/server.pub

3.3 Конфиг сервера /etc/wireguard/wg0.conf
Создаём full-tunnel с NAT через eth0:
SERVER_PRIV=$(sudo cat /etc/wireguard/server.key)

sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV

# Full-tunnel: NAT, чтобы клиенты выходили в интернет через ваш дом
PostUp   = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

sudo chmod 600 /etc/wireguard/wg0.conf

Если у вас интерфейс называется не eth0, смотрите:
ip route show default

и замените -o eth0 на нужное имя.
3.4 Запуск WireGuard и автозапуск
sudo systemctl enable --now wg-quick@wg0
sudo systemctl status wg-quick@wg0 --no-pager -l

Проверки:
sudo wg show
ip a show wg0


4) Роутер / DDNS
4.1 Проброс порта на роутере
Сделайте Port Forward:
UDP 51820 → LAN IP Raspberry (например 192.168.1.92) : 51820


4.2 DDNS
У вас DDNS: mindwave.dscloud.biz.
Проверьте, что он указывает на ваш текущий внешний IP (обычно в панели DDNS/роутера).

5) Скрипт wg-client (управление клиентами)
5.1 Установка wg-client
Создайте файл:
sudo nano /usr/local/bin/wg-client

Вставьте в него вашу финальную версию wg-client (ту, что мы довели до add/list/show/export/delete).
Сделайте исполняемым:
sudo chmod +x /usr/local/bin/wg-client

Проверка:
sudo wg-client help


6) Создание клиентов через wg-client
6.1 Создать клиента full-tunnel (весь интернет через дом)
sudo wg-client add phone

6.2 Посмотреть конфиг + QR (удобно для Android)
sudo wg-client show phone

В терминале вы увидите полный конфиг client-phone.conf


Ниже будет QR (если установлен qrencode)


6.3 Список клиентов
sudo wg-client list


7) Передача конфига на Windows
Есть 2 удобных способа.
Способ A: Copy/Paste из show (без скачивания)
На Raspberry:

 sudo wg-client show phone


Скопируйте блок конфигурации из терминала и вставьте в Блокнот.


Сохраните как client-phone.conf.


В WireGuard for Windows: Add Tunnel → Import from file и выберите файл.


Способ B: export + scp (удобно, если копировать не хочется)
На Raspberry
sudo wg-client export phone

Скрипт создаст копию в /home/<user>/client-phone.conf и распечатает команду scp.
На Windows PowerShell
Пример:
scp kolandor@192.168.1.92:client-phone.conf ".\client-phone.conf"

После скачивания (по желанию) удалить экспортированный файл на Pi:
rm -f /home/kolandor/client-phone.conf


8) Подключение клиентов
8.1 Windows
Установить WireGuard for Windows


Import tunnel(s) from file → client-xxx.conf


Активировать туннель


8.2 Android
Установить WireGuard


Add → Scan from QR


Отсканировать QR из sudo wg-client show <name>



9) Проверка работы (самое важное)
9.1 На сервере (Raspberry)
Смотрим handshake:
sudo wg show

Должно появиться latest handshake у peer.
9.2 На клиенте
Откройте сайт “what is my ip” — должен показывать ваш домашний внешний IP.

10) Удаление клиента
Удалить клиента и его доступ:
sudo wg-client delete phone

Проверить, что в wg0.conf его нет:
sudo grep -n "phone" /etc/wireguard/wg0.conf || echo "phone not found"
sudo wg show


11) Типовые проблемы и быстрые решения
11.1 Handshake не появляется
проверьте проброс UDP 51820 на роутере


проверьте, что DDNS указывает на правильный внешний IP


возможен CGNAT у провайдера (тогда прямое подключение “с улицы” не заработает)


11.2 Handshake есть, но интернета нет
Обычно:
не включён ip_forward


нет NAT (MASQUERADE)


отсутствует iptables


Проверки:
sudo sysctl net.ipv4.ip_forward
sudo iptables -t nat -S | grep MASQUERADE


12) Важные замечания по безопасности
client-*.conf содержит приватный ключ клиента. Не публикуйте его и не отправляйте “куда попало”.


Если приватный ключ случайно “засветили” — проще всего:

 sudo wg-client delete <name>
sudo wg-client add <name>
 и заменить конфиг на клиенте.
