# napiconfig-make-deb

Упаковка NaPi (бэкенд `napi-api` + фронтенд `napi-ui`) в один `.deb` `napiconfig` для arm64.

## Сборка

Нужен Docker. Хост arm64 собирает нативно.
Исходники (репозитории Igor Kha) кладутся рядом: `../napi-api`, `../napi-ui`,
или указываются через `API_SRC=` и `UI_SRC=`.

```bash
mkdir napiconfig && cd napiconfig
git clone https://gitlab.nnz-ipc.net/pub/napilinux/napi-api.git
git clone https://gitlab.nnz-ipc.net/pub/napilinux/napi-ui.git
git clone git@github.com:lab240/napiconfig-make-deb.git
cd napiconfig-make-deb
```

Собирается то, что сейчас извлечено в `../napi-api` и `../napi-ui` (ветка или тег).

```bash
./build.sh                       # → out/napiconfig_<api>+ui<ui>-<rev>_arm64.deb
SKIP_UI_BUILD=1 PKG_REV=2 ./build.sh   # без пересборки фронта
```

- Фронт собирается в `node:22-bookworm-slim` (`scripts/build-ui.sh`).
- Бэкенд собирается в `debian:bookworm` (`scripts/build-napiconfig.sh`) со своим Python:
  CPython 3.12 из [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
  (релиз и sha256 закреплены в скрипте). Пакет не зависит от Python системы и ставится на
  любой arm64 Debian/Ubuntu с glibc ≥ 2.36: bookworm, trixie, noble.
- Зависимости Python: `requirements.lock` с хешами. После изменения `../napi-api/pyproject.toml`:
  `./scripts/lock.sh`.

Размер: .deb ~26 МБ, на диске ~140 МБ (из них Python и библиотеки ~130 МБ).
Память napi-api такая же, как с системным Python (~120 МБ RSS сразу после старта).

## Установка на устройство

`napiconfig` зависит от `influxdb2` (репозиторий InfluxData) и `telegraf-light | telegraf`
(repo.napilab.ru). Оба репозитория подключаются до установки:

```bash
# InfluxData (ключ: отпечаток 24C975CBA61A024EE1B631787C3D57159FC2F927)
curl -fsSL https://repos.influxdata.com/influxdata-archive.key | gpg --dearmor > /etc/apt/keyrings/influxdata-archive.gpg
echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" \
    > /etc/apt/sources.list.d/influxdata.list
# NapiLab
curl -fsSL https://repo.napilab.ru/napilab.gpg | gpg --dearmor > /usr/share/keyrings/napilab.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/napilab.gpg] https://repo.napilab.ru stable main" \
    > /etc/apt/sources.list.d/napilab.list
apt update && apt install napiconfig        # или ./napiconfig_*_arm64.deb
```

Открой `https://<ip>/`. Вход по умолчанию: `admin` / `admin`, смени пароль.

Переход со старых пакетов `napi-api` + `napi-ui`: их postrm при purge удаляет
`/etc/napi-api`, `/var/lib/napi-api` и сертификат, а `napiconfig` использует те же пути.
Поэтому старые пакеты убираются без их postrm (так сделано на .54):

```bash
for p in napi-api napi-ui; do printf '#!/bin/sh\nexit 0\n' > /var/lib/dpkg/info/$p.postrm; done
dpkg --purge napi-api napi-ui && apt install ./napiconfig_*_arm64.deb
```

## Где что лежит

| Путь | Что |
|---|---|
| `/opt/napiconfig/app`, `/opt/napiconfig/python` | код napi-api и Python с библиотеками |
| `/usr/share/napiconfig/html` | собранный фронт |
| `/usr/lib/napiconfig/` | `netplan-takeover`, `influx-link` |
| `/etc/napi-api/napi-api.env` | конфиг (`app/.env` указывает сюда), не перезаписывается |
| `/var/lib/napi-api/db` | база SQLite (только root) |
| `/var/lib/napi-api/sensor_configs` | конфиги датчиков; telegraf читает их по symlink из `/etc/telegraf/telegraf.d` |
| `/etc/nginx/sites-available/napi.conf` | сайт: HTTPS, `/api` и `/tty/` (conffile) |
| `/etc/nginx/napi.d/*.conf` | дополнительные location; `00-http2.conf` пишет postinst, если nginx ≥ 1.25.1 |
| `/etc/nginx/cert.pem`, `key.pem` | самоподписанный сертификат устройства |
| `/etc/nginx/ttyd_tokens.map` | токены веб-терминала |

Службы: `napi-api`, `napi-cert` (первый запуск), `napi-ttyd` (если есть `/usr/bin/ttyd`),
`napi-influx-link` (токены InfluxDB, каждая загрузка).

Проверки в systemd-контейнере: `scripts/test-install.sh noble`, `scripts/test-influx.sh noble`,
`scripts/test-netplan.sh noble networkd|nm`.

## Сборка образа Armbian

Пакет можно ставить в chroot при сборке образа (оба репозитория подключить заранее).
В образах Armbian `APT::Install-Recommends "0"`, поэтому всё нужное — в Depends.
В chroot postinst только включает службы и не создаёт секретов.
Сертификат, токены терминала и токены InfluxDB создаются на первой загрузке, у каждого устройства свои.

## Сеть

napi-api пишет netplan-файл `/etc/netplan/01-network.yaml` (только интерфейсы, заданные
в веб-интерфейсе) и вызывает `netplan apply`. Чтобы у интерфейса был один владелец:

- `NETWORK_RENDERER` в `/etc/napi-api/napi-api.env` выбирается при установке по стеку образа:
  `NetworkManager`, если NM установлен и включён, иначе `networkd`
  (`BUILD_MINIMAL=yes` в Armbian, например NAPI-C).
- На стеке networkd Armbian кладёт `10-dhcp-all-interfaces.yaml` (шаблоны `e*`, `lan*`, `wan*` → DHCP).
  networkd берёт первый подходящий `.network` по алфавиту, и шаблон `all-eth-interfaces`
  перекрыл бы `eth0` из веб-интерфейса. Поэтому postinst (`/usr/lib/napiconfig/netplan-takeover`)
  переносит этот файл в `/var/lib/napi-api/netplan-backup/` и кладёт `90-napi-fallback.yaml`
  с теми же шаблонами, но с именами `zz-*`. Интерфейсы без настроек по-прежнему получают DHCP,
  настроенные в веб-интерфейсе идут первыми.
- На стеке NetworkManager у Armbian нет шаблонов (`00-default-use-network-manager.yaml`),
  napi-api создаёт профиль `netplan-<iface>`, ничего не переносится.
- `purge` возвращает файл Armbian и убирает `90-napi-fallback.yaml`.
  `01-network.yaml` остаётся: это сетевые настройки устройства.

Проверка: `./scripts/test-netplan.sh <trixie|noble> <networkd|nm>`.

Пока нет отката: ошибка в адресе отрезает доступ к устройству, а `netplan apply`
перезапускает всю сеть. Подтверждение с автооткатом (как в napi-switchd) требует
изменений в napi-api и UI.

## Telegraf и InfluxDB

Датчики пишет telegraf в InfluxDB 2, napi-api читает оттуда графики.

- **telegraf-light** из repo.napilab.ru: telegraf только с нужными плагинами
  (22 МБ вместо 300, RSS ~20 МБ вместо ~140). Сборка и пакет:
  [lab240/telegraf-ligth](https://github.com/lab240/telegraf-ligth).
  napiconfig зависит от `telegraf-light | telegraf`.
- **influxdb2** из репозитория InfluxData (тоже в Depends; `influxdb2-cli` по желанию).

Связку по токенам делает `/usr/lib/napiconfig/influx-link` (служба `napi-influx-link.service`,
каждая загрузка, до telegraf; и postinst napiconfig):

- на чистой InfluxDB: начальная настройка, пользователь `admin` со случайным паролем,
  org `napi`, bucket `sensors` (30 дней); пароль и операторский токен в
  `/root/influxdb-credentials` (600), конфиг `influx` CLI в `/root/.influxdbv2/configs`;
- telegraf: токен только на запись в `sensors`, `INFLUX_TOKEN` в `/etc/default/telegraf`
  (640 root:telegraf);
- napi-api: токен только на чтение `sensors`, `INFLUXDB_*` в `/etc/napi-api/napi-api.env`;
- токен проверяется запросом с ним самим; нет или отклонён — создаётся новый, служба
  перезапускается. Повторный запуск ничего не меняет.

Токены создаются на устройстве (в chroot служба только включается), в образе их нет.
Если InfluxDB настроили вручную и операторского токена в `/root/influxdb-credentials` нет,
связка ничего не трогает.

`purge` napiconfig не трогает данные InfluxDB и `/root/influxdb-credentials`.

Проверка: `./scripts/test-influx.sh noble` (napiconfig из `out/`, influxdb2 и telegraf-light
из репозиториев; права токенов, данные через API, повторный запуск, потеря токена,
загрузка).

## Отличия от NapiLinux

- nginx штатный из Debian/Ubuntu вместо собственной сборки; стандартный сайт `default` отключается.
- Модуль `napi_upgrade` (SWUpdate) включается только на NapiLinux, на Armbian он скрыт автоматически.
- «Сброс к заводским» вызывает `fw_setenv resetroot yes`; на Armbian нужен `u-boot-tools` и логика в загрузчике.
- Сертификат RSA 2048 вместо 4096: быстрее на слабых CPU.
