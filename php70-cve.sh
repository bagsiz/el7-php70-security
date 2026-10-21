#!/bin/bash
# PHP 7.0 (Remi, CentOS 7) için CVE-2026-109618 / CVE-2026-109619 yamalı paket kurulumu
#
# Kullanım:
#   ./php70-cve.sh status              kurulu PHP 7.0 paketlerini ve yama durumunu göster
#   ./php70-cve.sh install [-y]        kurulu PHP 7.0 paketlerini yamalı sürüme yükselt
#   ./php70-cve.sh uninstall [-y]      yamadan önceki sürümlere geri dön
#
# İki kurulum türü otomatik algılanır (ikisi birden de olabilir):
#   base: php, php-cli, php-fpm ... 7.0.x  (remi-php70 reposu; /usr/bin/php, php-fpm servisi)
#   scl : php70-php-*                      (Remi SCL; /opt/remi/php70, php70-php-fpm servisi)
# Yalnızca sunucuda zaten kurulu olan PHP paketleri değiştirilir. Bu pakette bulunmayanlar
# (pecl eklentileri, php-pear, php70-runtime ...) olduğu gibi kalır.
# install sonrası doğrulama başarısız olursa otomatik olarak geri alınır.
set -uo pipefail

PATCHED_VR=7.0.33-47.1.el7
CVE=CVE-2026-109618
HERE=$(cd "$(dirname "$0")" && pwd)
STATE_ROOT=/var/lib/php70-cve-2026

# RPM'ler GitHub release'inde: rpms/<base|scl> yoksa ilgili arşiv indirilir ve
# aşağıdaki SHA256 ile doğrulanır. Erişim yoksa (private repo, internet yok) arşivi
# elle indirip bu scriptin yanına koyun.
RELEASE_URL=${PHP70CVE_RELEASE_URL:-https://github.com/bagsiz/el7-php70-security/releases/download/v7.0.33-47.1}
SHA256_base=234361a140373e8e71307be8b43406092a3cca8bfae0c84ee91b12e28ec1039e
SHA256_scl=83183bc2ede37c4db8084c2cc6714835f0399012dda34180e39947373b5deef5

# yamalı sürümü bulunan paketler
PKGS_base="php php-bcmath php-cli php-common php-dba php-dbg php-devel php-embedded php-enchant php-fpm php-gd php-gmp php-imap php-interbase php-intl php-json php-ldap php-litespeed php-mbstring php-mcrypt php-mysqlnd php-odbc php-opcache php-pdo php-pdo-dblib php-pgsql php-process php-pspell php-recode php-snmp php-soap php-tidy php-xml php-xmlrpc"
PKGS_scl="php70-php php70-php-bcmath php70-php-cli php70-php-common php70-php-dba php70-php-dbg php70-php-devel php70-php-embedded php70-php-enchant php70-php-fpm php70-php-gd php70-php-gmp php70-php-imap php70-php-interbase php70-php-intl php70-php-json php70-php-ldap php70-php-litespeed php70-php-mbstring php70-php-mcrypt php70-php-mysqlnd php70-php-odbc php70-php-opcache php70-php-pdo php70-php-pdo-dblib php70-php-pgsql php70-php-process php70-php-pspell php70-php-recode php70-php-snmp php70-php-soap php70-php-tidy php70-php-xml php70-php-xmlrpc"

ASSUME_YES=0
CMD=${1:-status}
[ "${2:-}" = "-y" ] && ASSUME_YES=1

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mUYARI:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mHATA:\033[0m %s\n' "$*" >&2; exit 1; }
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [e/H] " a
    [ "$a" = e ] || [ "$a" = E ]
}

# kurulum türüne göre değişkenler
set_mode() {
    MODE=$1
    case $MODE in
    base)
        TITLE="php (base, remi-php70)"
        COMMON=php-common
        GLOBS="php php-*"
        PHP=/usr/bin/php
        FPM=/usr/sbin/php-fpm
        CONF_PATHS="etc/php.ini etc/php.d etc/php-fpm.conf etc/php-fpm.d etc/httpd/conf.d/php.conf"
        SERVICES="php-fpm httpd"
        ;;
    scl)
        TITLE="php70 (Remi SCL)"
        COMMON=php70-php-common
        GLOBS="php70-php php70-php-*"
        PHP=/opt/remi/php70/root/usr/bin/php
        FPM=/opt/remi/php70/root/usr/sbin/php-fpm
        CONF_PATHS="etc/opt/remi/php70 etc/httpd/conf.d/php70-php.conf"
        SERVICES="php70-php-fpm httpd"
        ;;
    esac
    RPM_DIR=$HERE/rpms/$MODE
    STATE_DIR=$STATE_ROOT/$MODE
    eval "PKGS=\$PKGS_$MODE ASSET_SHA=\$SHA256_$MODE"
    ASSET=php70-rpms-$MODE.tar.gz
}

