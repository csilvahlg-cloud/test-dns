#!/usr/bin/env bash
#
# dnstest-2026.sh
# Versión extendida y actualizada (2026) de cleanbrowsing/dnsperftest
#
# Métricas: Min / Max / Mediana / Avg / Jitter / QPS estimado / Tasa de éxito
# Ranking final ordenado por velocidad
#
# Lista de resolvers actualizada para 2026:
#   - Removidos: Freenom (descontinuado), Norton, Neustar, Yandex, Comodo
#   - Agregados: Mullvad, Control D, DNS4EU, variantes de seguridad
#
# Uso:
#   bash dnstest-2026.sh              # IPv4 (default)
#   bash dnstest-2026.sh ipv4
#   bash dnstest-2026.sh ipv6
#   bash dnstest-2026.sh all          # IPv4 + IPv6
#   bash dnstest-2026.sh secure       # solo resolvers con filtrado de malware
#   bash dnstest-2026.sh privacy      # solo resolvers privacy-first

command -v bc > /dev/null || { echo "error: bc not found. Please install bc."; exit 1; }
{ command -v drill > /dev/null && dig=drill; } || { command -v dig > /dev/null && dig=dig; } || { echo "error: dig not found. Please install dnsutils."; exit 1; }

NAMESERVERS=$(cat /etc/resolv.conf | grep ^nameserver | cut -d " " -f 2 | sed 's/\(.*\)/&#&/')

# ============================================================================
# RESOLVERS IPv4 - Listado actualizado mayo 2026
# ============================================================================
# Formato: IP#nombre
#
# Categorías:
#   [GP]  = General Purpose (sin filtrado)
#   [SEC] = Security (bloquea malware/phishing)
#   [FAM] = Family (malware + contenido adulto)
#   [PRIV]= Privacy-first (no logs verificable)
#   [EU]  = European data sovereignty
# ============================================================================

PROVIDERSV4="
1.1.1.1#cloudflare
1.1.1.2#cloudflare-security
1.1.1.3#cloudflare-family
8.8.8.8#google
9.9.9.9#quad9-secure
9.9.9.10#quad9-unsecure
149.112.112.112#quad9-secondary
208.67.222.222#opendns
208.67.222.123#opendns-familyshield
185.228.168.168#cleanbrowsing-security
185.228.168.10#cleanbrowsing-family
185.228.168.9#cleanbrowsing-adult
94.140.14.14#adguard
94.140.14.15#adguard-family
194.242.2.2#mullvad
194.242.2.3#mullvad-adblock
194.242.2.4#mullvad-base
76.76.2.0#controld-free
76.76.10.0#controld-malware
86.54.11.100#dns4eu-protective
86.54.11.200#dns4eu-noads
45.90.28.202#nextdns
"

# Solo IPv6
PROVIDERSV6="
2606:4700:4700::1111#cloudflare-v6
2606:4700:4700::1112#cloudflare-security-v6
2001:4860:4860::8888#google-v6
2620:fe::fe#quad9-secure-v6
2620:119:35::35#opendns-v6
2a0d:2a00:1::1#cleanbrowsing-v6
2a10:50c0::ad1:ff#adguard-v6
2a07:e340::2#mullvad-v6
2a07:e340::3#mullvad-adblock-v6
2606:1a40::#controld-v6
2a13:1001::86:54:11:100#dns4eu-v6
"

# Subconjunto: solo resolvers privacy-first (audited, no logs)
PROVIDERS_PRIVACY="
1.1.1.1#cloudflare
9.9.9.9#quad9-secure
194.242.2.2#mullvad
194.242.2.4#mullvad-base
45.90.28.202#nextdns
"

# Subconjunto: solo resolvers con filtrado de seguridad activo
PROVIDERS_SECURE="
1.1.1.2#cloudflare-security
1.1.1.3#cloudflare-family
9.9.9.9#quad9-secure
208.67.222.123#opendns-familyshield
185.228.168.168#cleanbrowsing-security
185.228.168.10#cleanbrowsing-family
94.140.14.14#adguard
94.140.14.15#adguard-family
194.242.2.3#mullvad-adblock
76.76.10.0#controld-malware
86.54.11.100#dns4eu-protective
"

# Testing for IPv6 support
$dig +short +tries=1 +time=2 +stats @2a0d:2a00:1::1 www.google.com | grep 216.239.38.120 >/dev/null 2>&1
if [ $? = 0 ]; then
    hasipv6="true"
fi

providerstotest=$PROVIDERSV4
mode_label="IPv4 (default)"

case "$1" in
    ipv6)
        if [ "x$hasipv6" = "x" ]; then
            echo "error: IPv6 support not found. Unable to do the ipv6 test."; exit 1;
        fi
        providerstotest=$PROVIDERSV6
        mode_label="IPv6"
        ;;
    ipv4)
        providerstotest=$PROVIDERSV4
        mode_label="IPv4"
        ;;
    all)
        if [ "x$hasipv6" = "x" ]; then
            providerstotest=$PROVIDERSV4
            mode_label="IPv4 (no IPv6 detected)"
        else
            providerstotest="$PROVIDERSV4 $PROVIDERSV6"
            mode_label="IPv4 + IPv6"
        fi
        ;;
    privacy)
        providerstotest=$PROVIDERS_PRIVACY
        mode_label="Privacy-first only"
        ;;
    secure)
        providerstotest=$PROVIDERS_SECURE
        mode_label="Security-filtered only"
        ;;
    *)
        providerstotest=$PROVIDERSV4
        ;;
esac

# Dominios a probar
DOMAINS2TEST="www.google.com amazon.com facebook.com www.youtube.com www.reddit.com wikipedia.org x.com gmail.com www.netflix.com whatsapp.com www.github.com www.cloudflare.com"

