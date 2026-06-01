# VCAM Development Repository

Virtual Camera tweak for iOS 14.0+ (rootless Theos).

**Version:** 272.3

## Stream
Подними MJPEG-сервер на ПК (`start-stream.bat`) и укажи в настройках твика:
`http://<IP-компьютера>:8888/live`

Также поддерживается HLS (URL должен заканчиваться на `.m3u8`).

## Build
GitHub Actions автоматически собирает `.deb` при пуше в `main`.
Артефакт: `VirtualCamPro_deb`.
