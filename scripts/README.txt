README по скриптам
==================

Рекомендуемый вход
------------------

  sudo ./install.sh

или:

  sudo ./scripts/00_manage.sh

00_manage.sh
------------
Единый интерактивный мастер.

Он сканирует текущее состояние:
- awg / awg-quick;
- kernel module amneziawg;
- install.env;
- sysctl-файл;
- nftables.conf;
- firewall.env;
- все /etc/amnezia/amneziawg/*.conf;
- ListenPort, Address, MTU и количество клиентов по каждому интерфейсу;
- service state awg-quick@<iface>.service.

Режимы:

  sudo ./scripts/00_manage.sh
  sudo ./scripts/00_manage.sh --status
  sudo ./scripts/00_manage.sh --help

01_install_from_source.sh
-------------------------
Устанавливает зависимости, скачивает или берёт из локальных архивов исходники, собирает модуль ядра через DKMS, собирает awg-tools в новый каталог без перезаписи старых бинарников и включает:

  net.ipv4.ip_forward = 1

Полезные переменные:

  FORCE_OFFLINE=yes
  SKIP_PACKAGE_INSTALL=yes
  SKIP_BUILD=yes
  SKIP_MODPROBE=yes
  INSTALL_QRENCODE=yes
  TOOLS_INSTALL_ROOT=/usr/local/libexec/amneziawg-bundle-tools

02_create_server_config.sh
--------------------------
Создаёт один интерфейс AmneziaWG. Подходит как для первого awg0, так и для дополнительных awg1/awg2.

Спрашивает:
- имя интерфейса;
- UDP ListenPort;
- IPv4 /24 адрес сервера;
- IPv6 /64 ULA адрес сервера;
- endpoint host;
- DNS для клиентов;
- MTU сервера;
- MTU клиента по умолчанию;
- Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4.

Безопасность:
- по умолчанию предлагает следующее свободное имя awgN;
- если указать существующий интерфейс, скрипт откажется продолжать;
- существующие .conf, ключи и клиенты не перезаписываются.

Пример неинтерактивного запуска для awg1:

  sudo VPN_IF_DEFAULT=awg1 \
       LISTEN_PORT_DEFAULT=443 \
       SERVER_ADDR_V4_DEFAULT=10.8.2.1/24 \
       SERVER_ADDR_V6_DEFAULT=fd42:42:43::1/64 \
       SERVER_MTU_DEFAULT=1280 \
       CLIENT_MTU_DEFAULT=1280 \
       ./scripts/02_create_server_config.sh

03_setup_nftables.sh
--------------------
Сканирует все:

  /etc/amnezia/amneziawg/*.conf

и создаёт или дополняет firewall/NAT для всех интерфейсов сразу.

Добавляет:
- named set vpn_ports со всеми ListenPort;
- named set vpn_ifaces со всеми awgN;
- IPv4 masquerade;
- enable/restart awg-quick@<iface>.service.

Безопасность: /etc/nftables.conf не перезаписывается. Если файла нет, он создаётся. Если файл уже есть, скрипт дописывает table ip amneziawg_bundle или append-команды в конец. Глобальный flush ruleset не используется.

04_add_client.sh
----------------
Добавляет клиента в выбранный интерфейс.

Примеры:

  sudo ./scripts/04_add_client.sh phone awg0
  sudo CLIENT_MTU=1280 ./scripts/04_add_client.sh phone awg1
  sudo CLIENT_ENABLE_IPV6=yes ./scripts/04_add_client.sh phone awg0

Если интерфейс не указан и их несколько, скрипт предложит выбрать.

По умолчанию клиент создаётся IPv4-only:

  AllowedIPs = 0.0.0.0/0

Для IPv6 нужно явно задать:

  CLIENT_ENABLE_IPV6=yes

05_update_amneziawg.sh
----------------------
Повторно запускает установку из исходников, делает dkms autoinstall и перезапускает все найденные awg-quick@<iface>.service.

06_run_all.sh
-------------
Оставлен для совместимости. Сейчас это wrapper на:

  scripts/00_manage.sh

07_add_interface.sh
-------------------
Оставлен для совместимости как shortcut для добавления интерфейса.
Рекомендуемый путь всё равно:

  sudo ./install.sh

Файлы состояния
---------------

  /etc/amnezia/amneziawg/install.env
  /etc/amnezia/amneziawg/firewall.env
  /etc/amnezia/amneziawg/manager.env
  /etc/amnezia/amneziawg/manager-<iface>.env
  /etc/amnezia/amneziawg/<iface>.conf

Тесты
-----

  sudo ./tests/run_tests.sh
