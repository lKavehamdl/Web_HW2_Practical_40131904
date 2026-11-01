# 📝 Web Programming HW2

> **Author:** Kaveh Ahmadi / lkavehamdl  
> **Date:** Nov 1 2026  


- [Question 1](#question-1)
- [Question 2](#question-2)

- [Disclaimer](#%EF%B8%8F-disclaimer)



---

## Question 1

**Answer:**

There are several ways to do such a thing:

**A:** 

Bind the service to a private IP address. By doing so, the service won't be listening on an address from outside.

**B:**

Use a firewall. By using a firewall, you can drop packets from the outside world, so the service would only answer from inside.

**C:**

Use Docker networks. By setting up the service in such a way that it has no exposed ports, it would only accept packets from a user-defined network.

**D:**

Separate the network, physically or logically. By doing so, there won't be a public IP address to listen from, so the only way to connect is to use a reverse proxy or a VPN.

## Question 2

**Answer:**

TLS termination means the encrypted HTTPS connection from the client ends at the reverse proxy, not at the backend service. The proxy holds the certificate and private key, does the handshake, decrypts the request, and then forwards it to the legacy service, usually as plain HTTP over the internal network.

The idea behind TLS termination is that we don't want to touch the old service, but we still want the connection to be secure. Legacy services often don't support TLS, or only support old and weak versions, and changing their code is risky and expensive. So we let the reverse proxy handle the encryption instead. The most dangerous part of the path is the public internet, where anyone can read or change the traffic, and that's exactly the part TLS protects. It also means certificates and TLS settings are managed in one place instead of on every backend service. And since the proxy has to read the request anyway to check the JWT in the header, it makes sense for it to be the point where the traffic gets decrypted.

The trade-off is that traffic between the proxy and the backend isn't encrypted. If the internal network can't be fully trusted, you can use TLS re-encryption (the proxy opens a new TLS connection to the backend) or mutual TLS. For a legacy service sitting on a private network behind the proxy, plain termination is usually good enough.

## Question 3

**Answer:**

I used **Nginx** as the reverse proxy. Open-source Nginx can't check JWTs on its own (that's only in Nginx Plus), so I wrote the token check in **njs**, the JavaScript module that ships with the official Nginx image.

### How it works

There are two containers, defined in `compose.yaml`:

- **httpbin**: the legacy service. It runs on port 8081, publishes no ports and is only on the `internal` network, so it can't be reached from outside.
- **proxy**: Nginx. It's the only container that publishes a port (80), and it's on both networks so it can forward requests to httpbin.

When a request comes in:

1. `POST /login` with a username and password returns a signed JWT (HS256).
2. Every other request first goes through `auth_request` to an internal location that runs `verify` in `jwt.js`. It checks the `Authorization: Bearer <token>` header, the signature and the expiry time.
3. If the token is valid, the request is forwarded to httpbin. Otherwise Nginx returns `401`.

### Project structure

```
compose.yaml       # httpbin + nginx, and the two networks
nginx/nginx.conf   # proxy config
nginx/jwt.js       # token check and /login
.env.example       # settings template
test.sh            # end-to-end test
```

### How to run

```bash
cp .env.example .env    # then set JWT_SECRET and LOGIN_PASSWORD
docker compose up -d
```

Get a token and use it:

```bash
curl -X POST -d '{"username":"admin","password":"<your password>"}' http://localhost/login
curl -H "Authorization: Bearer <token>" http://localhost/get
```

Without a token, or with an invalid or expired one, you get `401`.

### How to test

```bash
./test.sh
```

The script starts the services, runs all the checks, prints each result with the response it got, and then shuts everything down. It doesn't need a `.env`, but port 80 has to be free. It needs `docker`, `curl` and `openssl`.

It checks that:

- login works only with the right credentials
- requests with no token, or with a wrong, forged, expired or unsigned token, are blocked
- requests with a valid token reach httpbin
- httpbin can't be reached from the host directly, only through the proxy

## ⚠️ Disclaimer

I used AI to create this template and to write test script.