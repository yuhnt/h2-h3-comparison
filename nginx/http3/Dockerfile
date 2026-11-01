# Use nginx with HTTP/3 support
# Note: nginx:mainline-alpine includes HTTP/3 support in recent versions
FROM nginx:mainline-alpine

# Install dependencies for HTTP/3 support, debugging, health checks, and network simulation
# (iproute2 = tc/netem, ethtool = turn off TSO/GSO so netem sees real packets).
# netem itself is a kernel feature: the Docker host kernel must provide sch_netem.
RUN apk add --no-cache openssl curl net-tools lsof procps bc netcat-openbsd iproute2 ethtool

# Copy custom nginx configuration
COPY nginx/http3/nginx.conf /etc/nginx/nginx.conf

# Create directories for certificates and web content
RUN mkdir -p /etc/nginx/certs /usr/share/nginx/html

# Expose HTTPS and QUIC/UDP ports
EXPOSE 8444
EXPOSE 8444/udp

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -k -f https://localhost:8444/health || exit 1

# Start nginx
CMD ["nginx", "-g", "daemon off;"]