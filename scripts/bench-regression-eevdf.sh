#!/bin/sh
# Regression benchmark for EEVDF base/nice19 latency.
# Run inside StarryOS guest shell:
#   sh /root/bench-regression-eevdf.sh
#
# Optional:
#   LOAD=6 sh /root/bench-regression-eevdf.sh
#   SAMPLES=30,100 sh /root/bench-regression-eevdf.sh
#   BASELINE_MODE=refresh sh /root/bench-regression-eevdf.sh
#   PROBE_NAME=busybox_sha256 PROBE_CMD='sha256sum /bin/busybox >/dev/null' sh /root/bench-regression-eevdf.sh
#   MARKERS=0 sh /root/bench-regression-eevdf.sh   # disable console markers

set -eu

LOAD="${LOAD:-4}"
RESULT_DIR="${RESULT_DIR:-/tmp/bench-results}"
PROBE_NAME="${PROBE_NAME:-ls}"
PROBE_CMD="${PROBE_CMD:-ls >/dev/null}"
SAMPLES="${SAMPLES:-50,200}"
BASELINE_FILE="${RESULT_DIR}/${PROBE_NAME}-baseline.tsv"
LATEST_FILE="${RESULT_DIR}/${PROBE_NAME}-latest.tsv"
TABLE_FILE="${RESULT_DIR}/${PROBE_NAME}-latest-table.md"
ARCHIVE_FILE="${RESULT_DIR}/${PROBE_NAME}-history.tsv"
BASELINE_MODE="${BASELINE_MODE:-check}" # check | refresh
MARKERS="${MARKERS:-1}" # 1 | 0

SAMPLE_LIST="$(echo "${SAMPLES}" | tr ',' ' ')"
if [ -z "${SAMPLE_LIST}" ]; then
    echo "[bench] ERROR: SAMPLES is empty"
    exit 1
fi

# StarryOS/busybox: redundant `mkdir -p` can still walk "/" and fail with EINVAL;
# skip when RESULT_DIR already exists as a directory.
[ -d "${RESULT_DIR}" ] || mkdir -p "${RESULT_DIR}"

run_case() {
    label="$1"   # base | nice19
    samples="$2" # 50 | 200
    out_file="${RESULT_DIR}/${PROBE_NAME}_${label}_${samples}.txt"
    case_id="${PROBE_NAME}:${label}:${samples}:load${LOAD}"

    if [ "${MARKERS}" = "1" ]; then
        echo "[bench-marker] case-start ${case_id}"
    fi

    killall yes 2>/dev/null || true

    i=1
    while [ "$i" -le "$LOAD" ]; do
        if [ "$label" = "nice19" ]; then
            nice -n 19 yes > /dev/null &
        else
            yes > /dev/null &
        fi
        i=$((i + 1))
    done

    sleep 1
    i=1
    while [ "$i" -le "$samples" ]; do
        /usr/bin/time -f "%e" sh -c "${PROBE_CMD}"
        i=$((i + 1))
    done > "${out_file}" 2>&1

    killall yes 2>/dev/null || true

    if [ "${MARKERS}" = "1" ]; then
        echo "[bench-marker] case-end ${case_id}"
    fi
}

calc_stats() {
    label="$1"
    samples="$2"
    file="${RESULT_DIR}/${PROBE_NAME}_${label}_${samples}.txt"

    sort -n "${file}" | awk -v scenario="${label}" -v n_expect="${samples}" '
        { a[++n] = $1 }
        END {
            if (n == 0) {
                printf("%s\t%d\t0\t0\t0\t0\n", scenario, n_expect);
                exit 1;
            }
            p50 = a[int((n - 1) * 0.50) + 1];
            p95 = a[int((n - 1) * 0.95) + 1];
            p99 = a[int((n - 1) * 0.99) + 1];
            printf("%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\n", scenario, n, p50, p95, p99, a[n]);
        }'
}

write_table() {
    target="$1"
    printf "| Scenario | N | p50 | p95 | p99 | max |\n" > "${target}"
    printf "| --- | ---: | ---: | ---: | ---: | ---: |\n" >> "${target}"
    awk -F '\t' '{printf("| %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6)}' "${LATEST_FILE}" >> "${target}"
}

compare_baseline() {
    if [ ! -f "${BASELINE_FILE}" ]; then
        echo "[bench] baseline not found, creating initial baseline"
        cp "${LATEST_FILE}" "${BASELINE_FILE}"
        return 0
    fi

    echo "[bench] baseline compare (delta = latest - baseline, seconds):"
    echo "scenario/samples  dp95   dp99   dmax"
    while IFS="$(printf '\t')" read -r scenario n p50 p95 p99 pmax; do
        base_line="$(awk -F '\t' -v s="${scenario}" -v nn="${n}" '$1==s && $2==nn {print $0}' "${BASELINE_FILE}" || true)"
        if [ -z "${base_line}" ]; then
            printf "%s/%s\t(new)\t(new)\t(new)\n" "${scenario}" "${n}"
            continue
        fi
        base_p95="$(echo "${base_line}" | awk -F '\t' '{print $4}')"
        base_p99="$(echo "${base_line}" | awk -F '\t' '{print $5}')"
        base_pmax="$(echo "${base_line}" | awk -F '\t' '{print $6}')"
        awk -v s="${scenario}" -v n="${n}" -v a="${p95}" -v b="${base_p95}" -v c="${p99}" -v d="${base_p99}" -v e="${pmax}" -v f="${base_pmax}" '
            BEGIN {
                printf "%s/%s\t%+.3f\t%+.3f\t%+.3f\n", s, n, a-b, c-d, e-f;
            }'
    done < "${LATEST_FILE}"
}

echo "[bench] running base/nice19 regression (probe=${PROBE_NAME}; samples=${SAMPLES}; load=${LOAD})"
echo "[bench] probe cmd: ${PROBE_CMD}"

: > "${LATEST_FILE}"
for n in ${SAMPLE_LIST}; do
    case "${n}" in
        ''|*[!0-9]*)
            echo "[bench] ERROR: invalid sample '${n}' in SAMPLES='${SAMPLES}'"
            exit 1
            ;;
        *)
            ;;
    esac
    run_case base "${n}"
    run_case nice19 "${n}"
    calc_stats base "${n}" >> "${LATEST_FILE}"
    calc_stats nice19 "${n}" >> "${LATEST_FILE}"
done

write_table "${TABLE_FILE}"

if [ "${BASELINE_MODE}" = "refresh" ]; then
    cp "${LATEST_FILE}" "${BASELINE_FILE}"
    echo "[bench] baseline refreshed"
else
    compare_baseline
fi

ts="$(date +%Y%m%d-%H%M%S)"
awk -v ts="${ts}" -F '\t' '{printf("%s\t%s\n", ts, $0)}' "${LATEST_FILE}" >> "${ARCHIVE_FILE}"

echo ""
echo "[bench] latest table:"
cat "${TABLE_FILE}"
echo ""
echo "[bench] files:"
echo "  latest:   ${LATEST_FILE}"
echo "  table:    ${TABLE_FILE}"
echo "  baseline: ${BASELINE_FILE}"
echo "  history:  ${ARCHIVE_FILE}"
