FROM nginx:alpine

# Install tools for health checks, monitoring, and network simulation
# (iproute2 = tc/netem, ethtool = turn off TSO/GSO so netem sees real packets).
# netem itself is a kernel feature: the Docker host kernel must provide sch_netem.
RUN apk add --no-cache openssl curl net-tools lsof procps bc iproute2 ethtool

# Copy custom nginx configuration
COPY nginx/http2/nginx.conf /etc/nginx/nginx.conf

# Create directories for certificates and web content
RUN mkdir -p /etc/nginx/certs /usr/share/nginx/html

# Expose HTTPS port
EXPOSE 8443

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -k -f https://localhost:8443/health || exit 1

# Start nginx
CMD ["nginx", "-g", "daemon off;"]