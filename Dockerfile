FROM gcr.io/distroless/static-debian12:nonroot
ARG SERVICE
COPY bin/${SERVICE} /app
ENTRYPOINT ["/app"]
