# Kali nástroje na Ubuntu/Debianu

`setup-kali-tools.sh` doinstaluje penetračně-testovací nástroje z Kali Linux
(`kali-rolling`) přímo do systému založeného na Debianu/Ubuntu — **bez výměny
základního OS**. Určeno pro **autorizovaný pentest a CTF**.

## Jak je to bezpečné

Kali repozitář se přidá s **apt pinningem** (`Pin-Priority: 50`). Díky tomu apt
z Kali **nikdy sám neupgraduje** balíčky základního systému (libc, jádro,
systémové knihovny) — což je nejčastější příčina rozbití při míchání repozitářů.
Instalují se jen explicitně vyžádané nástroje přes `-t kali-rolling`.

GPG klíč se před přidáním ověřuje proti očekávanému fingerprintu
(`44C6513A8E4FB3D30875F758ED444FF07D8D0BF6`).

## Použití

```bash
# základní kuratorovaná sada (nmap, sqlmap, metasploit, john, hashcat, …)
sudo ./setup-kali-tools.sh

# jen připravit repozitář, nic neinstalovat
sudo TOOLSET=base ./setup-kali-tools.sh

# velký metabalíček kali-linux-headless
sudo TOOLSET=top10 ./setup-kali-tools.sh

# vlastní seznam balíčků
sudo ./setup-kali-tools.sh nmap sqlmap gobuster

# odstranit Kali repo + pinning (nainstalované balíčky zůstanou)
sudo PURGE=1 ./setup-kali-tools.sh
```

## Proměnné prostředí

| Proměnná     | Výchozí                     | Popis                                         |
|--------------|-----------------------------|-----------------------------------------------|
| `TOOLSET`    | `core`                      | `core` \| `top10` \| `base`                   |
| `KALI_MIRROR`| `http://http.kali.org/kali` | Zrcadlo repozitáře                            |
| `PURGE`      | `0`                         | `1` = odinstalovat repo a pinning             |

## Poznámky

- Vyžaduje root (`sudo`) a funkční `apt-get`.
- Potřebuje přístup k internetu (`archive.kali.org`, zrcadla Kali). Za proxy
  respektuje `http_proxy`/`https_proxy` prostředí.
- Pozdější instalace dalšího nástroje: `sudo apt-get install -t kali-rolling <balíček>`.
- Ověření pinningu: `apt-cache policy` — Kali řádek musí mít prioritu `50`.
