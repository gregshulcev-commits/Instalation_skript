# Обновление 2026-04-25: удаление по номеру, startup backup, monitoring all-mode

## 1. Удаление клиента теперь удобнее и безопаснее

В management-меню при выборе пункта `Удалить клиента из интерфейса` скрипт теперь:

1. показывает список интерфейсов по номерам;
2. после выбора интерфейса показывает список клиентов этого интерфейса по номерам;
3. удаляет выбранный peer по `PublicKey`, а не только по `friendly_name`.

Это важно, потому что одинаковые `friendly_name` могут встречаться на разных интерфейсах. Скрипт не меняет имена клиентов и не пытается делать их уникальными автоматически.

Пример интерактивного запуска:

```bash
sudo ./install.sh
# 7) Удалить клиента из интерфейса
```

Прямой запуск:

```bash
sudo ./scripts/08_remove_client.sh --interactive
sudo ./scripts/08_remove_client.sh --interactive awg800
```

Старый режим по имени оставлен для совместимости:

```bash
sudo ./scripts/08_remove_client.sh Officer awg800
```

Но рекомендуемый режим — выбор по номеру.

## 2. Исправлена ошибка с отсутствующим manager-<iface>.env

Раньше удаление могло завершиться ошибкой вида:

```text
[x] Не найден файл настроек интерфейса: /etc/amnezia/amneziawg/manager-awg0.env
```

Теперь, если `manager-awg0.env`, `manager-awg1.env` или другой per-interface env отсутствует, но есть `/etc/amnezia/amneziawg/<iface>.conf`, скрипт использует безопасный fallback:

```text
SERVER_CONF=/etc/amnezia/amneziawg/<iface>.conf
CLIENTS_DIR=/etc/amnezia/amneziawg/clients        # для awg0 legacy layout
CLIENTS_DIR=/etc/amnezia/amneziawg/<iface>/clients # для awg1/awg800...
KEYS_DIR=...
SERVICE_NAME=awg-quick@<iface>.service
```

Это позволяет удалять клиентов и интерфейсы на старых установках, где per-interface env ещё не был создан.

## 3. Каждый запуск management/install делает full backup

При запуске `install.sh` / `scripts/00_manage.sh` теперь всегда создаётся полный backup инфраструктуры до любого действия пользователя:

```text
/etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-script-start-management/
```

В backup попадают найденные AWG configs/env/clients/keys, nftables, monitoring configs, Prometheus/Grafana provisioning и systemd units. Папка `/etc/amnezia/amneziawg/backups` намеренно исключается из копирования, чтобы не создавать рекурсивные backup-и.

Для прямого запуска отдельных критичных скриптов также добавлен startup backup:

```bash
sudo ./scripts/08_remove_client.sh --interactive
sudo ./scripts/09_remove_interface.sh awg1
sudo ./scripts/11_setup_monitoring.sh
```

Экстренный режим для тестов/разработки:

```bash
sudo AWG_DISABLE_STARTUP_BACKUP=yes ./install.sh --status
```

По умолчанию backup всегда включён.

## 4. Monitoring exporter: all-mode по умолчанию

`11_setup_monitoring.sh` теперь по умолчанию запускает `prometheus_wireguard_exporter` без `-i`, чтобы exporter использовал `wg show all dump`.

Для AmneziaWG создан wrapper `/usr/local/bin/wg`, который поддерживает:

```bash
wg show interfaces
wg show all dump
wg show awg0 dump
wg show awg1 dump
wg show awg800 dump
```

`wg show all dump` строится из выбранных интерфейсов `WG_IFACES` и добавляет имя интерфейса первым столбцом, как ожидает WireGuard exporter.

Sudoers теперь разрешает exporter-пользователю:

```text
/usr/local/bin/wg show all dump
/usr/local/bin/wg show <iface> dump
```

Если на конкретной версии exporter нужен старый явный режим, можно включить:

```bash
sudo EXPORTER_INTERFACE_MODE=explicit WG_IFACES="awg0 awg1 awg800" ./install.sh --monitoring
```

Но штатный режим теперь:

```bash
sudo WG_IFACES="awg0 awg1 awg800" ./install.sh --monitoring
```

без `-i` в systemd `ExecStart`.

## 5. Что проверено тестами

Добавлены тесты:

- `00_manage.sh --status` создаёт startup full backup;
- `08_remove_client.sh --interactive` удаляет клиента, выбранного по номеру;
- удаление клиента работает даже без `manager-<iface>.env`;
- monitoring installer содержит `wg show all dump` all-mode;
- существующие тесты add/remove/restore/nftables/monitoring продолжают проходить.
