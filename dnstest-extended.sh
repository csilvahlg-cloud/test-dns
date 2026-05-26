#!/usr/bin/env bash
#
# dnstest-extended.sh
# Versión extendida de cleanbrowsing/dnsperftest con métricas adicionales:
#   - Mínimo, Máximo, Mediana, Promedio
#   - Jitter (desviación promedio de la latencia)
#   - QPS estimado (queries por segundo)
#   - Tasa de éxito (% de respuestas sin timeout)
#   - Resumen final ordenado por velocidad
#
# Uso:
#   bash dnstest-extended.sh           # IPv4 (default)
#   bash dnstest-extended.sh ipv4
#   bash dnstest-extended.sh ipv6
#   bash dnstest-extended.sh all

command -v bc > /dev/null || { echo "error: bc was not found. Please install bc."; exit 1; }
{ command -v drill > /dev/null && dig=drill; } || { command -v dig > /dev/null && dig=dig; } || { echo "error: dig was not found. Please install dnsutils."; exit 1; }

NAMESERVERS=$(cat /etc/resolv.conf | grep ^nameserver | cut -d " " -f 2 | sed 's/\(.*\)/&#&/')

PROVIDERSV4="
1.1.1.1#cloudflare
4.2.2.1#level3
8.8.8.8#google
9.9.9.9#quad9
80.80.80.80#freenom
208.67.222.123#opendns
199.85.126.20#norton
185.228.168.168#cleanbrowsing
77.88.8.7#yandex
176.103.130.132#adguard
156.154.70.3#neustar
8.26.56.26#comodo
45.90.28.202#nextdns
"

PROVIDERSV6="
2606:4700:4700::1111#cloudflare-v6
2001:4860:4860::8888#google-v6
2620:fe::fe#quad9-v6
2620:119:35::35#opendns-v6
2a0d:2a00:1::1#cleanbrowsing-v6
2a02:6b8::feed:0ff#yandex-v6
2a00:5a60::ad1:0ff#adguard-v6
2610:a1:1018::3#neustar-v6
"

# Testing for IPv6
$dig +short +tries=1 +time=2 +stats @2a0d:2a00:1::1 www.google.com | grep 216.239.38.120 >/dev/null 2>&1
if [ $? = 0 ]; then
    hasipv6="true"
fi

providerstotest=$PROVIDERSV4

if [ "x$1" = "xipv6" ]; then
    if [ "x$hasipv6" = "x" ]; then
        echo "error: IPv6 support not found. Unable to do the ipv6 test."; exit 1;
    fi
    providerstotest=$PROVIDERSV6
elif [ "x$1" = "xipv4" ]; then
    providerstotest=$PROVIDERSV4
elif [ "x$1" = "xall" ]; then
    if [ "x$hasipv6" = "x" ]; then
        providerstotest=$PROVIDERSV4
    else
        providerstotest="$PROVIDERSV4 $PROVIDERSV6"
    fi
else
    providerstotest=$PROVIDERSV4
fi

# Dominios a probar
DOMAINS2TEST="www.google.com amazon.com facebook.com www.youtube.com www.reddit.com wikipedia.org twitter.com gmail.com www.google.com whatsapp.com"

totaldomains=0
for d in $DOMAINS2TEST; do
    totaldomains=$((totaldomains + 1))
done

# Archivo temporal para guardar resultados y luego ordenarlos
RESULTS_FILE=$(mktemp)

# Encabezado
printf "%-20s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
    "Provider" "Min" "Max" "Median" "Avg" "Jitter" "QPS" "Success"
printf "%-20s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
    "--------" "---" "---" "------" "---" "------" "---" "-------"

for p in $NAMESERVERS $providerstotest; do
    pip=${p%%#*}
    pname=${p##*#}

    times=()
    successes=0
    failures=0

    for d in $DOMAINS2TEST; do
        ttime=$($dig +tries=1 +time=2 +stats @$pip $d 2>/dev/null | grep "Query time:" | cut -d : -f 2- | cut -d " " -f 2)
        if [ -z "$ttime" ]; then
            # timeout = 1000 ms y se considera fallo
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

    # --- Cálculos estadísticos ---
    # Suma, min, max
    sum=0
    min=${times[0]}
    max=${times[0]}
    for t in "${times[@]}"; do
        sum=$((sum + t))
        [ "$t" -lt "$min" ] && min=$t
        [ "$t" -gt "$max" ] && max=$t
    done

    # Promedio
    avg=$(bc -l <<< "scale=2; $sum/$totaldomains")

    # Mediana (ordenar y tomar el del medio)
    sorted=($(printf '%s\n' "${times[@]}" | sort -n))
    mid=$((totaldomains / 2))
    if [ $((totaldomains % 2)) -eq 0 ]; then
        median=$(bc -l <<< "scale=2; (${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2")
    else
        median=${sorted[$mid]}
    fi

    # Jitter = desviación promedio absoluta respecto al promedio
    jitter_sum=0
    for t in "${times[@]}"; do
        diff=$(bc -l <<< "scale=2; if ($t - $avg < 0) -1*($t - $avg) else ($t - $avg)")
        jitter_sum=$(bc -l <<< "scale=2; $jitter_sum + $diff")
    done
    jitter=$(bc -l <<< "scale=2; $jitter_sum / $totaldomains")

    # QPS estimado: 1000 ms / latencia promedio
    if (( $(bc -l <<< "$avg > 0") )); then
        qps=$(bc -l <<< "scale=2; 1000 / $avg")
    else
        qps="N/A"
    fi

    # Tasa de éxito
    success_rate=$(bc -l <<< "scale=1; ($successes * 100) / $totaldomains")

    # Imprimir línea
    printf "%-20s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
        "$pname" "${min}ms" "${max}ms" "${median}ms" "${avg}ms" "${jitter}ms" "$qps" "${success_rate}%"

    # Guardar para resumen ordenado (usamos avg como clave de ordenamiento)
    echo "$avg|$pname|$min|$max|$median|$jitter|$qps|$success_rate" >> "$RESULTS_FILE"
done

# --- Resumen ordenado por velocidad (avg ascendente) ---
echo ""
echo "================================================================"
echo " RANKING POR VELOCIDAD (latencia promedio, de menor a mayor)"
echo "================================================================"
printf "%-5s %-20s %-10s %-10s\n" "Pos" "Provider" "Avg (ms)" "QPS est."
printf "%-5s %-20s %-10s %-10s\n" "---" "--------" "--------" "--------"

pos=1
sort -t'|' -k1 -n "$RESULTS_FILE" | while IFS='|' read -r avg pname min max median jitter qps success; do
    printf "%-5s %-20s %-10s %-10s\n" "$pos" "$pname" "$avg" "$qps"
    pos=$((pos + 1))
done

rm -f "$RESULTS_FILE"

echo ""
echo "Leyenda:"
echo "  Min/Max/Median/Avg : latencia de respuesta en milisegundos"
echo "  Jitter             : variabilidad promedio (menor = más estable)"
echo "  QPS                : queries por segundo estimados (1000/avg)"
echo "  Success            : % de consultas que respondieron sin timeout"
echo ""

exit 0