has_patched() { # NAME: bu pakette yamalı sürümü var mı
    case " $PKGS " in *" $1 "*) return 0 ;; esac
    return 1
}

# rpms/<mode> yoksa release arşivini indir, doğrula, aç
fetch_rpms() {
    [ -f "$RPM_DIR/SHA256SUMS" ] && return 0
    local f=$HERE/$ASSET
    if [ ! -f "$f" ]; then
        say "RPM'ler indiriliyor: $RELEASE_URL/$ASSET"
        curl -fL --retry 3 --connect-timeout 20 -o "$f.part" "$RELEASE_URL/$ASSET" && mv "$f.part" "$f" || {
            rm -f "$f.part"
            die "$ASSET indirilemedi. Release'den elle indirip $HERE/ içine koyun ve tekrar çalıştırın"
        }
    fi
    echo "$ASSET_SHA  $f" | sha256sum --quiet -c - || die "$ASSET SHA256 uyuşmuyor (bozuk ya da değiştirilmiş); silip yeniden indirin"
    tar xzf "$f" -C "$HERE" || die "$ASSET açılamadı"
}

# bu sunucudaki PHP 7.0 kurulum türleri (base / scl)
detect_modes() {
    local v
    v=$(rpm -q --qf '%{VERSION}' php-common 2>/dev/null) && case $v in 7.0.*) echo base ;; esac
    rpm -q php70-php-common >/dev/null 2>&1 && echo scl
    return 0
}

# Paket adı -> kurulum türü: base | scl | desteklenmeyen kurulumun açıklaması
classify_pkg() { # NAME VERSION
    case "$1" in
        php70-php|php70-php-*)          echo scl ;;
        php70w*|mod_php70w*)            echo "Webtatic php70w (desteklenmiyor)" ;;
        php70u*|mod_php70u*)            echo "IUS php70u (desteklenmiyor)" ;;
        php|php-cli|php-fpm|php-cgi|php-common)
            case "$2" in 7.0.*) echo base ;; *) echo "PHP $2 (7.0 değil)" ;; esac ;;
        php[0-9]*-php*)                 echo "Remi SCL ${1%%-*} (7.0 değil)" ;;
        *)                              echo "paket $1 (tanınmıyor)" ;;
    esac
}

# Dosyanın sahibi: "rpm NAME VERSION", "dpkg NAME" ya da "yok"
owner_of() { # PATH
    local q
    if command -v rpm >/dev/null 2>&1 && q=$(rpm -qf --qf '%{NAME} %{VERSION}\n' "$1" 2>/dev/null | head -1); then
        echo "rpm $q"
    elif command -v dpkg >/dev/null 2>&1 && q=$(dpkg -S "$1" 2>/dev/null | head -1 | cut -d: -f1); then
        echo "dpkg $q"
    else
        echo yok
    fi
}