totaldomains=0
for d in $DOMAINS2TEST; do
    totaldomains=$((totaldomains + 1))
done

RESULTS_FILE=$(mktemp)

echo ""
echo "================================================================"
echo " DNS PERFORMANCE TEST - 2026 Edition"
echo " Mode: $mode_label"
echo " Domains tested per provider: $totaldomains"
echo "================================================================"
echo ""

printf "%-25s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
    "Provider" "Min" "Max" "Median" "Avg" "Jitter" "QPS" "Success"
printf "%-25s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
    "-------------------------" "----" "----" "------" "----" "------" "----" "-------"

for p in $NAMESERVERS $providerstotest; do
    pip=${p%%#*}
    pname=${p##*#}

    times=()
    successes=0
    failures=0

    for d in $DOMAINS2TEST; do
        ttime=$($dig +tries=1 +time=2 +stats @$pip $d 2>/dev/null | grep "Query time:" | cut -d : -f 2- | cut -d " " -f 2)
        if [ -z "$ttime" ]; then
            ttime=1000
            failures=$((failures + 1))
        elif [ "x$ttime" = "x0" ]; then
            ttime=1
            successes=$((successes + 1))
        else
            successes=$((successes + 1))
        fi
        times+=($ttime)
    done

    # Cálculos
    sum=0
    min=${times[0]}
    max=${times[0]}
    for t in "${times[@]}"; do
        sum=$((sum + t))
        [ "$t" -lt "$min" ] && min=$t
        [ "$t" -gt "$max" ] && max=$t
    done

    avg=$(bc -l <<< "scale=2; $sum/$totaldomains")

    sorted=($(printf '%s\n' "${times[@]}" | sort -n))
    mid=$((totaldomains / 2))
    if [ $((totaldomains % 2)) -eq 0 ]; then
        median=$(bc -l <<< "scale=2; (${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2")
    else
        median=${sorted[$mid]}
    fi

    jitter_sum=0
    for t in "${times[@]}"; do
        diff=$(bc -l <<< "scale=2; if ($t - $avg < 0) -1*($t - $avg) else ($t - $avg)")
        jitter_sum=$(bc -l <<< "scale=2; $jitter_sum + $diff")
    done
    jitter=$(bc -l <<< "scale=2; $jitter_sum / $totaldomains")

    if (( $(bc -l <<< "$avg > 0") )); then
        qps=$(bc -l <<< "scale=2; 1000 / $avg")
    else
        qps="N/A"
    fi

    success_rate=$(bc -l <<< "scale=1; ($successes * 100) / $totaldomains")

    printf "%-25s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
        "$pname" "${min}ms" "${max}ms" "${median}ms" "${avg}ms" "${jitter}ms" "$qps" "${success_rate}%"

    echo "$avg|$pname|$min|$max|$median|$jitter|$qps|$success_rate" >> "$RESULTS_FILE"
done

# Ranking final
echo ""
echo "================================================================"
echo " RANKING POR VELOCIDAD (latencia promedio, menor a mayor)"
echo "================================================================"
printf "%-5s %-25s %-12s %-12s %-12s\n" "Pos" "Provider" "Avg (ms)" "QPS est." "Success"
printf "%-5s %-25s %-12s %-12s %-12s\n" "---" "-------------------------" "--------" "--------" "-------"

pos=1
sort -t'|' -k1 -n "$RESULTS_FILE" | while IFS='|' read -r avg pname min max median jitter qps success; do
    printf "%-5s %-25s %-12s %-12s %-12s\n" "$pos" "$pname" "$avg" "$qps" "${success}%"
    pos=$((pos + 1))
done

rm -f "$RESULTS_FILE"

echo ""
echo "================================================================"
echo " GUÍA DE RESOLVERS (2026)"
echo "================================================================"
cat <<'EOF'

SIN FILTRADO (general purpose):
  cloudflare         1.1.1.1          Más rápido global, audited no-logs
  google             8.8.8.8          Ubicuo, infra masiva
  quad9-unsecure     9.9.9.10         Quad9 sin bloqueos
  opendns            208.67.222.222   Cisco
  mullvad-base       194.242.2.4      Suecia, zero-log, sin filtros

SEGURIDAD (bloquea malware/phishing):
  cloudflare-security 1.1.1.2         Malware blocking
  quad9-secure       9.9.9.9          No-profit, threat intel integrada
  cleanbrowsing-sec  185.228.168.168  Bloqueo malware
  adguard            94.140.14.14     Malware + ads
  controld-malware   76.76.10.0       Malware blocking
  dns4eu-protective  86.54.11.100     EU, GDPR, anti-malware

FAMILY (malware + contenido adulto):
  cloudflare-family  1.1.1.3          Familia
  cleanbrowsing-fam  185.228.168.10   Familia estricta
  opendns-fam        208.67.222.123   FamilyShield
  adguard-family     94.140.14.15     Familia + ads

PRIVACY-FIRST (auditados, no logs verificable):
  mullvad            194.242.2.2      Suecia, RAM-only, zero-log
  mullvad-adblock    194.242.2.3      Igual + ad block
  quad9-secure       9.9.9.9          Suiza, no-profit
  nextdns            45.90.28.202     Configurable (requiere cuenta)

EU SOVEREIGNTY:
  dns4eu-protective  86.54.11.100     Iniciativa UE, GDPR-compliant
  dns4eu-noads       86.54.11.200     + ad blocking

EOF

echo "Leyenda métricas:"
echo "  Min/Max/Median/Avg : latencia en ms"
echo "  Jitter             : variabilidad promedio (menor = más estable)"
echo "  QPS                : queries/segundo estimados (1000/avg)"
echo "  Success            : % consultas exitosas (sin timeout)"
echo ""

exit 0
