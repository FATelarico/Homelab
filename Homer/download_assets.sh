#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOH'
Usage:
  download_assets.sh [options] [input_file]

Arguments:
  input_file                 Input file to scan for URLs (default: config.yml)

Options:
  -o, --output-dir DIR       Output directory for downloads (default: assets)
      --max-size-bytes N     Skip files whose Content-Length exceeds N bytes
  -s, --save-url-list        Save filtered file URLs to DIR/origin.txt
      --include-html         Do not exclude HTML responses
      --include-plain-text   Do not exclude text/plain responses
      --parallel-probe       Probe URLs in parallel
      --parallel-jobs N      Number of parallel probe workers (default: 8)
  -h, --help                 Show this help

Examples:
  ./download_assets.sh
  ./download_assets.sh config.yml
  ./download_assets.sh -o static --save-url-list config.yml
  ./download_assets.sh --include-html -o assets site.yml
  ./download_assets.sh --include-plain-text config.yml
  ./download_assets.sh --parallel-probe --parallel-jobs 16 config.yml
EOH
}

max_size_bytes=""
input_file="config.yml"
assets_dir="assets"
save_url_list=false
exclude_html=true
exclude_plain_text=true
parallel_probe=false
parallel_jobs=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; exit 1; }
      assets_dir="$2"
      shift 2
      ;;
    --max-size-bytes)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; exit 1; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "Error: --max-size-bytes must be a non-negative integer" >&2; exit 1; }
      max_size_bytes="$2"
      shift 2
      ;;
    -s|--save-url-list)
      save_url_list=true
      shift
      ;;
    --include-html)
      exclude_html=false
      shift
      ;;
    --include-plain-text)
      exclude_plain_text=false
      shift
      ;;
    --parallel-probe)
      parallel_probe=true
      shift
      ;;
    --parallel-jobs)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; exit 1; }
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Error: --parallel-jobs must be a positive integer" >&2; exit 1; }
      parallel_jobs="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      input_file="$1"
      shift
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Error: too many positional arguments" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$input_file" ]]; then
  echo "Error: input file not found: $input_file" >&2
  exit 1
fi

extract_header_value() {
  local name="$1"
  awk -F': *' -v want="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" '
    {
      sub(/\r$/, "", $0)
    }
    tolower($1) == want {
      print $2
    }
  ' | tail -n1
}

get_probe_metadata() {
  local url="$1"
  local headers=""
  local content_type=""
  local content_length=""
  local need_fallback=false
  local fallback_headers=""
  local fallback_content_type=""
  local fallback_content_length=""

  headers="$(curl -k -L --max-redirs 10 --connect-timeout 10 --max-time 30 -fsSI "$url" 2>/dev/null || true)"

  content_type="$(printf '%s\n' "$headers" | extract_header_value content-type | tr '[:upper:]' '[:lower:]')"
  content_type="${content_type%%;*}"

  content_length="$(printf '%s\n' "$headers" | extract_header_value content-length | tr -d '[:space:]')"
  [[ "$content_length" =~ ^[0-9]+$ ]] || content_length=""

  if [[ -z "$content_type" ]]; then
    need_fallback=true
  fi
  if [[ -n "$max_size_bytes" && -z "$content_length" ]]; then
    need_fallback=true
  fi

  if [[ "$need_fallback" == true ]]; then
    fallback_headers="$(curl -k -L --max-redirs 10 --connect-timeout 10 --max-time 30 -fsS -r 0-0 -D - -o /dev/null "$url" 2>/dev/null || true)"

    if [[ -z "$content_type" ]]; then
      fallback_content_type="$(printf '%s\n' "$fallback_headers" | extract_header_value content-type | tr '[:upper:]' '[:lower:]')"
      content_type="${fallback_content_type%%;*}"
    fi

    if [[ -n "$max_size_bytes" && -z "$content_length" ]]; then
      fallback_content_length="$(printf '%s\n' "$fallback_headers" | extract_header_value content-length | tr -d '[:space:]')"
      [[ "$fallback_content_length" =~ ^[0-9]+$ ]] && content_length="$fallback_content_length"
    fi
  fi

  printf '%s\t%s\n' "$content_type" "$content_length"
}

