FROM alpine:3.20

RUN apk add --no-cache bash openssl tzdata zabbix-utils

WORKDIR /app

COPY send_certs.sh /app/send_certs.sh
RUN chmod +x /app/send_certs.sh

ENTRYPOINT ["/app/send_certs.sh"]