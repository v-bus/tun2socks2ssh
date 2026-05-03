# tun2socks-macos-project

Проект для macOS, который строит схему:

```text
macOS default route
  -> utun123 / tun2socks
  -> local GOST SOCKS balancer 127.0.0.1:1090
  -> 10 parallel ssh -D tunnels 127.0.0.1:1080..1089
  -> remote SSH server
```

При этом `routeguard` от root постоянно проверяет и восстанавливает маршруты:

```text
SSH_SERVER_IP -> real gateway via REAL_IF
default       -> TUN_GW / TUN_IF
```

Главная цель: не дать macOS сломать host route до SSH-сервера или вернуть default route на обычный Wi-Fi/Ethernet после DHCP renew, переподключения Wi-Fi, sleep/wake, VPN-событий и т.п.

> Важно: это техническая схема поверх SSH SOCKS. Для постоянного production-VPN обычно проще WireGuard. Эта схема полезна, когда нужен именно `ssh -D + tun2socks`.

---

## Состав проекта

```text
tun2socks-macos-project/
├── README.md
├── ansible/
│   ├── install-tun2socks-macos.yml
│   └── inventory.example.ini
├── bin/
│   ├── install-tools-macos.sh
│   ├── start-tun2socks.sh
│   ├── stop-tun2socks.sh
│   └── tun2socks-routeguard.sh
├── config/
│   └── tun2socks.conf.example
└── launchd/
    └── local.tun2socks.routeguard.plist
```

---

## Что устанавливается

- `tun2socks` — TUN-интерфейс, который отправляет IP-трафик в SOCKS-прокси.
- `gost` — локальный SOCKS5-балансировщик.
- `10 × ssh -D` — десять параллельных SSH SOCKS-туннелей.
- `routeguard` — root-watchdog для восстановления маршрутов.
- `launchd` daemon — автозапуск `routeguard` от root.

---

## Логика балансировки

Один `ssh -D` уже обслуживает много TCP-соединений через SSH channels, но все они идут внутри одного TCP transport. При потерях/задержках возможен head-of-line blocking.

Поэтому проект поднимает 10 независимых SSH transport-соединений:

```text
127.0.0.1:1080
127.0.0.1:1081
127.0.0.1:1082
...
127.0.0.1:1089
```

Затем GOST открывает один локальный SOCKS5 endpoint:

```text
127.0.0.1:1090
```

и распределяет новые соединения по upstream SOCKS-портам:

```text
socks5://127.0.0.1:1080,127.0.0.1:1081,...,127.0.0.1:1089?strategy=round
```

`tun2socks` подключается только к GOST:

```text
tun2socks -> socks5://127.0.0.1:1090
```

---

## Источники/ориентиры по инструментам

- tun2socks: https://github.com/xjasonlyu/tun2socks
- tun2socks macOS example: https://github.com/xjasonlyu/tun2socks/wiki/Examples#macos
- GOST: https://gost.run/en/
- GOST selector/load balancing: https://gost.run/en/concepts/selector/
- Homebrew gost formula: https://formulae.brew.sh/formula/gost

---

## Быстрая установка через Ansible

### 1. Установить Ansible

```bash
brew install ansible
```

### 2. Распаковать проект

```bash
unzip tun2socks-macos-project-v2.zip
cd tun2socks-macos-project-v2
```

### 3. Запустить playbook

Замените значения под ваш сервер:

```bash
ansible-playbook -i ansible/inventory.example.ini ansible/install-tun2socks-macos.yml \
  --ask-become-pass \
  --extra-vars "ssh_user=user ssh_host=203.0.113.10 ssh_ip=203.0.113.10 real_if=en0 ssh_tunnels_count=10"
```

Playbook:

1. копирует скрипты в `/usr/local/sbin`;
2. создаёт `/usr/local/etc/tun2socks.conf`;
3. устанавливает `gost` через Homebrew;
4. скачивает `tun2socks` из GitHub Releases;
5. устанавливает `launchd` daemon для `routeguard`;
6. включает `routeguard`.

---

## Ручная установка

### 1. Установить gost и tun2socks

```bash
chmod +x bin/install-tools-macos.sh
./bin/install-tools-macos.sh
```

По умолчанию используется:

```bash
TUN2SOCKS_VERSION=v2.6.0
```

Можно переопределить:

```bash
TUN2SOCKS_VERSION=v2.6.0 ./bin/install-tools-macos.sh
```

### 2. Установить скрипты

