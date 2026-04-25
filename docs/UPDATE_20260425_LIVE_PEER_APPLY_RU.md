# Обновление: live-применение add/remove client без полного restart awg-quick

## Причина изменения

На рабочем сервере удаление клиента дошло до изменения `server.conf`, но затем полный restart сервиса упал:

```text
Job for awg-quick@awg0.service failed because the control process exited with error code.
[!] Не удалось перезапустить awg-quick@awg0.service.
[!] Операция прервана/завершилась ошибкой. Выполняю откат созданных файлов.
```

Это означает, что выбранный клиент был найден правильно, но способ применения изменений был слишком тяжёлым: полный `systemctl restart awg-quick@awg0.service` заново прогоняет весь `awg-quick up/down` и может упасть из-за старой unrelated-проблемы в конфиге, маршрутах, IPv6/MTU, nftables hooks или состоянии интерфейса.

## Новое поведение по умолчанию

`04_add_client.sh` и `08_remove_client.sh` теперь по умолчанию используют:

```bash
CLIENT_APPLY_MODE=live
```

Добавление peer применяется так:

```bash
awg set <iface> peer <PublicKey> preshared-key <tmpfile> allowed-ips <AllowedIPs>
```

Удаление peer применяется так:

```bash
awg set <iface> peer <PublicKey> remove
```

Полный `restart awg-quick@<iface>.service` по умолчанию больше не выполняется при добавлении/удалении клиента.

## Почему это безопаснее

1. Не роняет весь интерфейс ради одного peer.
2. Не зависит от того, сможет ли `awg-quick` заново поднять старые IPv6 routes.
3. Не отключает остальных клиентов во время операции.
4. Всё равно сохраняет disk-state в `/etc/amnezia/amneziawg/<iface>.conf`.
5. При следующем плановом restart интерфейса состояние будет соответствовать server.conf.

## Режимы применения

```bash
# default
sudo CLIENT_APPLY_MODE=live ./scripts/08_remove_client.sh --interactive

# старое поведение: полный restart awg-quick@iface
sudo CLIENT_APPLY_MODE=restart ./scripts/08_remove_client.sh --interactive

# только изменить файлы, не трогая live-интерфейс
sudo CLIENT_APPLY_MODE=none ./scripts/08_remove_client.sh --interactive
```

Те же режимы поддерживаются в `04_add_client.sh`.

## Monitoring/Grafana после add/remove

После успешного add/remove скрипты best-effort перезапускают:

```text
wgexporter
awg-persistent-traffic
```

Это нужно, чтобы:

- `/etc/wgexporter/peers.conf` пересобрался из актуальных server configs;
- raw exporter быстрее увидел нового/удалённого peer;
- persistent exporter быстрее обновил `/metrics`;
- Grafana dashboard обновился на следующем scrape Prometheus.

При удалении клиента persistent-state дополнительно чистится по `interface + PublicKey`:

```text
/var/lib/wgexporter/traffic_totals.json
```

Так удалённый клиент не должен оставаться в bar diagram только из-за старого накопленного счётчика.

## Backup и rollback

Backup перед операцией сохранён:

```text
/etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-remove-client-<iface>-<name>/
```

Если live-команда `awg set ...` не удалась, скрипт откатывает файловые изменения из operation backup. Если monitoring-сервисы не перезапустились, AWG-операция не откатывается: мониторинг считается вспомогательным best-effort слоем.

## Что проверено тестами

- add client больше не вызывает `systemctl restart awg-quick@<iface>.service` по умолчанию;
- remove client больше не вызывает `systemctl restart awg-quick@<iface>.service` по умолчанию;
- после add/remove выполняется best-effort restart `wgexporter`;
- remove client по номеру продолжает работать без `manager-<iface>.env`;
- restore backup возвращает удалённого клиента.