mkdir -p "$assets_dir"

urls_file="$(mktemp)"
files_file="$(mktemp)"
probe_tmp="$(mktemp -d)"

cleanup() {
  rm -f "$urls_file" "$files_file"
  rm -rf "$probe_tmp"
}
trap cleanup EXIT

get_content_type() {
  local url="$1"
  local headers=""
  local content_type=""

  headers="$(curl -k -L --max-redirs 10 --connect-timeout 10 --max-time 30 -fsSI "$url" 2>/dev/null || true)"
  content_type="$(
    printf '%s\n' "$headers" |
    awk -F': *' '
      {
        sub(/\r$/, "", $0)
      }
      tolower($1) == "content-type" {
        v = tolower($2)
        sub(/;.*/, "", v)
        print v
      }
    ' |
    tail -n1
  )"

  if [[ -z "$content_type" ]]; then
    headers="$(curl -k -L --max-redirs 10 --connect-timeout 10 --max-time 30 -fsS -r 0-0 -D - -o /dev/null "$url" 2>/dev/null || true)"
    content_type="$(
      printf '%s\n' "$headers" |
      awk -F': *' '
        {
          sub(/\r$/, "", $0)
        }
        tolower($1) == "content-type" {
          v = tolower($2)
          sub(/;.*/, "", v)
          print v
        }
      ' |
      tail -n1
    )"
  fi

  printf '%s\n' "$content_type"
}

is_excluded_content_type() {
  case "$1" in
    text/html|application/xhtml+xml)
      [[ "$exclude_html" == true ]] && return 0
      ;;
    text/plain)
      [[ "$exclude_plain_text" == true ]] && return 0
      ;;
  esac
  return 1
}

probe_one() {
  local url="$1"
  local content_type=""
  local content_length=""

  IFS=$'\t' read -r content_type content_length < <(get_probe_metadata "$url")

  if [[ -z "$content_type" ]]; then
    printf 'SKIP\tNO_CONTENT_TYPE\t%s\n' "$url"
    return 0
  fi

  if is_excluded_content_type "$content_type"; then
    printf 'SKIP\tCONTENT_TYPE\t%s\t%s\n' "$content_type" "$url"
    return 0
  fi

  if [[ -n "$max_size_bytes" && -n "$content_length" ]] && (( content_length > max_size_bytes )); then
    printf 'SKIP\tTOO_LARGE\t%s\t%s\t%s\n' "$content_length" "$max_size_bytes" "$url"
    return 0
  fi

  if [[ -n "$content_length" ]]; then
    printf 'KEEP\t%s\t%s\t%s\n' "$content_type" "$content_length" "$url"
  else
    printf 'KEEP\t%s\tUNKNOWN\t%s\n' "$content_type" "$url"
  fi
}

export -f extract_header_value
export -f get_probe_metadata
export -f is_excluded_content_type
export -f probe_one
export exclude_html
export exclude_plain_text
export max_size_bytes

grep -Eo 'https?://[^][(){}<>"'"'"'[:space:]]+' "$input_file" > "$urls_file" || true

mapfile -t unique_urls < <(sort -u "$urls_file")
total_urls="${#unique_urls[@]}"

if [[ "$total_urls" -eq 0 ]]; then
  echo "No URLs found in input." >&2
  : > "$files_file"
else
  echo "Found $total_urls unique URL(s)." >&2
fi

: > "$files_file"

probe_serial() {
  local i=0
  local url=""
  local result=""
  local status=""
  local a=""
  local b=""
  local c=""
  local kept=0

  for url in "${unique_urls[@]}"; do
    i=$((i + 1))
    printf '[%d/%d] Probing %s\n' "$i" "$total_urls" "$url" >&2

    result="$(probe_one "$url")"
    IFS=$'\t' read -r status a b c <<< "$result"

    case "$status" in
      KEEP)
        printf '  -> keep (%s, %s bytes)\n' "$a" "$b" >&2
        printf '%s\n' "$c" >> "$files_file"
        kept=$((kept + 1))
        ;;
      SKIP)
        case "$a" in
          NO_CONTENT_TYPE)
            printf '  -> skip (no content type)\n' >&2
            ;;
          CONTENT_TYPE)
            printf '  -> skip (content type: %s)\n' "$b" >&2
            ;;
          TOO_LARGE)
            printf '  -> skip (too large: %s > %s bytes)\n' "$b" "$c" >&2
            ;;
          *)
            printf '  -> skip (%s)\n' "$a" >&2
            ;;
        esac
        ;;
    esac
  done

  echo "Probe complete: kept $kept of $total_urls URL(s)." >&2
}

