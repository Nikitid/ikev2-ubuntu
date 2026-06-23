# IKEv2 Manager for Ubuntu

[English](README.en.md)

[![Лицензия: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Проверки](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml/badge.svg)](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml)

Интерактивный Bash-скрипт для установки и обслуживания IKEv2/IPsec-сервера
на Ubuntu. Проект рассчитан на один сервер и использует strongSwan с
`swanctl`, сертификаты ACME, пользователей EAP-MSCHAPv2 и правила
межсетевого экрана.

## Состояние

Поддерживаются Ubuntu 22.04 LTS и 24.04 LTS. Актуальная стабильная версия —
`v1.2.0`.

## Возможности

- установка, переустановка и удаление IKEv2-сервера;
- выпуск сертификатов через `acme.sh` с проверкой `dns-01` или `http-01`;
- управление VPN-пользователями и экспорт клиентских конфигураций;
- IPv4 full tunnel, защита от утечек IPv6 или NAT66;
- изоляция VPN-клиентов и ограничение входящего трафика;
- диагностика, журналы, управление службами и обновление сертификатов;
- дополнительное управление MTProxy и 3x-ui.

## Требования

- Ubuntu 22.04 LTS или 24.04 LTS;
- права `root`;
- systemd и iptables;
- публичное доменное имя, указывающее на сервер.

## Установка

Стабильный релиз:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/v1.2.0/scripts/ikev2-manager.sh)
```

Текущая ветка `main`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/main/scripts/ikev2-manager.sh)
```

Перед запуском удаленного скрипта рекомендуется проверить его содержимое и
использовать закрепленный тег релиза.

## Использование и конфигурация

Скрипт открывает интерактивное меню. Управляемые файлы и состояние хранятся в
`/opt/ikev2-manager`.

- UDP-порты `500` и `4500` должны быть открыты во внешнем межсетевом экране.
- Для `http-01` во время выпуска сертификата необходим входящий TCP-порт `80`.
- Для `dns-01` потребуются учетные данные выбранного DNS-провайдера.
- Пароли VPN и экспортированные клиентские наборы содержат секреты.

## Разработка

```bash
bash -n scripts/ikev2-manager.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```

Дополнительные правила работы с репозиторием описаны в [AGENTS.md](AGENTS.md).

## Безопасность

Не публикуйте конфигурацию из `/opt/ikev2-manager`, пароли, сертификаты,
закрытые ключи и клиентские наборы. Порядок сообщения об уязвимостях указан в
[SECURITY.md](SECURITY.md).

## Лицензия

[MIT](LICENSE)
