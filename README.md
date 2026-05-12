# netmode Releases

Dieses Repository enthaelt oeffentliche Release-Pakete fuer netmode.

## Schnellstart

Stable installieren oder aktualisieren:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/netmode_releases/main/install.sh | sudo bash
```

Pre-Release installieren:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/netmode_releases/main/install.sh | sudo bash -s -- --pre
```

Bestimmte Version installieren:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/netmode_releases/main/install.sh | sudo bash -s -- --tag v0.1.4
```

## Service

```bash
systemctl status netmode --no-pager
journalctl -u netmode -f
```

## Lizenz

Die Nutzung ist fuer private und nicht-kommerzielle Zwecke erlaubt. Kommerzielle Nutzung benoetigt eine vorherige schriftliche Zustimmung von ehive. Siehe `LICENSE.txt` und `THIRD_PARTY_NOTICES.txt`.
