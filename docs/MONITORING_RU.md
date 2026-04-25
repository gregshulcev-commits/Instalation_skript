# Мониторинг AmneziaWG клиентов через Prometheus + Grafana

## Что добавлено

В основной bundle добавлен отдельный модуль мониторинга:

- `scripts/11_setup_monitoring.sh` — развёртывание/обновление мониторинга;
- `monitoring/src/awg_exporter_sync_peers.py` — создаёт безопасный файл peer metadata без `PrivateKey` и `PresharedKey`;
- `monitoring/src/awg_persistent_traffic_exporter.py` — сохраняет суммарные счётчики трафика на диск;
- `monitoring/src/check_awg_monitoring.sh` — диагностика прав, сервисов и endpoint-ов;
- `monitoring/grafana/awg-traffic-by-client-dashboard.json` — один dashboard: bar diagram общего трафика по `friendly_name` для всех интерфейсов.

Скрипты установки и настройки AWG-интерфейсов (`01`-`10`) не менялись. Изменён только management-скрипт `00_manage.sh`, чтобы из общего меню можно было запустить мониторинг.

## Безопасность существующей Grafana

Новая версия не должна ломать пользовательские dashboards.

Что делает скрипт:

1. Не удаляет пользовательские dashboards.
2. Не пишет dashboard в общий каталог `/var/lib/grafana/dashboards`.
3. Создаёт отдельную managed-папку:

   ```text
   /var/lib/grafana/dashboards/awg-managed
   ```

4. Создаёт отдельный provisioning-файл:

   ```text
   /etc/grafana/provisioning/dashboards/awg-monitoring.yml
   ```

5. Использует отдельный dashboard UID:

   ```text
   awg-traffic-by-client
   ```

6. В provider выставлено:

   ```yaml
   disableDeletion: true
   allowUiUpdates: true
   ```

Это означает, что удаление provisioning-файла не должно автоматически удалить dashboard из базы Grafana. При этом сам dashboard остаётся managed: если позднее обновить JSON-файл с тем же UID, Grafana обновит именно этот dashboard.

## Datasource

Скрипт создаёт отдельный datasource:

```text
Name: AWG Prometheus
UID:  awg-prometheus
URL:  http://127.0.0.1:9090
```

Он не назначается datasource по умолчанию:

```yaml
isDefault: false
```

Это сделано специально, чтобы не ломать существующие панели и dashboards пользователя, которые уже используют свой Prometheus datasource.

## Prometheus

Скрипт больше не перезаписывает `/etc/prometheus/prometheus.yml` целиком простым heredoc. Он читает существующий YAML, удаляет старые AWG-managed jobs и добавляет только два scrape job:

```yaml
- job_name: awg_wgexporter_raw
  static_configs:
    - targets: ['127.0.0.1:9586']

- job_name: awg_persistent_traffic
  static_configs:
    - targets: ['127.0.0.1:9587']
```

Перед изменением создаётся backup в папке времени:

```text
/etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-monitoring/
```

Если установлен `promtool`, новый config проверяется командой:

```bash
promtool check config /tmp/prometheus.yml.*
```

## Все интерфейсы

По умолчанию интерфейсы определяются автоматически из:

```text
/etc/amnezia/amneziawg/*.conf
```

и проверяются через:

```bash
awg show <iface> dump
```

Запуск:

```bash
sudo ./install.sh --monitoring
```

или через меню:

```bash
sudo ./install.sh
# пункт 10
```

Явно указать интерфейсы:

```bash
sudo WG_IFACES="awg0 awg1 awg800" ./install.sh --monitoring
```

## Persistent traffic counters

Обычные счётчики `wireguard_received_bytes_total` и `wireguard_sent_bytes_total` берутся из текущих counters интерфейса. После перезапуска интерфейса или exporter-а они могут сбрасываться.

Для постоянной суммы добавлен сервис:

```text
awg-persistent-traffic.service
```

Он читает raw metrics с:

```text
http://127.0.0.1:9586/metrics
```

и публикует persistent metrics на:

```text
http://127.0.0.1:9587/metrics
```

Файл состояния:

```text
/var/lib/wgexporter/traffic_totals.json
```

Новые метрики:

```text
awg_persistent_received_bytes_total
awg_persistent_sent_bytes_total
```

Логика:

- если raw counter вырос, добавляется разница;
- если raw counter уменьшился, считается, что был reset, и добавляется новое значение после reset;
- если persistent exporter перезапустился, сумма читается из JSON-файла и продолжается.

## Dashboard

Создаётся только один dashboard:

```text
Folder: AmneziaWG
Title:  AWG traffic by client
UID:    awg-traffic-by-client
```

Внутри одна bar gauge panel:

```promql
sum by (friendly_name) (awg_persistent_received_bytes_total)
+
sum by (friendly_name) (awg_persistent_sent_bytes_total)
```

Она показывает суммарный RX+TX трафик по каждому `friendly_name` сразу по всем интерфейсам.

## Права доступа

Exporter запускается от отдельного пользователя:

```text
wgexporter
```

Для него создаётся ограниченное sudoers-правило только на команды вида:

```text
/usr/local/bin/wg show awg0 dump
/usr/local/bin/wg show awg1 dump
...
```

Wrapper `/usr/local/bin/wg` вызывает `awg show <iface> dump` и отдаёт exporter-у WireGuard-compatible dump. `/usr/bin/wg` не перезаписывается.

## Диагностика

После установки:

```bash
sudo /usr/local/sbin/check-awg-monitoring
```

Ручные проверки:

```bash
systemctl status wgexporter --no-pager
systemctl status awg-persistent-traffic --no-pager
systemctl status prometheus --no-pager
systemctl status grafana-server --no-pager
curl -fsS http://127.0.0.1:9586/metrics | head
curl -fsS http://127.0.0.1:9587/metrics | head
curl -fsS http://127.0.0.1:9090/-/healthy
```

## Если Grafana уже была установлена

По умолчанию скрипт не правит существующий `/etc/grafana/grafana.ini`, если Grafana уже установлена. Он только добавляет datasource/dashboard provisioning.

Чтобы явно разрешить правку `grafana.ini`:

```bash
sudo MANAGE_EXISTING_GRAFANA_INI=yes ./install.sh --monitoring
```

Чтобы вообще не трогать Grafana:

```bash
sudo INSTALL_GRAFANA=no ./install.sh --monitoring
```

Чтобы не править nftables:

```bash
sudo CONFIGURE_NFTABLES=no ./install.sh --monitoring
```

## Дополнение: all-mode wrapper для нескольких интерфейсов

Начиная с обновления 2026-04-25 monitoring installer по умолчанию не передаёт exporter-у список интерфейсов через повторяющиеся `-i`. Вместо этого используется режим `wg show all dump` через wrapper `/usr/local/bin/wg`.

Wrapper читает `/etc/wgexporter/monitoring.env`, берёт `WG_IFACES` и для каждого интерфейса вызывает `awg show <iface> dump`, добавляя имя интерфейса первым столбцом. Это делает multi-interface сбор метрик стабильнее для AmneziaWG.

Рекомендуемый запуск:

```bash
sudo WG_IFACES="awg0 awg1 awg800" ./install.sh --monitoring
```

Аварийный явный режим, если он нужен для конкретной сборки exporter:

```bash
sudo EXPORTER_INTERFACE_MODE=explicit WG_IFACES="awg0 awg1 awg800" ./install.sh --monitoring
```