php_version_of() { # BINARY (php / php-fpm / php-cgi)
    local v
    v=$("$1" -v 2>/dev/null | head -1) || true
    v=${v#PHP }; echo "${v%% *}"
}

# Sunucudaki tüm PHP'leri bulur ve nasıl kullanıldığını yazar.
# Her satır: TÜR|AÇIKLAMA   (TÜR: base, scl ya da - )
discover() {
    local cands=() p real own ver kind how pid exe conf mod f cmd
    local -A hows=() order=()
    local n=0
    local names="php php70 php7.0 php-fpm php-fpm70 php-fpm7.0 php70-php-fpm php-cgi php-cgi70 php-cgi7.0"
    for p in $names; do
        f=$(command -v "$p" 2>/dev/null) && cands+=("$f|komut '$p'")
    done
    for f in /usr/bin/php* /usr/sbin/php-fpm* /usr/local/bin/php* /usr/local/sbin/php-fpm* \
             /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
             /usr/local/php*/bin/php /usr/local/php*/sbin/php-fpm /opt/php*/bin/php /opt/php*/sbin/php-fpm; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        # yalnızca yorumlayıcılar: php, php70, php7.0, php-cgi*, php70-cgi, php-fpm* (phpize, php-config, phar hariç)
        case "${f##*/}" in
            php|php[0-9]|php[0-9][0-9]|php[0-9].[0-9]|php-fpm*|php-cgi*|php[0-9]*-cgi) cands+=("$f|$f") ;;
        esac
    done
    # çalışan php-fpm master süreçleri: başlık "php-fpm: master process (conf)";
    # başlık değiştirilmemişse komut satırının ilk argümanı php-fpm yoludur
    local ppid_
    for p in /proc/[0-9]*; do
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        pid=${p#/proc/}
        exe=$(readlink -f "$p/exe" 2>/dev/null)
        case "$cmd" in
            "php-fpm: master"*) ;;
            /*)
                case "${cmd%% *}" in */php-fpm*) ;; *) continue ;; esac
                # master: ebeveyni php-fpm olmayan süreç
                ppid_=$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null)
                case "$(tr '\0' ' ' < "/proc/$ppid_/cmdline" 2>/dev/null)" in *php-fpm*) continue ;; esac
                [ -n "$exe" ] || exe=${cmd%% *}
                ;;
            *) continue ;;
        esac
        [ -n "$exe" ] || continue
        conf=$(echo "$cmd" | sed -n 's/.*(\(.*\)).*/\1/p')
        cands+=("$exe|ÇALIŞIYOR: php-fpm master pid $pid${conf:+ ($conf)}")
    done
    # Apache'de yüklü PHP modülü (mod_php)
    for f in /etc/httpd/conf.modules.d/*.conf /etc/httpd/conf.d/*.conf; do
        [ -f "$f" ] || continue
        while read -r mod; do
            [ -n "$mod" ] || continue
            case "$mod" in /*) ;; *) mod=/etc/httpd/$mod ;; esac
            cands+=("$(readlink -f "$mod")|Apache modülü ($f)")
        done < <(sed -n 's/^[[:space:]]*LoadModule[[:space:]]\+php[0-9_]*module[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$f")
    done

    # aynı gerçek dosyaya giden yolları tek satırda birleştir
    # bash 4.2 (CentOS 7): boş dizi "set -u" ile unbound sayılır
    [ ${#cands[@]} -gt 0 ] || return 0
    for p in "${cands[@]}"; do
        f=${p%%|*}; how=${p#*|}
        real=$(readlink -f "$f" 2>/dev/null || echo "$f")
        [ "$how" = "$f" ] && { [ "$f" = "$real" ] && how="" || how="link: $f"; }
        if [ -z "${order[$real]+x}" ]; then order[$real]=$n; n=$((n+1)); hows[$real]=$how
        elif [ -n "$how" ]; then
            case "; ${hows[$real]}; " in *"; $how; "*) ;; *) hows[$real]="${hows[$real]:+${hows[$real]}; }$how" ;; esac
        fi
    done

    for real in $(for r in "${!order[@]}"; do echo "${order[$r]} $r"; done | sort -n | cut -d' ' -f2-); do
        how=${hows[$real]}
        own=$(owner_of "$real")
        case "$real" in *.so) ver="" ;; *) ver=$(php_version_of "$real") ;; esac
        case "$own" in
            rpm\ *) set -- $own; kind=$(classify_pkg "$2" "$3"); [ -z "$ver" ] && ver=$3 ;;
            dpkg\ *) kind="Debian/Ubuntu paketi ${own#dpkg } (desteklenmiyor)" ;;
            *) kind="hiçbir pakete ait değil: kaynaktan derlenmiş/elle kopyalanmış (desteklenmiyor)" ;;
        esac
        f="$real  [PHP ${ver:-?}]${how:+  ($how)}"
        case "$kind" in base|scl) echo "$kind|$f" ;;
                        *)        echo "-|$f : $kind" ;; esac
    done
}

print_discovery() {
    local line k found=0
    say "Sunucudaki PHP'ler"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=1; k=${line%%|*}
        case $k in
            base) echo "  [yamalanabilir: base] ${line#*|}" ;;
            scl)  echo "  [yamalanabilir: scl ] ${line#*|}" ;;
            *)    echo "  [dokunulmayacak    ] ${line#*|}" ;;
        esac
    done < <(discover)
    [ "$found" = 1 ] || echo "  (hiç PHP bulunamadı)"
}

# "NAME VERSION-RELEASE" satırları
installed_pkgs() {
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' $GLOBS | sort
}

is_patched() { # NAME
    [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null)" = "$PATCHED_VR" ]
}

active_services() {
    local s
    for s in $SERVICES; do
        systemctl is-active --quiet "$s" >/dev/null 2>&1 && echo "$s"
    done
}

preflight() {
    [ "$(id -u)" = 0 ] || die "root olarak çalıştırın"
    grep -q 'release 7\.' /etc/centos-release 2>/dev/null || die "yalnızca CentOS 7 için"
    [ "$(uname -m)" = x86_64 ] || die "yalnızca x86_64 için"
}

# kurulum sonrası kontroller; hata varsa 1 döner
verify() {
    local ok=0 out
    say "Doğrulama ($TITLE)"
    if out=$("$PHP" -v 2>&1); then echo "  php -v: $(echo "$out" | head -1)"; else echo "  php -v BAŞARISIZ: $out"; ok=1; fi
    out=$("$PHP" -m 2>&1 | grep -iE 'warning|error|fatal|unable to')
    if [ -n "$out" ]; then echo "  php -m uyarı/hata verdi:"; echo "$out" | sed 's/^/    /'; ok=1; else echo "  modüller: uyarısız yüklendi"; fi
    if rpm -q --changelog "$COMMON" | grep -q "$CVE"; then echo "  changelog: $CVE var"; else echo "  changelog: $CVE YOK"; ok=1; fi
    if [ -x "$FPM" ]; then
        if out=$("$FPM" -t 2>&1); then echo "  php-fpm -t: tamam"; else echo "  php-fpm -t BAŞARISIZ:"; echo "$out" | sed 's/^/    /'; ok=1; fi
    fi
    if systemctl is-active --quiet httpd >/dev/null 2>&1 || [ -n "${HTTPD_CHECK:-}" ]; then
        if command -v apachectl >/dev/null 2>&1; then
            if out=$(apachectl -t 2>&1); then echo "  apachectl -t: tamam"; else echo "  apachectl -t BAŞARISIZ:"; echo "$out" | sed 's/^/    /'; ok=1; fi
        fi
    fi
    # yalnızca test için: otomatik geri alma yolunu denemek
    [ -n "${PHP70CVE_TEST_FAIL_VERIFY:-}" ] && { echo "  (test) doğrulama bilerek başarısız sayıldı"; ok=1; }
    return $ok
}

restart_services() { # servis listesi
    local s ok=0
    for s in "$@"; do
        say "$s yeniden başlatılıyor"
        if systemctl restart "$s" && sleep 2 && systemctl is-active --quiet "$s" >/dev/null 2>&1; then
            echo "  $s: aktif"
        else
            echo "  $s: BAŞLATILAMADI"; systemctl status "$s" --no-pager -l 2>&1 | tail -15 | sed 's/^/    /'; ok=1
        fi
    done
    return $ok
}

status_mode() {
    local name vr mark
    say "Kurulu paketler: $TITLE"
    while read -r name vr; do
        [ -n "$name" ] || continue
        if [ "$vr" = "$PATCHED_VR" ]; then mark="yamalı"
        elif has_patched "$name"; then mark="YAMASIZ (yamalı sürüm mevcut)"
        else mark="dokunulmayacak (bu pakette yok)"; fi
        printf '  %-32s %-24s %s\n' "$name" "$vr" "$mark"
    done < <(installed_pkgs)
    say "Servisler"
    for s in $SERVICES; do printf '  %-16s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done
    if [ -L "$STATE_DIR/current" ]; then say "Son kurulumun yedeği: $(readlink "$STATE_DIR/current")"; fi
}

install_mode() {
    fetch_rpms
    say "Paket bütünlüğü kontrol ediliyor ($TITLE)"
    (cd "$RPM_DIR" && sha256sum --quiet -c SHA256SUMS) || die "RPM dosyaları bozuk ya da değiştirilmiş"

    local name vr files=() upgrade=() skipped=()
    while read -r name vr; do
        [ -n "$name" ] || continue
        if is_patched "$name"; then continue; fi
        if has_patched "$name"; then
            [ -f "$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm" ] || die "$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm yok"
            files+=("$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm"); upgrade+=("$name $vr")
        else
            skipped+=("$name $vr")
        fi
    done < <(installed_pkgs)

    if [ ${#upgrade[@]} -eq 0 ]; then
        say "$TITLE: yükseltilecek paket yok, kurulu paketler zaten yamalı"
        return 0
    fi

    say "$TITLE: yükseltilecek paketler (→ $PATCHED_VR)"
    printf '  %s\n' "${upgrade[@]}"
    if [ ${#skipped[@]} -gt 0 ]; then
        say "$TITLE: dokunulmayacak paketler"
        printf '  %s\n' "${skipped[@]}"
    fi

    if [ -x "$FPM" ] && ! "$FPM" -t >/dev/null 2>&1; then
        "$FPM" -t
        die "php-fpm yapılandırması kurulumdan ÖNCE de hatalı; önce bunu düzeltin"
    fi

    local services
    services=$(active_services)
    say "Kurulumdan sonra yeniden başlatılacak servisler: ${services:-(yok)}"

    confirm "Devam edilsin mi?" || die "iptal edildi"

    # yedek
    local backup=$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S) p existing=()
    mkdir -p "$backup/rpms"
    say "Yedek alınıyor: $backup"
    printf '%s\n' "${upgrade[@]}" > "$backup/upgraded.txt"
    echo "$services" > "$backup/services.txt"
    for p in $CONF_PATHS; do [ -e "/$p" ] && existing+=("$p"); done
    if [ ${#existing[@]} -gt 0 ] && tar czf "$backup/config.tar.gz" -C / "${existing[@]}" 2>/dev/null; then
        echo "  yapılandırma: $backup/config.tar.gz"
    fi

    # geri dönüş için mevcut sürümlerin RPM'leri
    command -v yumdownloader >/dev/null 2>&1 || yum -y -q install yum-utils >/dev/null 2>&1
    local missing=() nevra line
    for line in "${upgrade[@]}"; do
        set -- $line
        nevra="$1-$2.x86_64"
        if [ -z "${PHP70CVE_NO_DOWNLOAD:-}" ] && yumdownloader -q --destdir "$backup/rpms" "$nevra" >/dev/null 2>&1 \
                && [ -f "$backup/rpms/$nevra.rpm" ]; then
            :
        else
            missing+=("$nevra")
        fi
    done
    echo "  eski sürüm RPM'leri: $(( ${#upgrade[@]} - ${#missing[@]} ))/${#upgrade[@]} indirildi"
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Şu sürümler repoda bulunamadı, yedeklenemedi:"
        printf '    %s\n' "${missing[@]}" >&2
        warn "uninstall bunlar için repodaki en son sürüme (yamasız) döner"
        confirm "Yine de devam edilsin mi?" || { rm -rf "$backup"; die "iptal edildi"; }
    fi
    ln -sfn "$backup" "$STATE_DIR/current"

    say "Yamalı paketler kuruluyor ($TITLE)"
    if ! yum -y localinstall "${files[@]}"; then
        die "yum kurulumu başarısız; sistem değişmedi (yum işlemi geri alındı). Yedek: $backup"
    fi

    local failed=0
    verify || failed=1
    if [ "$failed" = 0 ] && [ -n "$services" ]; then
        restart_services $services || failed=1
    fi

    if [ "$failed" = 1 ]; then
        warn "Doğrulama başarısız, otomatik geri alınıyor ($TITLE)"
        ASSUME_YES=1 uninstall_mode
        die "kurulum geri alındı"
    fi
    say "Tamam: $TITLE yamalı sürüme ($PATCHED_VR) yükseltildi"
}

uninstall_mode() {
    if [ ! -L "$STATE_DIR/current" ]; then
        say "$TITLE: kurulum yedeği yok, bu script ile kurulum yapılmamış; atlanıyor"
        return 0
    fi
    local backup
    backup=$(readlink "$STATE_DIR/current")
    [ -f "$backup/upgraded.txt" ] || die "$backup/upgraded.txt yok"

    local name vr local_rpms=() repo_pkgs=()
    while read -r name vr; do
        [ -n "$name" ] || continue
        is_patched "$name" || continue
        if [ -f "$backup/rpms/$name-$vr.x86_64.rpm" ]; then
            local_rpms+=("$backup/rpms/$name-$vr.x86_64.rpm")
        else
            repo_pkgs+=("$name")
        fi
    done < "$backup/upgraded.txt"

    if [ ${#local_rpms[@]} -eq 0 ] && [ ${#repo_pkgs[@]} -eq 0 ]; then
        say "$TITLE: geri alınacak yamalı paket yok"
        rm -f "$STATE_DIR/current"; return 0
    fi

    say "$TITLE: geri dönülecek sürümler"
    [ ${#local_rpms[@]} -gt 0 ] && printf '  %s (yedekten)\n' "${local_rpms[@]##*/}"
    [ ${#repo_pkgs[@]} -gt 0 ] && printf '  %s → repodaki en son sürüm\n' "${repo_pkgs[@]}"
    confirm "Devam edilsin mi?" || die "iptal edildi"

    if [ ${#local_rpms[@]} -gt 0 ]; then
        rpm -Uvh --oldpackage "${local_rpms[@]}" || die "rpm downgrade başarısız"
    fi
    if [ ${#repo_pkgs[@]} -gt 0 ]; then
        yum -y downgrade "${repo_pkgs[@]}" || die "yum downgrade başarısız"
    fi

    local services
    services=$(cat "$backup/services.txt" 2>/dev/null)
    [ -n "$services" ] && restart_services $services

    rm -f "$STATE_DIR/current"
    say "$TITLE geri alındı. Yapılandırma yedeği: $backup/config.tar.gz (otomatik geri yüklenmez)"
}

main() {
    local modes m
    case "$CMD" in
        status|install|uninstall) ;;
        *) sed -n '2,15p' "$0"; exit 2 ;;
    esac
    # status her sunucuda çalışır (yalnızca rapor); install/uninstall CentOS 7 ister
    [ "$CMD" = status ] || preflight

    if [ "$CMD" = uninstall ]; then
        # geri alma: bu script ile kurulmuş her tür
        modes=$(for m in base scl; do [ -L "$STATE_ROOT/$m/current" ] && echo $m; done)
        [ -n "$modes" ] || die "geri alınacak kurulum yok ($STATE_ROOT); bu script ile kurulum yapılmamış"
    else
        print_discovery
        command -v rpm >/dev/null 2>&1 && modes=$(detect_modes) || modes=""
        if [ -z "$modes" ]; then
            say "Yamalanabilir PHP 7.0 kurulumu yok (Remi php-* 7.0 ya da php70-php-*)"
            [ "$CMD" = status ] && exit 0 || exit 1
        fi
    fi

    for m in $modes; do
        set_mode "$m"
        case "$CMD" in
            status)    status_mode ;;
            install)   install_mode ;;
            uninstall) uninstall_mode ;;
        esac
    done
    [ "$CMD" = install ] && say "Geri almak için: $0 uninstall"
    return 0
}

main
