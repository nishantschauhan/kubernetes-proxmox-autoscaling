
set -e

echo "[thesis] Starting FreeBSD edge gateway bootstrap"

# --- Install FRR (BGP) + HAProxy --------------------------------------------
env ASSUME_ALWAYS_YES=yes pkg bootstrap -f >/dev/null 2>&1 || true
pkg install -y frr9 haproxy


sysrc -f /usr/local/etc/frr/daemons zebra=yes
sysrc -f /usr/local/etc/frr/daemons bgpd=yes

mkdir -p /usr/local/etc/frr
cat > /usr/local/etc/frr/frr.conf << 'FRRCONF'
frr version 9.1
frr defaults traditional
hostname thesis-edge-gw
log file /var/log/frr/frr.log informational
log timestamp precision 3
!
router bgp 64513
 bgp router-id GATEWAY_IP
 no bgp ebgp-requires-policy
 bgp log-neighbor-changes
 !
 neighbor METALLB peer-group
 neighbor METALLB remote-as 64512
 neighbor METALLB timers 3 9
 bgp listen range NODE_NET peer-group METALLB
 !
 address-family ipv4 unicast
  neighbor METALLB activate
  neighbor METALLB soft-reconfiguration inbound
  neighbor METALLB prefix-list ONLY-SERVICE-POOL in
 exit-address-family
!
ip prefix-list ONLY-SERVICE-POOL seq 10 permit SERVICE_NET le 32
ip prefix-list ONLY-SERVICE-POOL seq 99 deny any
!
line vty
!
FRRCONF
sed -i '' \
  -e "s|GATEWAY_IP|${gateway_ip}|" \
  -e "s|NODE_NET|${node_ip_base}.0/22|" \
  -e "s|SERVICE_NET|192.168.67.240/29|" \
  /usr/local/etc/frr/frr.conf
chown -R frr:frr /usr/local/etc/frr

# --- HAProxy: static pre-declared backend slots -----------------------------
mkdir -p /usr/local/etc
cat > /usr/local/etc/haproxy.conf << 'HAPROXYCONF'
global
    log /var/run/log local0 info
    maxconn 20000
    daemon
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    option  redispatch
    retries 3
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    timeout http-request 10s

listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 5s
    stats show-node

frontend web_in
    bind *:80
    default_backend k8s_workers

backend k8s_workers
    balance roundrobin
    option httpchk GET /
    http-check expect status 200

    # Static, pre-declared slots (see adaptation note #2 at the top of the
    # script this config was generated from) — one per possible worker
    # offset up to pending_watcher.py's MAX_NODES ceiling. Slots for workers
    # that don't exist yet simply fail their healthcheck until provisioned.
    server worker0 NODE_IP_BASE.160:30080 check
    server worker1 NODE_IP_BASE.161:30080 check
    server worker2 NODE_IP_BASE.162:30080 check
    server worker3 NODE_IP_BASE.163:30080 check
    server worker4 NODE_IP_BASE.164:30080 check
    server worker5 NODE_IP_BASE.165:30080 check
HAPROXYCONF
sed -i '' -e "s|NODE_IP_BASE|${node_ip_base}|g" /usr/local/etc/haproxy.conf

# --- PF: default-deny perimeter, single-NIC lab topology --------------------
cat > /etc/pf.conf << 'PFCONF'
ext_if  = "vtnet0"
int_if  = "vtnet0"
node_net    = "NODE_NET"
service_net = "SERVICE_NET"
proxmox_mgmt = "PROXMOX_MGMT_IP"
admin_net   = "NODE_NET"

table <bruteforce> persist

set skip on lo0
set block-policy drop
set loginterface $ext_if
scrub in all fragment reassemble

block in log all
block out log all

pass out quick on $ext_if all keep state

block quick from <bruteforce>

pass in quick on $ext_if proto tcp to $service_net port { 80, 443 } \
     flags S/SA keep state

pass in quick on $ext_if proto tcp from $admin_net to ($ext_if) port 22 \
     flags S/SA keep state \
     (max-src-conn 10, max-src-conn-rate 5/30, overload <bruteforce> flush global)

pass in quick on $ext_if inet proto icmp icmp-type echoreq keep state

pass in quick on $int_if proto tcp from $node_net to ($int_if) port 179 \
     flags S/SA keep state

pass out quick on $int_if proto tcp from ($int_if) to $node_net \
     keep state

pass in quick on $int_if proto tcp from $admin_net to $proxmox_mgmt port 8006 \
     flags S/SA keep state

pass in quick on $int_if proto tcp from $admin_net to $node_net port 6443 \
     flags S/SA keep state

pass quick on $int_if from $node_net to $node_net keep state
PFCONF
sed -i '' \
  -e "s|NODE_NET|${node_ip_base}.0/22|g" \
  -e "s|SERVICE_NET|192.168.67.240/29|" \
  -e "s|PROXMOX_MGMT_IP|${proxmox_mgmt_ip}|" \
  /etc/pf.conf

# --- Enable and start everything --------------------------------------------
sysrc frr_enable=YES
sysrc haproxy_enable=YES
sysrc pf_enable=YES

service frr start
service haproxy start
service pf start

echo "[thesis] FreeBSD edge gateway bootstrap complete"