```bash
sudo mkdir  /usr/local/sbin
sudo install -m 0755 bin/start-tun2socks.sh /usr/local/sbin/start-tun2socks.sh
sudo install -m 0755 bin/stop-tun2socks.sh /usr/local/sbin/stop-tun2socks.sh
sudo install -m 0755 bin/tun2socks-routeguard.sh /usr/local/sbin/tun2socks-routeguard.sh
```

### 3. Установить конфиг

```bash
sudo mkdir /usr/local/etc
sudo cp config/tun2socks.conf.example /usr/local/etc/tun2socks.conf
sudo nano /usr/local/etc/tun2socks.conf

ssh-keyscan -p 22 123.123.123.123 | sudo tee /usr/local/etc/tun2socks_known_hosts >/dev/null
sudo chmod 644 /usr/local/etc/tun2socks_known_hosts
```

Минимально заменить:

```bash
REAL_IF="en0"
SSH_USER="user"
SSH_HOST="203.0.113.10"
SSH_IP="203.0.113.10"
SSH_PORT="22"
SSH_TUNNELS_COUNT="10"
```

Определить реальный интерфейс:

```bash
route -n get default | awk '/interface:/ {print $2}'
```

Определить реальный gateway:

```bash
route -n get default | awk '/gateway:/ {print $2}'
```

### 4. Установить launchd daemon routeguard

```bash
sudo cp launchd/local.tun2socks.routeguard.plist /Library/LaunchDaemons/local.tun2socks.routeguard.plist
sudo chown root:wheel /Library/LaunchDaemons/local.tun2socks.routeguard.plist
sudo chmod 644 /Library/LaunchDaemons/local.tun2socks.routeguard.plist
```

Загрузить:

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/local.tun2socks.routeguard.plist
sudo launchctl enable system/local.tun2socks.routeguard
```

Проверить:

```bash
sudo launchctl print system/local.tun2socks.routeguard
```

## dnscrypt-proxy

```text
macOS DNS → 127.0.0.1:53 → dnscrypt-proxy → Cloudflare DoH → tun2socks → ssh -D
```

### Установка

```bash
brew install dnscrypt-proxy
```

Homebrew прямо указывает, что после запуска `dnscrypt-proxy` нужно направить локальный DNS на `127.0.0.1`. 

### 2. Конфиг dnscrypt-proxy

Откройте конфиг:

```bash
sudo nano /opt/homebrew/etc/dnscrypt-proxy.toml
```

Для Intel Mac путь может быть:

```bash
sudo nano /usr/local/etc/dnscrypt-proxy.toml
```

Найдите и выставьте:

```toml
listen_addresses = ['127.0.0.1:53']

ipv4_servers = true
ipv6_servers = false

dnscrypt_servers = false
doh_servers = true
odoh_servers = false

require_dnssec = false
require_nolog = false
require_nofilter = false

server_names = ['cloudflare', 'cloudflare-ipv6']
```

Если IPv6 в вашей схеме отключён или не маршрутизируется через туннель, лучше оставить:

```toml
ipv6_servers = false
```

А `server_names` можно сделать только IPv4:

```toml
server_names = ['cloudflare']
```

### 3. Запуск dnscrypt-proxy

Проверить вручную:

```bash
sudo dnscrypt-proxy -config /opt/homebrew/etc/dnscrypt-proxy.toml
```

Если Intel Mac:

```bash
sudo dnscrypt-proxy -config /usr/local/etc/dnscrypt-proxy.toml
```

В другом окне:

```bash
dig @127.0.0.1 ifconfig.me
```

Если работает — остановите ручной запуск `Ctrl+C` и запустите как сервис:

```bash
sudo brew services start dnscrypt-proxy
```

Проверка:

```bash
sudo brew services list | grep dnscrypt
```

## 4. Направить DNS macOS на localhost

```bash
sudo networksetup -setdnsservers Wi-Fi 127.0.0.1
```

Проверка:

```bash
networksetup -getdnsservers Wi-Fi
```

Должно быть:

```text
127.0.0.1
```

И:

```bash
scutil --dns | grep -A4 nameserver
```

Должно появиться:

```text
nameserver[0] : 127.0.0.1
```

### 5. Проверка, что DoH идёт через туннель

После запуска `tun2socks`:

```bash
route -n get 1.1.1.1 | egrep "gateway|interface"
```

Ожидаемо:

```text
gateway: 198.18.0.1
interface: utun123
```

Проверка DNS:

```bash
dig @127.0.0.1 ifconfig.me
```

Проверка внешнего IP:

```bash
curl https://ifconfig.me
```

---

## Запуск

```bash
sudo /usr/local/sbin/start-tun2socks.sh
```

Скрипт сделает:

1. определит обычный gateway через `REAL_IF`;
2. добавит host route до `SSH_IP` через обычный gateway;
3. поднимет 10 `ssh -D` туннелей;
4. поднимет GOST SOCKS balancer на `127.0.0.1:1090`;
5. поднимет `tun2socks` на `utun123`;
6. назначит `198.18.0.1` на `utun123`;
7. заменит default route на `198.18.0.1`;
8. оставит `routeguard` следить за маршрутами.

---

## Остановка

```bash
sudo /usr/local/sbin/stop-tun2socks.sh
```

Скрипт:

1. возвращает default route на обычный gateway;
2. удаляет host route до SSH;
3. останавливает `tun2socks`;
4. останавливает `gost`;
5. останавливает все `ssh -D` процессы;
6. опускает `utun123`.

---

## Проверка

### Проверить маршруты

```bash
SSH_IP=203.0.113.10

