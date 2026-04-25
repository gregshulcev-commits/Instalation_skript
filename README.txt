AmneziaWG bash bundle
=====================

Назначение
----------
Этот набор bash-скриптов устанавливает и обслуживает сервер AmneziaWG из исходников, создаёт несколько AWG-интерфейсов на одном сервере, добавляет/удаляет клиентов, пересобирает nftables/NAT и умеет откатывать изменения из timestamp-backup.

Главный входной скрипт:

  sudo ./install.sh

или напрямую:

  sudo ./scripts/00_manage.sh

Что исправлено в этой сборке
----------------------------
1. Исправлена практическая причина сбоя вида:

     awg-quick up awg800
     ...
     ip -6 route add fd42:42:44::2/128 dev awg800
     RTNETLINK answers: No such device

   В старой логике клиентский IPv6 /128 попадал в server.conf автоматически. Из-за этого awg-quick пытался добавить IPv6-маршрут к peer. Теперь новый клиент по умолчанию IPv4-only:

     server.conf: AllowedIPs = 10.8.X.Y/32
     client.conf: AllowedIPs = 0.0.0.0/0

   IPv6 /128 добавляется в server.conf только при явном CLIENT_ENABLE_IPV6=yes. Если IPv6 включён, MTU ниже 1280 запрещён/блокируется как небезопасный вариант.

2. nftables больше не дописывается бесконечными дублями. Скрипт строит итоговый candidate, сохраняет backup и перезаписывает /etc/nftables.conf. Итоговый файл начинается с `flush ruleset`, чтобы `nft -f /etc/nftables.conf` заменял runtime ruleset, а не наслаивал старые правила.

3. install.env, manager.env и firewall.env теперь перезаписываются атомарно с backup, а не дописываются блоками. sysctl остаётся append-safe: старые строки не редактируются, новое значение добавляется в конец.

4. Добавлены timestamp-backup и restore:

     /etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-label/
       INFO
       MANIFEST.tsv
       CREATED_PATHS        # если операция создавала новые файлы
       files/...

   Откат:

     sudo ./scripts/10_restore_backup.sh /etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-label

5. Добавлены новые операции:

     sudo ./scripts/08_remove_client.sh <client_name> [iface]
     sudo ./scripts/09_remove_interface.sh [iface]
     sudo ./scripts/10_restore_backup.sh [backup_dir]

6. Улучшены подсказки интерфейса:
   - подсказки по Jc/Jmin/Jmax/S1/S2/H1-H4;
   - следующий свободный IPv4 default: 10.8.1.1/24, затем 10.8.2.1/24, ...;
   - следующий IPv6 ULA default: fd42:42:42::1/64, затем fd42:42:43::1/64, ...;
   - endpoint host по умолчанию берётся из системного IPv4 source address.

Быстрый старт
-------------

  unzip amneziawg_bash_bundle_FIXED_20260425.zip
  cd amneziawg_bash_bundle_GIT
  sudo ./install.sh

Дальше используйте меню:

  1) Показать состояние
  2) Установить/переустановить AmneziaWG из исходников
  3) Создать новый интерфейс AWG
  4) Добавить клиента в существующий интерфейс
  5) Пересобрать nftables/NAT для всех интерфейсов
  6) Обновить/восстановить AWG и перезапустить интерфейсы
  7) Удалить клиента из интерфейса
  8) Удалить интерфейс AWG
  9) Восстановить состояние из backup
  0) Выход

Создание интерфейса
-------------------
Через меню выберите пункт 3 или запустите напрямую:

  sudo ./scripts/02_create_server_config.sh

Скрипт спросит:
- имя интерфейса, например awg0/awg1;
- UDP ListenPort;
- IPv4 адрес сервера в туннеле, строго /24;
- включать ли IPv6 на серверном интерфейсе;
- IPv6 ULA /64, если IPv6 включён;
- публичный endpoint host для клиентов;
- DNS для клиентов;
- MTU сервера и MTU клиента по умолчанию;
- obfuscation параметры Jc/Jmin/Jmax/S1/S2/H1-H4.

Если IPv6 включён, server MTU ниже 1280 не принимается. Это сделано специально, потому что IPv6 требует минимальный MTU 1280.

Добавление клиента
------------------

  sudo ./scripts/04_add_client.sh phone awg0

По умолчанию клиент IPv4-only:

  [Interface]
  Address = 10.8.1.2/32
  # Address = fd42:42:42::2/128
  AllowedIPs = 0.0.0.0/0

  server.conf peer:
  AllowedIPs = 10.8.1.2/32

Это безопасный режим, который не заставляет awg-quick добавлять IPv6 /128 route.

Явное включение IPv6 для клиента:

  sudo CLIENT_ENABLE_IPV6=yes CLIENT_MTU=1280 ./scripts/04_add_client.sh phone6 awg0

