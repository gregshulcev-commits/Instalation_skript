Папка для локальных архивов исходников AmneziaWG.

Основные скрипты сначала пытаются взять исходники из интернета.
Если интернет недоступен, они ищут локальные архивы в этой папке.

Поддерживаемые имена файлов:
- amneziawg-linux-kernel-module-master.tar.gz
- amneziawg-linux-kernel-module.tar.gz
- amneziawg-tools-master.tar.gz
- amneziawg-tools.tar.gz

Если вы хотите подготовить bundle к работе без интернета:
1. Запустите download_upstream_sources.sh на машине с доступом в интернет.
2. Убедитесь, что архивы лежат в этой папке.
3. Перенесите весь архив bundle на сервер.
