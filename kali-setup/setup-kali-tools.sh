#!/usr/bin/env bash
#
# setup-kali-tools.sh
#
# Doinstaluje nastroje z Kali Linux (kali-rolling) primo do systemu zalozeneho
# na Debianu/Ubuntu, BEZ nahrazeni zakladniho OS. Urceno pro AUTORIZOVANY
# pentest a CTF.
#
# Bezpecnost: Kali repozitar se pridava s prisnym apt pinningem (Pin-Priority
# nizka), takze apt z nej NIKDY sam neupgraduje zakladni balicky (libc, jadro,
# atd.). Instaluji se jen explicitne vyzadane nastroje.
#
# Pouziti:
#   sudo ./setup-kali-tools.sh                 # nainstaluje zakladni sadu (TOOLSET=core)
#   sudo TOOLSET=top10 ./setup-kali-tools.sh   # kali-linux-headless metabalicek
#   sudo TOOLSET=base  ./setup-kali-tools.sh   # jen pripravi repo, nic neinstaluje
#   sudo ./setup-kali-tools.sh nmap sqlmap     # vlastni seznam balicku
#   sudo PURGE=1 ./setup-kali-tools.sh         # odstrani Kali repo + pinning
#
set -euo pipefail

KALI_MIRROR="${KALI_MIRROR:-http://http.kali.org/kali}"
KALI_LIST="/etc/apt/sources.list.d/kali.list"
KALI_PREF="/etc/apt/preferences.d/kali-pin"
KALI_KEYRING="/usr/share/keyrings/kali-archive-keyring.gpg"
KALI_KEY_URL="https://archive.kali.org/archive-key.asc"

# Kuratorovana zakladni sada pro pentest/CTF. Jednotlive nastroje misto
# metabalicku -> mene zavislosti, mensi riziko konfliktu se zakladnim systemem.
CORE_TOOLS=(
  nmap
  netcat-traditional
  sqlmap
  nikto
  hydra
  john
  hashcat
  gobuster
  ffuf
  dirb
  wpscan
  whatweb
  dnsutils
  dnsrecon
  seclists
  wordlists
  metasploit-framework
  exploitdb
  binwalk
  foremost
  steghide
  radare2
  ltrace
  tcpdump
  tshark
  aircrack-ng
  hping3
  masscan
  enum4linux
  smbclient
  proxychains4
)

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Spust jako root (sudo)."

# --- Odinstalace ------------------------------------------------------------
if [[ "${PURGE:-0}" == "1" ]]; then
  log "Odstranuji Kali repozitar a pinning (nainstalovane balicky zustavaji)."
  rm -f "$KALI_LIST" "$KALI_PREF" "$KALI_KEYRING"
  apt-get update -o Dir::Etc::sourceparts="-" 2>/dev/null || apt-get update || true
  log "Hotovo."
  exit 0
fi

command -v apt-get >/dev/null || die "apt-get nenalezen - tohle neni system zalozeny na Debianu/Ubuntu."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  log "Detekovany system: ${PRETTY_NAME:-$ID}"
fi

export DEBIAN_FRONTEND=noninteractive

# --- 1) Zavislosti pro pridani repa ----------------------------------------
log "Instaluji pomocne balicky (gpg, curl, ca-certificates)..."
apt-get update -y
apt-get install -y --no-install-recommends curl gnupg ca-certificates apt-transport-https

# --- 2) GPG klic Kali ------------------------------------------------------
log "Stahuji a overuji archivacni klic Kali..."
tmpkey="$(mktemp)"
curl -fsSL "$KALI_KEY_URL" -o "$tmpkey"
# Ocekavany fingerprint oficialniho Kali archive klice.
EXPECTED_FPR="44C6513A8E4FB3D30875F758ED444FF07D8D0BF6"
got_fpr="$(gpg --show-keys --with-colons "$tmpkey" | awk -F: '/^fpr:/{print $10; exit}')"
if [[ "$got_fpr" != "$EXPECTED_FPR" ]]; then
  rm -f "$tmpkey"
  die "Fingerprint klice nesouhlasi! ocekavano=$EXPECTED_FPR dostalo=$got_fpr"
fi
gpg --dearmor < "$tmpkey" > "$KALI_KEYRING"
rm -f "$tmpkey"
log "Klic overen (fpr $EXPECTED_FPR) a ulozen do $KALI_KEYRING."

# --- 3) Repozitar ----------------------------------------------------------
log "Pridavam kali-rolling repozitar -> $KALI_LIST"
echo "deb [signed-by=$KALI_KEYRING] $KALI_MIRROR kali-rolling main contrib non-free non-free-firmware" > "$KALI_LIST"

# --- 4) APT PINNING (klicove pro bezpecnost) -------------------------------
# Vychozi priorita vsech balicku z Kali = 50 (= nizsi nez nainstalovane i nez
# repozitare puvodniho systemu). Apt tedy z Kali NIKDY sam neupgraduje nic,
# co uz je v systemu. Pozadovane nastroje nainstalujeme explicitne nize
# pres `-t kali-rolling`.
log "Nastavuji apt pinning -> $KALI_PREF (Kali balicky maji nizkou prioritu)"
cat > "$KALI_PREF" <<EOF
Package: *
Pin: release o=Kali
Pin-Priority: 50
EOF

log "apt-get update..."
apt-get update -y

# --- 5) Instalace nastroju -------------------------------------------------
TOOLSET="${TOOLSET:-core}"
declare -a PKGS=()

if [[ $# -gt 0 ]]; then
  PKGS=("$@")
  log "Instaluji vlastni seznam: ${PKGS[*]}"
elif [[ "$TOOLSET" == "base" ]]; then
  log "TOOLSET=base -> repozitar pripraven, zadne nastroje se neinstaluji."
  log "Pozdeji napr.: sudo apt-get install -t kali-rolling nmap sqlmap"
  exit 0
elif [[ "$TOOLSET" == "top10" ]]; then
  PKGS=(kali-linux-headless)
  warn "TOOLSET=top10 stahne metabalicek kali-linux-headless (stovky MB, vice zavislosti)."
else
  PKGS=("${CORE_TOOLS[@]}")
  log "TOOLSET=core -> kuratorovana zakladni sada (${#PKGS[@]} balicku)."
fi

# Instaluj z Kali repa; kazdy balicek zvlast, aby jeden chybejici nezastavil vse.
failed=()
for pkg in "${PKGS[@]}"; do
  if apt-get install -y -t kali-rolling "$pkg"; then
    log "OK: $pkg"
  else
    warn "Nepodarilo se: $pkg (preskakuji)"
    failed+=("$pkg")
  fi
done

echo
log "Instalace dokoncena."
if [[ ${#failed[@]} -gt 0 ]]; then
  warn "Neuspesne balicky: ${failed[*]}"
fi
log "Kontrola: 'apt-cache policy' ukaze, ze Kali ma Pin-Priority 50 (bezpecne)."
log "Smazani repa pozdeji: sudo PURGE=1 ./setup-kali-tools.sh"
