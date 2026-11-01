#!/usr/bin/env bash
#
# End-to-end test for the JWT proxy.
# Starts the stack, runs every check against it, prints the results and
# shuts everything down again, even if a check fails or the script is stopped.
#
# Usage: ./test.sh
# Needs: docker (with compose), curl, openssl. Port 80 must be free.

set -uo pipefail
cd "$(dirname "$0")"

PROJECT=hw2p-test
BASE=http://localhost
COMPOSE=(docker compose -p "$PROJECT")

# Throwaway values for this run only. They override .env (if there is one),
# so the test never depends on or changes your own settings.
export JWT_SECRET=$(openssl rand -hex 32)
export JWT_TTL=60
export LOGIN_USERNAME=tester
export LOGIN_PASSWORD=$(openssl rand -hex 12)

if [ -t 1 ]; then
    GREEN=$'\e[32m' RED=$'\e[31m' BOLD=$'\e[1m' DIM=$'\e[2m' RESET=$'\e[0m'
else
    GREEN='' RED='' BOLD='' DIM='' RESET=''
fi

passed=0
failed=0

section() {
    printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"
}

# check <description> <expected> <actual> [detail]
# The optional detail (e.g. the response body) is printed under the result.
check() {
    if [ "$2" = "$3" ]; then
        printf '  %sPASS%s  %-58s %s\n' "$GREEN" "$RESET" "$1" "$3"
        passed=$((passed + 1))
    else
        printf '  %sFAIL%s  %-58s expected %s, got %s\n' "$RED" "$RESET" "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
    if [ -n "${4:-}" ]; then
        printf '        %s%s%s\n' "$DIM" "$4" "$RESET"
    fi
}

# request <curl args...>
# Sends a request, sets STATUS ("000" if it never connected) and saves the
# response body and headers to $BODY and $HEADERS.
request() {
    : > "$BODY"
    : > "$HEADERS"
    STATUS=$(curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code}' --max-time 5 "$@")
}

# preview [text to focus on]
# Prints the last response body on one line, cut to a readable length.
# If a focus text is given, the preview starts just before it.
preview() {
    if [ "$STATUS" = "000" ]; then
        echo "(no response, connection failed)"
        return
    fi
    if [ ! -s "$BODY" ]; then
        echo "(empty body)"
        return
    fi
    local text
    text=$(tr -s ' \r\n\t' ' ' < "$BODY")
    text=${text% }
    if [ -n "${1:-}" ] && [[ "$text" == *"$1"* ]]; then
        local before=${text%%"$1"*}
        if [ "${#before}" -gt 20 ]; then
            text="...${text:$((${#before} - 20))}"
        fi
    fi
    if [ "${#text}" -gt 100 ]; then
        text="${text:0:100}..."
    fi
    echo "$text"
}

# expect <description> <expected status> [text the body must contain]
# Checks the last response and shows its body.
expect() {
    local actual=$STATUS
    if [ -n "${3:-}" ] && ! grep -qF -- "$3" "$BODY"; then
        actual="$STATUS without \"$3\" in the body"
    fi
    check "$1" "$2" "$actual" "$(preview "${3:-}")"
}

base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# make_token <header json> <payload json> <secret>
make_token() {
    local data
    data="$(printf '%s' "$1" | base64url).$(printf '%s' "$2" | base64url)"
    printf '%s.%s' "$data" "$(printf '%s' "$data" | openssl dgst -sha256 -hmac "$3" -binary | base64url)"
}