probe_parallel() {
  local manifest="$probe_tmp/manifest.tsv"
  local results="$probe_tmp/results.tsv"
  local progress_file="$probe_tmp/progress.count"
  local i=0
  local done_count=0
  local pid=""

  : > "$manifest"
  : > "$results"
  : > "$progress_file"

  for url in "${unique_urls[@]}"; do
    i=$((i + 1))
    printf '%s\t%s\n' "$i" "$url" >> "$manifest"
  done

  (
    awk -F '\t' '{ print $1 }' "$manifest" |
    xargs -n 1 -P "$parallel_jobs" -I {} bash -c '
      set -euo pipefail
      idx="$1"
      manifest="$2"
      results="$3"
      progress_file="$4"

      url="$(awk -F "\t" -v n="$idx" '"'"'$1 == n { sub(/^[^\t]+\t/, "", $0); print; exit }'"'"' "$manifest")"
      result="$(probe_one "$url")"
      printf "%s\t%s\n" "$idx" "$result" >> "$results"
      printf ".\n" >> "$progress_file"
    ' _ {} "$manifest" "$results" "$progress_file"
  ) &
  pid="$!"

  while kill -0 "$pid" 2>/dev/null; do
    if [[ -f "$progress_file" ]]; then
      done_count="$(wc -l < "$progress_file" | tr -d '[:space:]')"
    else
      done_count=0
    fi
    printf '\rProbing in parallel: %d/%d complete' "$done_count" "$total_urls" >&2
    sleep 0.5
  done

  wait "$pid"
  done_count="$(wc -l < "$progress_file" | tr -d '[:space:]')"
  printf '\rProbing in parallel: %d/%d complete\n' "$done_count" "$total_urls" >&2

    sort -n "$results" | while IFS=$'\t' read -r idx status a b c d; do
    if [[ "$status" == "KEEP" ]]; then
      printf '[%s/%s] keep (%s, %s bytes) %s\n' "$idx" "$total_urls" "$a" "$b" "$c" >&2
      printf '%s\n' "$c" >> "$files_file"
    else
      case "$a" in
        NO_CONTENT_TYPE)
          printf '[%s/%s] skip (no content type) %s\n' "$idx" "$total_urls" "$b" >&2
          ;;
        CONTENT_TYPE)
          printf '[%s/%s] skip (content type: %s) %s\n' "$idx" "$total_urls" "$b" "$c" >&2
          ;;
        TOO_LARGE)
          printf '[%s/%s] skip (too large: %s > %s bytes) %s\n' "$idx" "$total_urls" "$b" "$c" "$d" >&2
          ;;
        *)
          printf '[%s/%s] skip (%s)\n' "$idx" "$total_urls" "$a" >&2
          ;;
      esac
    fi
  done

  local kept=0
  if [[ -s "$files_file" ]]; then
    kept="$(wc -l < "$files_file" | tr -d '[:space:]')"
  fi
  echo "Probe complete: kept $kept of $total_urls URL(s)." >&2
}

if [[ "$total_urls" -gt 0 ]]; then
  if [[ "$parallel_probe" == true ]]; then
    echo "Using parallel probe mode with $parallel_jobs worker(s)." >&2
    probe_parallel
  else
    echo "Using single-threaded probe mode." >&2
    probe_serial
  fi
fi

if [[ -s "$files_file" ]]; then
  echo "Starting downloads..." >&2
  wget -i "$files_file" -P "$assets_dir"/ -nc
else
  echo "No matching URLs found after Content-Type filtering." >&2
fi

if [[ "$save_url_list" == true ]]; then
  cp "$files_file" "$assets_dir"/origin.txt
fi
