#!/bin/bash

# Generate Unbound configuration from blocks.txt
python3 /usr/local/bin/generate_unbound_conf.py

# Check if DOMAIN and EMAIL environment variables are set
if [[ -n "$DOMAIN" && -n "$EMAIL" ]]; then
    apt-get -qq update && apt-get -qq --yes install certbot

    # Obtain Let's Encrypt certificates using certbot
    certbot certonly -n --standalone -d "$DOMAIN" --agree-tos --email "$EMAIL"
else
    echo "DOMAIN and EMAIL environment variables are not set. Skipping certificate generation."
fi

reserved=12582912
availableMemory=$((1024 * $( (grep MemAvailable /proc/meminfo || grep MemTotal /proc/meminfo) | sed 's/[^0-9]//g' ) ))
memoryLimit=$availableMemory
[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && memoryLimit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes | sed 's/[^0-9]//g')
[[ ! -z $memoryLimit && $memoryLimit -gt 0 && $memoryLimit -lt $availableMemory ]] && availableMemory=$memoryLimit
if [ $availableMemory -le $(($reserved * 2)) ]; then
    echo "Not enough memory" >&2
    exit 1
fi
availableMemory=$(($availableMemory - $reserved))
rr_cache_size=$(($availableMemory / 3))
# Use roughly twice as much rrset cache memory as msg cache memory
msg_cache_size=$(($rr_cache_size / 2))
nproc=$(nproc)
export nproc
if [ "$nproc" -gt 1 ]; then
    threads=$((nproc - 1))
    # Calculate base 2 log of the number of processors
    nproc_log=$(perl -e 'printf "%5.5f\n", log($ENV{nproc})/log(2);')

    # Round the logarithm to an integer
    rounded_nproc_log="$(printf '%.*f\n' 0 "$nproc_log")"

    # Set *-slabs to a power of 2 close to the num-threads value.
    # This reduces lock contention.
    slabs=$(( 2 ** rounded_nproc_log ))
else
    threads=1
    slabs=4
fi

if [ ! -f /opt/unbound/etc/unbound/unbound.conf ]; then
    sed \
        -e "s/@MSG_CACHE_SIZE@/${msg_cache_size}/" \
        -e "s/@RR_CACHE_SIZE@/${rr_cache_size}/" \
        -e "s/@THREADS@/${threads}/" \
        -e "s/@SLABS@/${slabs}/" \
        > /opt/unbound/etc/unbound/unbound.conf << EOT
server:
    ###########################################################################
    # BASIC SETTINGS
    ###########################################################################
    cache-max-ttl: 86400
    cache-min-ttl: 300
    directory: "/opt/unbound/etc/unbound"
    ede: yes
    ede-serve-expired: yes
    edns-buffer-size: 1232
    interface: 0.0.0.0@53
    rrset-roundrobin: yes
    username: "_unbound"

    ###########################################################################
    # LOGGING
    ###########################################################################
    log-local-actions: no
    log-queries: no
    log-replies: no
    log-servfail: no
    logfile: ""
    verbosity: 1

    ###########################################################################
    # PRIVACY SETTINGS
    ###########################################################################
    aggressive-nsec: yes
    delay-close: 10000
    do-daemonize: no
    do-not-query-localhost: no
    neg-cache-size: 4M
    qname-minimisation: yes

    ###########################################################################
    # SECURITY SETTINGS
    ###########################################################################
    # Restrict access to your DNS server. Modify to allow necessary IPs.
    access-control: 127.0.0.1/32 allow
    access-control: 0.0.0.0/0 allow  # Allow all public IPs (use with caution)
    auto-trust-anchor-file: "var/root.key"
    chroot: "/opt/unbound/etc/unbound"
    deny-any: yes
    harden-algo-downgrade: yes
    harden-unknown-additional: yes
    harden-below-nxdomain: yes
    harden-dnssec-stripped: yes
    harden-glue: yes
    harden-large-queries: yes
    harden-referral-path: no
    harden-short-bufsize: yes
    hide-http-user-agent: no
    hide-identity: yes
    hide-version: yes
    http-user-agent: "DNS"
    identity: "DNS"
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    ratelimit: 1000
    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt
    unwanted-reply-threshold: 10000
    use-caps-for-id: yes
    val-clean-additional: yes

    ###########################################################################
    # PERFORMANCE SETTINGS
    ###########################################################################
    infra-cache-slabs: @SLABS@
    incoming-num-tcp: 10
    key-cache-slabs: @SLABS@
    msg-cache-size: @MSG_CACHE_SIZE@
    msg-cache-slabs: @SLABS@
    num-queries-per-thread: 4096
    num-threads: @THREADS@
    outgoing-range: 8192
    rrset-cache-size: @RR_CACHE_SIZE@
    rrset-cache-slabs: @SLABS@
    minimal-responses: yes
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    sock-queue-timeout: 3
    so-reuseport: yes

    ###########################################################################
    # LOCAL ZONE
    ###########################################################################
    include: /opt/unbound/etc/unbound/a-records.conf
    include: /opt/unbound/etc/unbound/srv-records.conf

    ###########################################################################
    # FORWARD ZONE
    ###########################################################################
    include: /opt/unbound/etc/unbound/forward-records.conf

remote-control:
    control-enable: no
EOT

    if [[ -n "$DOMAIN" && -n "$EMAIL" ]]; then
        cat << EOT >> /opt/unbound/etc/unbound/unbound.conf
        
server:
    ###########################################################################
    # DNS over TLS
    ###########################################################################
    interface: 0.0.0.0@853
    tls-service-key: "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    tls-service-pem: "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    tls-port: 853
EOT
    fi
fi

mkdir -p /opt/unbound/etc/unbound/dev && \
cp -a /dev/random /dev/urandom /dev/null /opt/unbound/etc/unbound/dev/

mkdir -p -m 700 /opt/unbound/etc/unbound/var && \
chown _unbound:_unbound /opt/unbound/etc/unbound/var && \
/opt/unbound/sbin/unbound-anchor -a /opt/unbound/etc/unbound/var/root.key

exec /opt/unbound/sbin/unbound -d -c /opt/unbound/etc/unbound/unbound.conf