Тогда будет:

  client.conf:
  Address = 10.8.1.3/32
  Address = fd42:42:42::3/128
  AllowedIPs = 0.0.0.0/0, ::/0

  server.conf peer:
  AllowedIPs = 10.8.1.3/32, fd42:42:42::3/128

Удаление клиента
----------------

  sudo ./scripts/08_remove_client.sh phone awg0

Что делает:
- создаёт backup server.conf и client.conf;
- удаляет peer block с `# friendly_name=phone` или legacy `### Client phone`;
- удаляет файл clients/phone.conf;
- перезапускает только awg-quick@awg0.service;
- при ошибке restart по умолчанию откатывает изменения.

Удаление интерфейса
-------------------

  sudo CONFIRM_REMOVE=yes ./scripts/09_remove_interface.sh awg1

Что делает:
- останавливает/отключает awg-quick@awg1.service;
- удаляет awg1.conf, manager-awg1.env, clients/keys папки интерфейса;
- переключает manager.env на оставшийся интерфейс;
- пересобирает nftables, удаляя UDP allow и masquerade удалённого интерфейса;
- сохраняет всё в одну backup-папку.

Откат из backup
---------------

Интерактивно:

  sudo ./scripts/10_restore_backup.sh

Или явно:

  sudo RESTORE_CONFIRM=yes RESTORE_APPLY_NFT=yes RESTORE_RESTART_SERVICES=yes \
    ./scripts/10_restore_backup.sh /etc/amnezia/amneziawg/backups/20260425-120000-remove-interface-awg1

Перед restore текущие файлы ещё раз сохраняются в pre-restore backup, чтобы можно было откатить сам restore.

nftables
--------

  sudo ./scripts/03_setup_nftables.sh

Скрипт сканирует все:

  /etc/amnezia/amneziawg/*.conf

и формирует единые правила:

  iifname "ens3" udp dport { 56789, 520 } accept
  iifname { "awg0", "awg1" } oifname "ens3" masquerade

Если в существующем firewall есть пользовательские правила, например:

  iifname "ens3" udp dport { 53, 443 } accept
  udp dport { 53, 443 } redirect to :56789
  iifname "awg0" tcp dport 3000 accept

они сохраняются при понятной структуре `table inet filter` + `table inet nat`. Старые AWG-дубли и старая `table ip amneziawg_bundle` удаляются из candidate.

Проверка состояния
------------------

  sudo ./scripts/00_manage.sh --status

В статусе показываются:
- пути к awg/awg-quick;
- наличие install.env, firewall.env, nftables.conf;
- список интерфейсов;
- IPv4/IPv6 Address, ListenPort, server/client MTU;
- SERVER_ENABLE_IPV6;
- количество peer/routes и client.conf файлов;
- предупреждение, если в server.conf есть IPv6 при MTU ниже 1280;
- состояние awg-quick@<iface>.service.

Тесты
-----
Автотесты запускаются так:

  ./tests/run_tests.sh

В этой сборке проверяется:
- bash -n всех скриптов;
- установка через fake sources;
- создание awg0 и awg1;
- выбор следующих подсетей;
- nftables template и обновление существующего native firewall без дублей;
- добавление IPv4-only клиента по умолчанию;
- явное добавление IPv6-клиента;
- update с backup install.env;
- status мастера;
- удаление клиента и restore из backup;
- удаление интерфейса, очистка nftables и restore из backup.

Ограничения
-----------
- Автовыдача IPv4 рассчитана на /24.
- Реальная DKMS-сборка зависит от ядра VPS, headers, Secure Boot и systemd. В контейнере проверяются только безопасные dry-run сценарии с заглушками.
- Если nftables.conf имеет нестандартную структуру, скрипт остановится и напечатает ручные инструкции вместо рискованного изменения.

====================================================================
Monitoring add-on, 2026-04-25
====================================================================

В bundle добавлен безопасный multi-interface мониторинг Prometheus/Grafana.

Основной запуск:

  sudo ./install.sh --monitoring

Через меню:

  sudo ./install.sh
  пункт 10 - развернуть/обновить мониторинг
  пункт 11 - показать состояние мониторинга

Документация:

  docs/MONITORING_RU.md
  docs/MONITORING_AUDIT_RU.md

Существующие AWG install/config/client scripts не менялись. Добавлен новый
скрипт scripts/11_setup_monitoring.sh и пункт меню в scripts/00_manage.sh.

Главное поведение:

- мониторинг всех интерфейсов AWG;
- отдельный Grafana datasource AWG Prometheus, isDefault=false;
- отдельный dashboard UID awg-traffic-by-client;
- пользовательские dashboards не удаляются;
- persistent traffic totals хранятся в /var/lib/wgexporter/traffic_totals.json;
- /usr/bin/wg не перезаписывается, wrapper ставится в /usr/local/bin/wg.
