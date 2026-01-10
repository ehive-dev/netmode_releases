# netmode

`netmode` ist ein kleiner systemd-Dienst (Python), der über GPIO (Button/LED) den Netzwerkmodus umschaltet – typischerweise **DHCP ↔ Default-IP**.  
Er ist für eHive/OpenArc-Systeme gedacht und läuft als **root**, weil Netzwerk- und GPIO-Zugriffe erforderlich sind.

---

## Features

- GPIO Button als Trigger (kurzer/langer Druck je nach Implementierung)
- GPIO LED als Statusanzeige
- Umschalten des Netzwerkmodus:
  - **DHCP aktivieren** oder
  - **statische Default-IP** setzen (CIDR)
- Konfiguration über `/etc/default/netmode`
- Betrieb als `systemd`-Service (`netmode.service`)

---

## Installation (empfohlen)

Installation über GitHub-Releases per `install.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/netmode_releases/main/install.sh | sudo bash -s -- --stable

curl -fsSL https://raw.githubusercontent.com/ehive-dev/netmode_releases/main/install.sh | sudo bash -s -- --pre

curl -fsSL https://raw.githubusercontent.com/ehive-dev/netmode_releases/main/install.sh | sudo bash -s -- --tag v0.1.0

