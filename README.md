# BambuBar for Omarchy

The live status of your **Bambu Lab** 3D printer in the Omarchy bar: progress, time left, temperatures and AMS humidity, without opening Bambu Studio or the phone app.

![The bar widget and its panel during a print](preview.png)

*(Demo mode, sample data.)*

This is the Omarchy version of [BambuBar](https://github.com/kopytjuk/bambubar), a macOS menu bar app. It shows the same things, built as an Omarchy shell plugin.

- **In the bar:** the bamboo mark, plus progress and time left while a print runs (`64% · 1h 23m`), *Paused*, *Done* or *Failed* otherwise. The mark is dimmed while the printer can't be reached and turns red when a print fails or the login is rejected.
- **In the panel:** job name, progress bar, layer, time left, nozzle and bed temperature, AMS humidity per unit (in % where the hardware reports it, otherwise as a 1–5 level) and total print time.
- **Local only:** talks directly to the printer on your network. No cloud, no account.
- English, Danish and German, following Omarchy's language setting.

## Requirements

- A Bambu Lab printer on the same network, with **LAN mode** on (newer firmware may also need *Developer mode*)
- The printer's **IP address**, **serial number** and **access code**, all on the printer's screen under *Settings → WLAN / Device*
- `python3` and `secret-tool`, both part of a standard Omarchy install

## Install

```bash
omarchy plugin add https://github.com/tripex/omarchy-bambubar --enable
```

Update later with `omarchy plugin update tripex.bambubar`.

## Set up

Click the bamboo icon. The first time, the panel asks for the printer's IP address, serial number and access code. Press **Save** and BambuBar connects, and reconnects on its own if the connection drops.

Change the settings later with the cog in the panel or `s`. Leave the access code empty to keep the saved one.

Tip: give the printer a fixed IP address in your router so the setting never goes stale.

## Use

| | |
| --- | --- |
| Click | Open or close the panel |
| Middle-click | Ask the printer for a full status update |
| `r` in the panel | Same as middle-click |
| `s` in the panel | Printer settings |

From a script or a key binding:

```bash
omarchy-shell tripex.bambubar toggle
omarchy-shell tripex.bambubar status    # e.g. "Printing 64% · 1h 23m"
omarchy-shell tripex.bambubar refresh
```

Widget settings, set with `omarchy bar set tripex.bambubar <key> <value>`:

| Key | Default | |
| --- | --- | --- |
| `showProgress` | `true` | Progress and time left next to the icon. Vertical bars always show the icon only. |
| `demo` | `false` | A sample print, no printer needed. |

## How it works

Bambu Lab printers run an MQTT broker on port `8883` (TLS, user `bblp`, password = access code). The widget starts `bin/bambubar-bridge`, a small Python program using only the standard library, that subscribes to `device/<serial>/report`, asks the printer for a full status dump and merges the partial updates it keeps sending. The bridge and the widget talk JSON lines over stdin and stdout.

Where things are kept:

| What | Where |
| --- | --- |
| IP address and serial number | `~/.config/bambubar/printer.json` |
| Access code | Your keyring (`secret-tool`, service `bambubar`) |
| Total print time | `~/.local/state/bambubar/stats.json` |

The access code goes to the bridge over stdin, never on a command line, so it doesn't show up in `ps`.

The printer uses a self-signed certificate, so BambuBar does not verify it. Only use it on a network you trust.

## Limitations

- Works on the local network only (use a VPN or Tailscale to reach your home network from elsewhere).
- The printer does not report its lifetime print hours over MQTT, so *Total print time* only counts what BambuBar has seen while it was running.
- One printer.
- Developed against the same report fields as the macOS app; other models may report fields differently.

## Development

```bash
python3 -m unittest discover -s tests
```

The tests cover the MQTT framing, the report parsing and a full connection against a fake TLS printer (needs `openssl` for a test certificate).

Omarchy runs its shell with Quickshell's file watcher off, so after changing a file run `omarchy restart shell` to see it.

## Disclaimer

BambuBar is an unofficial community project and is not affiliated with or endorsed by Bambu Lab.

## License

[MIT](LICENSE)