route -n get "$SSH_IP" | egrep 'gateway|interface'
route -n get default | egrep 'gateway|interface'
route -n get 8.8.8.8 | egrep 'gateway|interface'
```

Ожидаемо:

```text
route to SSH_IP:
gateway: обычный роутер, например 192.168.1.1
interface: en0

route to default:
gateway: 198.18.0.1
interface: utun123
```

### Проверить внешний IP

```bash
curl https://ifconfig.me
```

Должен быть IP удалённого SSH-сервера.

### Проверить GOST

```bash
curl --socks5-hostname 127.0.0.1:1090 https://ifconfig.me
```

### Проверить отдельные SSH SOCKS

```bash
for p in {1080..1089}; do
  echo "port=$p"
  curl --connect-timeout 5 --socks5-hostname 127.0.0.1:$p https://ifconfig.me
  echo
 done
```

---

## Логи

Routeguard:

```bash
tail -f /var/log/tun2socks-routeguard.log
```

Launchd stdout/stderr:

```bash
tail -f /var/log/tun2socks-routeguard.out.log
 tail -f /var/log/tun2socks-routeguard.err.log
```

---

## Диагностика проблем

### 1. SSH route уходит в tun2socks

Плохо:

```text
gateway: 198.18.0.1
interface: utun123
```

Исправление:

```bash
REAL_GW=$(ipconfig getoption en0 router)
sudo route delete -host 203.0.113.10 2>/dev/null || true
sudo route add -host 203.0.113.10 "$REAL_GW"
```

### 2. GOST не стартует

Проверить, заняты ли порты:

```bash
lsof -nP -iTCP:1090 -sTCP:LISTEN
lsof -nP -iTCP:1080 -sTCP:LISTEN
```

Проверить версию:

```bash
gost -V
```

### 3. tun2socks не создаёт utun

Проверить:

```bash
ifconfig utun123
```

Если `resource busy`, поменяйте в конфиге:

```bash
TUN_IF="utun124"
```

### 4. После sleep/wake сломались маршруты

Проверить routeguard:

```bash
sudo launchctl print system/local.tun2socks.routeguard
 tail -f /var/log/tun2socks-routeguard.log
```

Вручную перезапустить:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/local.tun2socks.routeguard.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/local.tun2socks.routeguard.plist
```

---

## Удаление

Остановить туннель:

```bash
sudo /usr/local/sbin/stop-tun2socks.sh
```

Отключить routeguard:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/local.tun2socks.routeguard.plist 2>/dev/null || true
sudo launchctl disable system/local.tun2socks.routeguard 2>/dev/null || true
```

Удалить файлы:

```bash
sudo rm -f /Library/LaunchDaemons/local.tun2socks.routeguard.plist
sudo rm -f /usr/local/sbin/start-tun2socks.sh
sudo rm -f /usr/local/sbin/stop-tun2socks.sh
sudo rm -f /usr/local/sbin/tun2socks-routeguard.sh
sudo rm -f /usr/local/sbin/install-tun2socks-tools.sh
sudo rm -f /usr/local/etc/tun2socks.conf
sudo rm -rf /var/run/tun2socks-macos
```

---

## Безопасность

- Не указывайте пароль SSH в конфиге.
- Используйте SSH keys + `ssh-agent`.
- Для LaunchDaemon лучше использовать ключ без passphrase только в закрытой локальной среде; предпочтительнее `ssh-agent`, но root-daemon может не видеть пользовательский agent.
- `SSH_IP` лучше фиксировать как IP, иначе routeguard не сможет надёжно защитить маршрут при проблемах с DNS.
- `default route -> tun2socks` не гарантирует отсутствие DNS/WebRTC/IPv6-утечек. Проверяйте отдельно.
