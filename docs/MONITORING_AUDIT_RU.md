# Отчёт по анализу инструкции мониторинга

## Итоговая оценка

Ваша исходная схема `AWG/WireGuard -> exporter -> Prometheus -> Grafana` правильная. Основные проблемы были не в самой идее, а в аккуратности развёртывания на сервере, где уже есть рабочая Grafana/Prometheus:

1. Старый скрипт был рассчитан на один интерфейс `awg0`.
2. Старый скрипт мог перезаписать `/etc/prometheus/prometheus.yml` целиком.
3. Старый скрипт создавал Grafana provisioning с datasource `Prometheus`, `uid: prometheus`, `isDefault: true`, что могло повлиять на существующие dashboards.
4. Старый dashboard был шире, чем нужно сейчас.
5. Не было отдельной защиты от сброса traffic counters после reset/restart exporter-а или интерфейса.
6. Была потенциальная проблема прав: exporter запускается не от root, но для `wg show`/`awg show` требуются права. В новой версии это закрыто wrapper-ом `/usr/local/bin/wg` и sudoers-правилом для конкретных интерфейсов.

## Что изменено

### Multi-interface

Exporter запускается с несколькими `-i`:

```text
prometheus_wireguard_exporter ... -i awg0 -i awg1 -i awg800
```

Список интерфейсов берётся автоматически или задаётся через:

```bash
WG_IFACES="awg0 awg1 awg800"
```

### Не ломаем пользовательские dashboards

Dashboard создаётся в отдельной managed-папке и с отдельным UID:

```text
/var/lib/grafana/dashboards/awg-managed/awg-traffic-by-client-dashboard.json
uid: awg-traffic-by-client
```

Пользовательские dashboards в Grafana UI не удаляются и не перезаписываются.

### Не делаем наш datasource default

Создаётся datasource:

```text
AWG Prometheus / awg-prometheus
```

`isDefault: false`, чтобы не менять поведение существующих dashboards.

### Persistent traffic

Добавлен overlay-exporter, который хранит totals в:

```text
/var/lib/wgexporter/traffic_totals.json
```

Grafana использует именно persistent metrics:

```text
awg_persistent_received_bytes_total
awg_persistent_sent_bytes_total
```

### Проверка версий

Перед установкой `11_setup_monitoring.sh` показывает версии/наличие:

- OS;
- `awg`;
- `awg-quick`;
- `prometheus`;
- `grafana-server`;
- `rustc`;
- `cargo`;
- `prometheus_wireguard_exporter`;
- dpkg versions для `prometheus` и `grafana`.

### Backups

Перед изменением файлов создаётся backup в timestamp-папке:

```text
/etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-monitoring/
```

## Остаточные риски

1. Если в Grafana уже есть dashboard с UID `awg-traffic-by-client`, он будет обновлён provisioning-ом. UID выбран уникальным, но это всё равно нужно учитывать.
2. Если `/etc/prometheus/prometheus.yml` содержит нестандартные YAML-теги, `python3-yaml` может не обработать такой файл. Для обычной Prometheus-конфигурации это не проблема.
3. Если сервер использует нестандартную sudo `secure_path`, скрипт явно задаёт secure_path для пользователя `wgexporter`, но локальные политики sudoers всё равно могут это переопределить.
4. Применение nftables на production-сервере всегда нужно проверять осторожно. Скрипт делает backup runtime ruleset и `/etc/nftables.conf`, но если правила firewall очень нестандартные, можно запустить с `CONFIGURE_NFTABLES=no` и добавить правила вручную.
