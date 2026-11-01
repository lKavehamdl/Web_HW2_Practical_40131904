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

## ⚠️ Disclaimer

I used AI to create the template.