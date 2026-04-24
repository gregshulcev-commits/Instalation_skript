AmneziaWG bash bundle
=====================

Назначение
----------
Этот bundle устанавливает и обслуживает сервер AmneziaWG из исходников. Он рассчитан на два сценария:

1. Первый запуск на чистом сервере.
2. Добавление второго и последующих AWG-интерфейсов на тот же сервер без поломки уже работающих интерфейсов.

Главный входной скрипт
----------------------
Запускайте один скрипт из корня распакованного архива:

  sudo ./install.sh

Или напрямую:

  sudo ./scripts/00_manage.sh

00_manage.sh сам сканирует состояние сервера и показывает:
- найден ли awg;
- найден ли awg-quick;
- есть ли install.env;
- есть ли sysctl-файл с ip_forward;
- есть ли nftables.conf;
- какие /etc/amnezia/amneziawg/*.conf уже существуют;
- какие ListenPort, Address, server MTU и client MTU у каждого интерфейса;
- сколько клиентов найдено в server.conf и в папке клиентских конфигов;
- состояние systemd service awg-quick@<iface>.service.

После сканирования скрипт предлагает логичное действие:
- если awg/awg-quick не найдены — установить AmneziaWG из исходников;
- если установка есть, но интерфейсов нет — создать первый интерфейс;
- если интерфейсы уже есть — добавить клиента, добавить новый интерфейс, пересобрать firewall/NAT или обновить AWG.

Защита от перезаписи старых данных
----------------------------------
Исправленная версия придерживается append/create-only политики для bundle-данных:
- существующие interface/server/client .conf не перезаписываются;
- install.env, manager.env, firewall.env и sysctl дополняются, старые строки остаются как были;
- /etc/nftables.conf не заменяется целиком и не получает глобальный flush ruleset;
- source/cache/DKMS пути создаются заново, старые каталоги не удаляются;
- awg-tools при реальной сборке ставятся в новый отдельный каталог TOOLS_INSTALL_ROOT, а не поверх старых awg/awg-quick бинарников.

Быстрый старт с нуля
--------------------

  tar -xzf amneziawg_bash_bundle_fixed.tar.gz
  cd amneziawg_bundle
  sudo ./install.sh

Во время создания интерфейса можно задать:
- имя интерфейса, например awg0;
- UDP ListenPort, например 56789 или 443;
- внутренний IPv4 адрес сервера, например 10.8.1.1/24;
- внутренний IPv6 ULA адрес, например fd42:42:42::1/64;
- публичный endpoint host для клиентов;
- DNS для клиентов;
- MTU сервера;
- MTU клиента по умолчанию;
- AWG obfuscation параметры: Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4.

Рекомендуемый безопасный старт для проблемных мобильных сетей:

  server MTU: 1280
  client MTU: 1280

Если требуется проверить гипотезу с меньшим MTU, можно задать, например, client MTU 1200. Но помните: MTU ниже 1280 может конфликтовать с IPv6, поэтому для IPv4-only теста это допустимо, а для IPv6 лучше начинать с 1280.

Добавление второго интерфейса
-----------------------------
Запустите тот же самый главный скрипт:

  sudo ./install.sh

Дальше выберите:

  3) Создать новый интерфейс AWG

Скрипт сам предложит следующее свободное имя awgN. Например, если awg0 уже есть, будет предложено awg1.

Для второго интерфейса обязательно задайте отдельные подсети, например:

  awg0: 10.8.1.1/24 и fd42:42:42::1/64
  awg1: 10.8.2.1/24 и fd42:42:43::1/64

После создания нового интерфейса скрипт предложит дополнить nftables/NAT для всех интерфейсов. Это важно: firewall-файл должен учитывать все ListenPort и все AWG interface names одновременно. Старые строки nftables.conf при этом не переписываются: новые элементы добавляются в конец файла.

Добавление клиента
------------------
Через главный скрипт:

  sudo ./install.sh

Выберите:

  4) Добавить клиента в существующий интерфейс

Если интерфейсов несколько, скрипт покажет список и спросит, куда добавить клиента.

Ручной запуск тоже поддерживается:

  sudo ./scripts/04_add_client.sh phone awg0
  sudo ./scripts/04_add_client.sh phone2 awg1

При добавлении клиента скрипт:
- берёт параметры из manager-<iface>.env;
- выбирает следующий свободный IPv4 в /24 подсети интерфейса;
- спрашивает MTU клиента или использует DEFAULT_CLIENT_MTU;
- генерирует ключи клиента и PresharedKey;
- создаёт client.conf;
- добавляет peer в правильный server.conf;
- перезапускает только нужный awg-quick@<iface>.service.

IPv6 для клиентов
-----------------
По умолчанию клиент создаётся в IPv4-only режиме:

  Address = 10.8.X.Y/32
  # Address = fd42:...::Y/128
  AllowedIPs = 0.0.0.0/0

Это сделано безопаснее, потому что nftables в bundle настраивает только IPv4 NAT, а у многих серверов нет рабочего внешнего IPv6.

Если вы сознательно хотите включить IPv6 в клиентском конфиге:

  sudo CLIENT_ENABLE_IPV6=yes ./scripts/04_add_client.sh phone awg0

Тогда будет создано:

  Address = 10.8.X.Y/32
  Address = fd42:...::Y/128
  AllowedIPs = 0.0.0.0/0, ::/0

Перед включением IPv6 убедитесь, что понимаете маршрутизацию и firewall для IPv6.

Файлы состояния
---------------
Основные файлы:

  /etc/amnezia/amneziawg/install.env
      Пути к awg, awg-quick, кешу исходников и sysctl-файлу. При повторной установке новые значения дописываются в конец, старые строки не меняются.

  /etc/amnezia/amneziawg/firewall.env
      Внешний интерфейс и SSH-порт, использованные при последней генерации nftables. Новые значения дописываются append-only.

  /etc/amnezia/amneziawg/manager.env
      Указатель на последний созданный/настроенный интерфейс. Оставлен для совместимости. Обновляется append-only: shell source берёт последние значения.

  /etc/amnezia/amneziawg/manager-awg0.env
  /etc/amnezia/amneziawg/manager-awg1.env
      Индивидуальные настройки каждого интерфейса.

  /etc/amnezia/amneziawg/awg0.conf
  /etc/amnezia/amneziawg/awg1.conf
      Серверные конфиги интерфейсов.

  /etc/amnezia/amneziawg/keys/
  /etc/amnezia/amneziawg/clients/
      Ключи и клиенты для awg0 в совместимом layout.

  /etc/amnezia/amneziawg/awg1/keys/
  /etc/amnezia/amneziawg/awg1/clients/
      Ключи и клиенты для второго и последующих интерфейсов.

Почему awg0 хранится иначе
--------------------------
Для совместимости с предыдущими single-interface установками awg0 использует старые папки:

  /etc/amnezia/amneziawg/keys
  /etc/amnezia/amneziawg/clients

Если у вас уже была более ранняя тестовая версия, где awg0 хранился в /etc/amnezia/amneziawg/awg0/clients, скрипт умеет использовать существующий layout и не ломает его.

nftables
--------
Скрипт scripts/03_setup_nftables.sh собирает append-safe правила для всех найденных AWG конфигов:

  /etc/amnezia/amneziawg/*.conf

Он добавляет:
- разрешение UDP ListenPort каждого AWG интерфейса на внешнем интерфейсе;
- forward для всех AWG interface names;
- IPv4 masquerade для выхода в интернет через внешний интерфейс;
- сохранение правил в /etc/nftables.conf без перезаписи существующего файла;
- enable/restart awg-quick@<iface>.service для найденных интерфейсов.

Важное поведение безопасности: скрипт не использует глобальный flush ruleset и не копирует новый файл поверх старого nftables.conf. Если /etc/nftables.conf уже существует, в конец дописывается отдельный table/append-команды AmneziaWG. Если на сервере уже есть строгий кастомный firewall, проверьте итоговую политику вручную: append-only режим сохраняет старые правила и не пытается их удалить или переупорядочить.

Ручные скрипты
--------------
Все низкоуровневые скрипты сохранены:

  scripts/01_install_from_source.sh     установка/переустановка AWG из исходников
  scripts/02_create_server_config.sh    создание одного интерфейса
  scripts/03_setup_nftables.sh          firewall/NAT для всех интерфейсов
  scripts/04_add_client.sh              добавление клиента в выбранный интерфейс
  scripts/05_update_amneziawg.sh        обновление/восстановление AWG
  scripts/06_run_all.sh                 совместимый wrapper на 00_manage.sh
  scripts/07_add_interface.sh           совместимый shortcut для добавления интерфейса

Но обычный путь теперь один:

  sudo ./install.sh

Офлайн-режим
------------
Если на сервере нет доступа к GitHub:

1. На машине с интернетом выполните:

     ./sources/download_upstream_sources.sh

2. Убедитесь, что в sources/ появились архивы:

     amneziawg-linux-kernel-module-master.tar.gz
     amneziawg-tools-master.tar.gz

3. Перенесите весь bundle на сервер.
4. Запустите:

     sudo FORCE_OFFLINE=yes ./install.sh

Тесты
-----
В архиве есть сухие тесты с заглушками awg/systemctl/nft:

  cd amneziawg_bundle
  sudo ./tests/run_tests.sh

Тесты проверяют:
- bash -n всех скриптов;
- append-only поведение sysctl/install.env;
- создание awg0;
- server MTU и DEFAULT_CLIENT_MTU;
- nftables для одного интерфейса без flush ruleset;
- добавление клиента IPv4-only;
- запрет перезаписи существующего awg0 даже при OVERWRITE_EXISTING_IFACE=yes;
- создание awg1 без поломки awg0;
- append-only дополнение nftables для двух интерфейсов;
- добавление клиента именно в awg1;
- единый мастер-скрипт --status.

См. также
---------
- docs/CONFIG_GUIDE.txt
- docs/TROUBLESHOOTING.txt
- docs/CHANGES_AND_AUDIT.txt
- scripts/README.txt
