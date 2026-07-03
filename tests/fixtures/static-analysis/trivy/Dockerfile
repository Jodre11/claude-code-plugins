FROM alpine:latest

RUN apk add --no-cache curl

COPY app /app

EXPOSE 22

ENV API_KEY=supersecret123

USER appuser

ENTRYPOINT ["/app/run"]