# on_internal <url>
# Sends a request from a throwaway container on the internal network,
# so we can see what that network can and cannot reach.
on_internal() {
    local out
    out=$(docker run --rm --network "${PROJECT}_internal" --entrypoint curl nginx:latest \
        -s -w '\n%{http_code}' --max-time 5 "$1")
    STATUS=${out##*$'\n'}
    printf '%s' "${out%$'\n'*}" > "$BODY"
}

cleanup() {
    section "Stopping services"
    "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1
    rm -rf "$TMP"
    echo "  done"
}

# --- Start ----------------------------------------------------------------

for tool in docker curl openssl; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done

if curl -s -o /dev/null --max-time 2 "$BASE"; then
    echo "Something is already listening on port 80. Stop it first (e.g. 'docker compose down')."
    exit 1
fi

TMP=$(mktemp -d)
BODY=$TMP/body
HEADERS=$TMP/headers
trap cleanup EXIT
trap 'exit 130' INT TERM

section "Starting services"
if ! "${COMPOSE[@]}" up -d >/dev/null 2>&1; then
    echo "  docker compose up failed:"
    "${COMPOSE[@]}" up -d
    exit 1
fi

# Wait until nginx answers (GET /login returns 405 once everything is up).
for _ in $(seq 1 30); do
    request "$BASE/login"
    [ "$STATUS" = "405" ] && break
    sleep 1
done
"${COMPOSE[@]}" ps --format '  {{.Service}}: {{.State}}  {{.Ports}}'

# --- Login ----------------------------------------------------------------

section "Login (POST /login)"
request "$BASE/login"
expect "GET /login is not allowed" 405

request -X POST -d 'hello' "$BASE/login"
expect "body that is not JSON is rejected" 400

request -X POST -d "{\"username\":\"$LOGIN_USERNAME\",\"password\":\"wrong\"}" "$BASE/login"
expect "wrong password is rejected" 401

request -X POST -d "{\"username\":\"nobody\",\"password\":\"$LOGIN_PASSWORD\"}" "$BASE/login"
expect "unknown user is rejected" 401

request -X POST -d "{\"username\":\"$LOGIN_USERNAME\",\"password\":\"$LOGIN_PASSWORD\"}" "$BASE/login"
expect "correct credentials return a token" 200 '"access_token"'
TOKEN=$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' "$BODY")

# --- Requests without a valid token -------------------------------------------

section "Requests without a valid token are blocked"
NOW=$(date +%s)
EXPIRED=$(make_token '{"alg":"HS256","typ":"JWT"}' "{\"sub\":\"x\",\"exp\":$((NOW - 10))}" "$JWT_SECRET")
WRONG_KEY=$(make_token '{"alg":"HS256","typ":"JWT"}' "{\"sub\":\"x\",\"exp\":$((NOW + 60))}" "not-the-secret")
NO_EXP=$(make_token '{"alg":"HS256","typ":"JWT"}' '{"sub":"x"}' "$JWT_SECRET")
ALG_NONE="$(printf '{"alg":"none"}' | base64url).$(printf '{"sub":"x","exp":%d}' $((NOW + 60)) | base64url)."
TAMPERED="${TOKEN%.*}.$(printf 'forged' | base64url)"

request "$BASE/get"
expect "no Authorization header" 401
WWW_AUTH=$(grep -i '^WWW-Authenticate:' "$HEADERS" | tr -d '\r')
check "401 includes 'WWW-Authenticate: Bearer'" yes \
    "$(echo "$WWW_AUTH" | grep -qi 'Bearer' && echo yes || echo no)" "${WWW_AUTH:-(header missing)}"

request -H "Authorization: Basic $TOKEN" "$BASE/get"
expect "Basic auth instead of Bearer" 401

request -H 'Authorization: Bearer abc.def.ghi' "$BASE/get"
expect "random string as token" 401

request -H "Authorization: Bearer $TAMPERED" "$BASE/get"
expect "token with a forged signature" 401

request -H "Authorization: Bearer $WRONG_KEY" "$BASE/get"
expect "token signed with a different secret" 401

request -H "Authorization: Bearer $EXPIRED" "$BASE/get"
expect "expired token" 401

request -H "Authorization: Bearer $NO_EXP" "$BASE/get"
expect "token without an expiry (exp)" 401

request -H "Authorization: Bearer $ALG_NONE" "$BASE/get"
expect "unsigned token (alg: none)" 401

request "$BASE/_auth"
expect "internal /_auth location is hidden" 404

# --- Requests with a valid token ------------------------------------------

section "Requests with a valid token reach httpbin"
AUTH=(-H "Authorization: Bearer $TOKEN")

request "${AUTH[@]}" "$BASE/get?course=web"
expect "GET /get with a query string" 200 '"course"'

request "${AUTH[@]}" -X POST -d 'hello-httpbin' "$BASE/post"
expect "POST body is passed through" 200 'hello-httpbin'

request "${AUTH[@]}" -X DELETE "$BASE/delete"
expect "other methods work (DELETE /delete)" 200

request "${AUTH[@]}" "$BASE/status/418"
expect "status codes from httpbin are kept (/status/418)" 418

request "${AUTH[@]}" "$BASE/"
expect "httpbin home page" 200

# --- Network isolation ----------------------------------------------------

section "httpbin is only reachable through the proxy"
PUBLISHED=$("${COMPOSE[@]}" port httpbin 8081 2>/dev/null)
check "httpbin publishes no ports on the host" none "${PUBLISHED:-none}"

request "http://localhost:8081/get"
expect "host cannot reach localhost:8081" 000

HTTPBIN_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$("${COMPOSE[@]}" ps -q httpbin)")
request "http://$HTTPBIN_IP:8081/get"
expect "host cannot reach httpbin's container IP ($HTTPBIN_IP)" 000

on_internal http://httpbin:8081/get
expect "inside the internal network, httpbin answers" 200

on_internal https://example.com
expect "the internal network has no internet access" 000

# --- Summary --------------------------------------------------------------

section "Result"
total=$((passed + failed))
if [ "$failed" -eq 0 ]; then
    printf '  %sAll %d checks passed.%s\n' "$GREEN" "$total" "$RESET"
else
    printf '  %s%d of %d checks failed.%s\n' "$RED" "$failed" "$total" "$RESET"
fi

[ "$failed" -eq 0 ]
