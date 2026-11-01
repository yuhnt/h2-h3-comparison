# Tools for scripts/set-network-condition-linux.sh, so members of the docker group can
# shape the host's network without sudo (run with host networking + NET_ADMIN).
FROM alpine:latest
RUN apk add --no-cache bash iproute2 ethtool
ENTRYPOINT ["/scripts/set-network-condition-linux.sh"]
