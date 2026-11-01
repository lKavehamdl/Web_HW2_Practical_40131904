// JWT helpers for the nginx proxy, written for njs (nginx's JavaScript module).
// Tokens are signed with HMAC-SHA256 (HS256) using the shared JWT_SECRET.

const crypto = require('crypto');

const SECRET = process.env.JWT_SECRET;
const TTL = Number(process.env.JWT_TTL) || 3600;
const USERNAME = process.env.LOGIN_USERNAME;
const PASSWORD = process.env.LOGIN_PASSWORD;

function base64url(text) {
    return Buffer.from(text).toString('base64url');
}

function sign(data) {
    return crypto.createHmac('sha256', SECRET).update(data).digest('base64url');
}

function now() {
    return Math.floor(Date.now() / 1000);
}

// Compares two strings in constant time, so the time taken does not reveal
// how many characters of a guessed signature or password were correct.
function safeEqual(a, b) {
    if (a.length !== b.length) {
        return false;
    }
    let diff = 0;
    for (let i = 0; i < a.length; i++) {
        diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return diff === 0;
}

function createToken(subject) {
    const issuedAt = now();
    const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const payload = base64url(JSON.stringify({ sub: subject, iat: issuedAt, exp: issuedAt + TTL }));
    return `${header}.${payload}.${sign(`${header}.${payload}`)}`;
}

// Returns true only for a well-formed, correctly signed, unexpired HS256 token.
function isValidToken(token) {
    const parts = token.split('.');
    if (parts.length !== 3) {
        return false;
    }
    const header = parts[0];
    const payload = parts[1];
    const signature = parts[2];

    if (!safeEqual(signature, sign(`${header}.${payload}`))) {
        return false;
    }

    try {
        // Reject any other algorithm, e.g. "none", which would skip the signature.
        if (JSON.parse(Buffer.from(header, 'base64url').toString()).alg !== 'HS256') {
            return false;
        }
        const claims = JSON.parse(Buffer.from(payload, 'base64url').toString());
        return typeof claims.exp === 'number' && claims.exp > now();
    } catch (e) {
        return false;
    }
}

function sendJson(r, status, body) {
    r.headersOut['Content-Type'] = 'application/json';
    r.return(status, JSON.stringify(body) + '\n');
}

// Handler for the internal auth_request location: 204 lets the request
// through to httpbin, 401 makes nginx reject it.
function verify(r) {
    const auth = r.headersIn['Authorization'] || '';
    const match = auth.match(/^Bearer (\S+)$/);

    if (match && isValidToken(match[1])) {
        r.return(204);
    } else {
        r.headersOut['WWW-Authenticate'] = 'Bearer';
        r.return(401);
    }
}

// Handler for POST /login: exchanges a username and password for a token.
// Expects a JSON body like {"username": "...", "password": "..."}.
function login(r) {
    if (r.method !== 'POST') {
        r.headersOut['Allow'] = 'POST';
        sendJson(r, 405, { error: 'method not allowed' });
        return;
    }

    let body;
    try {
        body = JSON.parse(r.requestText || '');
    } catch (e) {
        sendJson(r, 400, { error: 'body must be JSON' });
        return;
    }

    const validUser = safeEqual(String(body.username), USERNAME);
    const validPassword = safeEqual(String(body.password), PASSWORD);
    if (!validUser || !validPassword) {
        sendJson(r, 401, { error: 'invalid username or password' });
        return;
    }

    sendJson(r, 200, {
        access_token: createToken(USERNAME),
        token_type: 'Bearer',
        expires_in: TTL,
    });
}

export default { verify, login };
