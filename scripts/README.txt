README по скриптам
==================

Рекомендуемый вход
------------------

  sudo ./install.sh
  sudo ./scripts/00_manage.sh

00_manage.sh
------------
Единый интерактивный мастер. Режимы:

  sudo ./scripts/00_manage.sh
  sudo ./scripts/00_manage.sh --status
  sudo ./scripts/00_manage.sh --help

Меню умеет установить AWG, создать интерфейс, добавить/удалить клиента, добавить/удалить интерфейс, пересобрать firewall, обновить AWG и восстановить backup.

01_install_from_source.sh
-------------------------
Устанавливает зависимости, берёт исходники из sources/ или скачивает их, собирает DKMS module и awg-tools. Если старые awg/awg-quick уже существуют, новые tools ставятся в отдельный safe-prefix, чтобы не перезаписать старые бинарники.

Полезные переменные:

  FORCE_OFFLINE=yes
  SKIP_PACKAGE_INSTALL=yes
  SKIP_BUILD=yes
  SKIP_MODPROBE=yes
  INSTALL_QRENCODE=yes
  TOOLS_INSTALL_ROOT=/usr/local/libexec/amneziawg-bundle-tools

02_create_server_config.sh
--------------------------
Создаёт новый интерфейс.

  sudo ./scripts/02_create_server_config.sh

Особенности:
- повторное создание существующего интерфейса запрещено;
- IPv4 default выбирается как следующая свободная /24;
- IPv6 ULA default выбирается синхронно с IPv4;
- endpoint default берётся из системного IPv4 source address;
- если IPv6 включён, MTU < 1280 не принимается;
- перед операцией создаётся backup/rollback папка;
- при Ctrl+C/ошибке созданные файлы удаляются, изменённые восстанавливаются.

Полезные переменные:

  VPN_IF_DEFAULT=awg1
  LISTEN_PORT_DEFAULT=443
  SERVER_ADDR_V4_DEFAULT=10.8.2.1/24
  SERVER_ADDR_V6_DEFAULT=fd42:42:43::1/64
  ENABLE_IPV6_DEFAULT=yes|no
  ENDPOINT_HOST_DEFAULT=203.0.113.10
  SERVER_MTU_DEFAULT=1280
  CLIENT_MTU_DEFAULT=1280

03_setup_nftables.sh
--------------------
Пересобирает nftables для всех найденных AWG-интерфейсов.

  sudo ./scripts/03_setup_nftables.sh

Особенности:
- создаёт timestamp-backup;
- перезаписывает итоговый /etc/nftables.conf candidate;
- итоговый файл начинается с `flush ruleset`, чтобы runtime rules не наслаивались;
- объединяет AWG UDP ports в одно правило;
- объединяет AWG masquerade в одно правило;
- сохраняет пользовательские правила, если структура firewall понятна;
- удаляет старую `table ip amneziawg_bundle` из candidate.

Полезные переменные:

  EXTERNAL_IF_DEFAULT=ens3
  SSH_PORT_DEFAULT=22
  NFT_SAVE_CHANGES=yes|no|ask
  NFT_APPLY_NOW=yes|no|ask
  ALLOW_NO_INTERFACES=yes
  EXTRA_AWG_PORTS_TO_REMOVE=520
  EXTRA_AWG_IFACES_TO_REMOVE=awg1

04_add_client.sh
----------------
Добавляет клиента.

  sudo ./scripts/04_add_client.sh phone awg0

По умолчанию IPv4-only:

  server.conf: AllowedIPs = 10.8.X.Y/32
  client.conf: AllowedIPs = 0.0.0.0/0

Явный IPv6:

  sudo CLIENT_ENABLE_IPV6=yes CLIENT_MTU=1280 ./scripts/04_add_client.sh phone6 awg0

Полезные переменные:

  CLIENT_MTU=1280
  CLIENT_ENABLE_IPV6=yes|no
  ENDPOINT_HOST_OVERRIDE=vpn.example.com
  ENDPOINT_PORT_OVERRIDE=443
  DNS_SERVERS_OVERRIDE='1.1.1.1, 8.8.8.8'
  ROLLBACK_ON_RESTART_FAIL=yes|no
  QR_OUTPUT=no

05_update_amneziawg.sh
----------------------
Обновляет/восстанавливает установку AWG и пытается перезапустить все найденные awg-quick@*.service. install.env перезаписывается с backup.

  sudo ./scripts/05_update_amneziawg.sh

06_run_all.sh
-------------
Совместимый wrapper на 00_manage.sh.

07_add_interface.sh
-------------------
Совместимый wrapper на создание дополнительного интерфейса через 00_manage/02_create_server_config.

08_remove_client.sh
-------------------
Удаляет клиента из server.conf и удаляет client.conf.

  sudo ./scripts/08_remove_client.sh phone awg0

Создаёт backup. При неудачном restart по умолчанию откатывает изменения.

09_remove_interface.sh
----------------------
Удаляет интерфейс и чистит nftables.

  sudo CONFIRM_REMOVE=yes ./scripts/09_remove_interface.sh awg1

Полезные переменные:

  CONFIRM_REMOVE=yes|no|ask
  SKIP_FIREWALL_UPDATE=yes|no
  NFT_SAVE_CHANGES=yes|no|ask
  NFT_APPLY_NOW=yes|no|ask

10_restore_backup.sh
--------------------
Восстанавливает состояние из backup.

  sudo ./scripts/10_restore_backup.sh
  sudo RESTORE_CONFIRM=yes ./scripts/10_restore_backup.sh /etc/amnezia/amneziawg/backups/YYYYMMDD-HHMMSS-label

Полезные переменные:

  RESTORE_CONFIRM=yes|no|ask
  RESTORE_APPLY_NFT=yes|no|ask
  RESTORE_RESTART_SERVICES=yes|no|ask
