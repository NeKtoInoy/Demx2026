cat > deploy.sh << 'CONF'
#!/bin/bash

ROLE=$1

if [ -z "$ROLE" ]; then
    echo "Использование: ./deploy.sh [ISP|BR-RTR|HQ-RTR|HQ-SRV|BR-SRV]"
    exit 1
fi

case $ROLE in
    "ISP")
        echo ">>> Настройка ISP..."
        hostnamectl set-hostname ISP
        mkdir -p /etc/net/ifaces/enp7s{2,3}
        echo 'TYPE=eth' | tee /etc/net/ifaces/enp7s2/options /etc/net/ifaces/enp7s3/options > /dev/null
        echo '172.16.1.1/28' > /etc/net/ifaces/enp7s2/ipv4address
        echo '172.16.2.1/28' > /etc/net/ifaces/enp7s3/ipv4address
        
        apt-get update && apt-get install nftables -y

cat << 'EOF_ISP' > /etc/nftables/nftables.nft
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "enp7s1" masquerade
    }
}
EOF_ISP

        systemctl enable --now nftables
        sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
        sysctl -w net.ipv4.ip_forward=1
        systemctl restart network
        ;;

    "BR-RTR")
        echo ">>> Настройка BR-RTR..."
        hostnamectl set-hostname br-rtr.au-team.irpo
        mkdir -p /etc/net/ifaces/{enp7s1,enp7s2,gre1}
        echo 'TYPE=eth' | tee /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options > /dev/null
        
        echo '172.16.2.2/28' > /etc/net/ifaces/enp7s1/ipv4address
        echo 'default via 172.16.2.1' > /etc/net/ifaces/enp7s1/ipv4route
        echo 'nameserver 8.8.8.8' > /etc/net/ifaces/enp7s1/resolv.conf
        echo '192.168.3.1/28' > /etc/net/ifaces/enp7s2/ipv4address
        
        sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
        sysctl -w net.ipv4.ip_forward=1

cat << 'EOF_GRE' > /etc/net/ifaces/gre1/options
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNTTL=64
TUNOPTIONS='ttl 64'
EOF_GRE

        echo "10.10.10.2/30" > /etc/net/ifaces/gre1/ipv4address
        systemctl restart network
        apt-get update && apt-get install sudo tzdata frr nftables -y
        
        rm -f /etc/net/ifaces/enp7s1/resolv.conf
        echo -e "search au-team.irpo\nnameserver 192.168.100.2" > /etc/net/ifaces/enp7s2/resolv.conf

cat << 'EOF_NFT' > /etc/nftables/nftables.nft
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "enp7s1" masquerade
    }
}
EOF_NFT

        timedatectl set-timezone Europe/Moscow
        useradd net_admin || true
        echo "net_admin:P@ssw0rd" | chpasswd
        usermod -aG wheel net_admin
        echo "WHEEL_USERS ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
        
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons

cat << 'EOF_FRR' > /etc/frr/frr.conf
interface gre1
 ip ospf area 0
 ip ospf authentication
 ip ospf authentication-key P@ssw0rd
 no ip ospf passive
!
interface enp7s2
 ip ospf area 0
!
router ospf
 passive-interface default
!
EOF_FRR

        systemctl restart network
        systemctl enable --now nftables frr
	echo "-----Проверка-----"
	cat /etc/resolv.conf
	ip r
        ;;

    "HQ-RTR")
        echo ">>> Настройка HQ-RTR..."
        hostnamectl set-hostname hq-rtr.au-team.irpo

        # Сетевые интерфейсы и VLAN
        mkdir -p /etc/net/ifaces/{enp7s{1,2},vlan100,vlan200,vlan999,gre1}
        echo 'TYPE=eth' | tee /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options > /dev/null

        # Внешний линк к ISP
        echo '172.16.1.2/28' > /etc/net/ifaces/enp7s1/ipv4address
        echo 'default via 172.16.1.1' > /etc/net/ifaces/enp7s1/ipv4route
        echo 'nameserver 8.8.8.8' > /etc/net/ifaces/enp7s1/resolv.conf

        # Настройка VLAN через xargs
        echo $'100\n200\n999' | xargs -i bash -c 'echo -e "TYPE=vlan\nHOST=enp7s2\nVID={}" > /etc/net/ifaces/vlan{}/options'
        
        echo '192.168.100.1/27' > /etc/net/ifaces/vlan100/ipv4address
        echo '192.168.200.1/28' > /etc/net/ifaces/vlan200/ipv4address
        echo '192.168.99.1/29' > /etc/net/ifaces/vlan999/ipv4address

        # Форвардинг
        sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
        sysctl -w net.ipv4.ip_forward=1

        # Настройка GRE
cat << 'EOF_HQ_GRE' > /etc/net/ifaces/gre1/options
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNOPTIONS='ttl 64'
EOF_HQ_GRE

        echo "10.10.10.1/30" > /etc/net/ifaces/gre1/ipv4address
        systemctl restart network

        # Установка ПО
        apt-get update && apt-get install sudo tzdata frr dnsmasq nftables -y

        # DNS и NAT
        rm -f /etc/net/ifaces/enp7s1/resolv.conf
        echo -e "search au-team.irpo\nnameserver 192.168.100.2" > /etc/net/ifaces/vlan100/resolv.conf

cat << 'EOF_HQ_NFT' > /etc/nftables/nftables.nft
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "enp7s1" masquerade
    }
}
EOF_HQ_NFT

        systemctl enable --now nftables

        # Timezone и net_admin
        timedatectl set-timezone Europe/Moscow
        useradd net_admin || true
        echo "net_admin:P@ssw0rd" | chpasswd
        usermod -aG wheel net_admin
        echo "WHEEL_USERS ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin

        # Настройка OSPF
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
cat << 'EOF_HQ_FRR' > /etc/frr/frr.conf
interface gre1
 ip ospf area 0
 ip ospf authentication
 ip ospf authentication-key P@ssw0rd
 no ip ospf passive
!
interface vlan100
 ip ospf area 0
!
interface vlan200
 ip ospf area 0
!
interface vlan999
 ip ospf area 0
!
router ospf
 passive-interface default
!
EOF_HQ_FRR

        # Настройка DHCP (dnsmasq)
        sed -i 's/AUTO_LOCAL_RESOLVER=yes/AUTO_LOCAL_RESOLVER=no/' /etc/sysconfig/dnsmasq
cat << 'EOF_HQ_DHCP' > /etc/dnsmasq.conf
port=0
interface=vlan200
listen-address=192.168.200.1
dhcp-authoritative
dhcp-range=interface:vlan200,192.168.200.2,192.168.200.2,255.255.255.240,6h
dhcp-option=3,192.168.200.1
dhcp-option=6,192.168.100.2
leasefile-ro
EOF_HQ_DHCP

        systemctl enable --now frr dnsmasq
        systemctl restart network
        echo ">>> HQ-RTR настроен. Проверка OSPF соседей:"
        vtysh -c "show ip ospf neighbor"
        ;;

    "HQ-SRV")
	echo ">>> Настройка HQ-SRV..."

	hostnamectl hostname HQ-SRV.au-team.irpo
	timedatectl set-timezone Europe/Moscow

	echo 'TYPE=eth\nONBOOT=yes' > /etc/net/ifaces/enp7s1/options

	mkdir -p /etc/net/ifaces/enp7s1.100
	cat > /etc/net/ifaces/enp7s1.100/options << EOF_VLAN
TYPE=vlan
HOST=enp7s1
VID=100
ONBOOT=yes
EOF_VLAN
	echo '192.168.100.2/27' > /etc/net/ifaces/enp7s1.100/ipv4address
	echo 'default via 192.168.100.1' > /etc/net/ifaces/enp7s1.100/ipv4route
	echo 'nameserver 8.8.8.8' > /etc/net/ifaces/enp7s1.100/resolv.conf
	systemctl restart network
	
	useradd -u 2026 sshuser
	echo "sshuser:P@ssw0rd" | chpasswd
	usermod -aG wheel sshuser
	echo "WHEEL_USERS ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

	echo "Authorized access only" > /etc/openssh/banner
	echo -e "Port 2026\nMaxAuthTries 2\nAllowUsers sshuser\nBanner /etc/openssh/banner\n" >> /etc/openssh/sshd_config
	systemctl restart sshd

	apt-get update && apt-get install bind bind-utils -y

	echo $'search au-team.irpo\nnameserver 127.0.0.1' > /etc/net/ifaces/enp7s1/resolv.conf
	
	chown -R root:named /etc/bind/zone && chmod -R 644 /etc/bind/zone
	
	rndc-confgen -a -c /etc/bind/rndc.key
	chmod 640 /etc/bind/rndc.key

	cat <<'EOF' > /etc/bind/options.conf
logging { };
options {
 listen-on { localnets; 127.0.0.1; };
 forwarders { 77.88.8.7; 77.88.8.3; };
 recursion yes;
 allow-recursion { any; };
 allow-query { any; };
 dnssec-validation no;

	chmod 755 /etc/bind/zone
	chmod 644 /etc/bind/zone/*
 
 directory "/etc/bind/zone";
 dump-file "/var/run/named/named_dump.db";
 statistics-file "/var/run/named/named.stats";
 recursing-file "/var/run/named/named.recursing"; 
 secroots-file "/var/run/named/named.scroots";
 pid-file none;
};
zone "au-team.irpo" {
 type master;
 file "au-team.irpo";
};
zone "168.192.in-addr.arpa" {
 type master;
 file "168.192.in-addr.arpa";
};
EOF

cat <<'EOF' > /etc/bind/zone/au-team.irpo
$TTL  1D
@    IN   SOA   au-team.irpo. root.au-team.irpo. (
                2025020600 ; serial
                12H        ; refresh
                1H         ; retry
                1W         ; expire
                1H         ; ncache
            )
@       IN  NS    hq-srv.au-team.irpo.
hq-rtr  IN   A    192.168.100.1
hq-srv  IN   A    192.168.100.2
hq-cli  IN   A    192.168.200.2
br-rtr  IN   A    192.168.3.1
br-srv  IN   A    192.168.3.2
docker  IN   A    172.16.1.1
web     IN   A    172.16.2.1
EOF

cat <<'EOF' > /etc/bind/zone/168.192.in-addr.arpa
$TTL  1D
@    IN   SOA   au-team.irpo. root.au-team.irpo. (
                2025020600 ; serial
                12H        ; refresh
                1H         ; retry
                1W         ; expire
                1H         ; ncache
            )
      IN   NS    au-team.irpo.
1.100 IN   PTR   hq-rtr.au-team.irpo.
2.100 IN   PTR   hq-srv.au-team.irpo.
2.200 IN   PTR   hq-cli.au-team.irpo.
EOF

	chown :named /etc/bind/zone/au-team.irpo /etc/bind/zone/168.192.in-addr.arpa
	systemctl enable --now bind

	service network restart
	host br-rtr
	host -t PTR 192.168.100.2
	
	echo"Проверка..."
	named-checkzone au-team.irpo /etc/bind/zone/au-team.irpo
	named-checkzone 168.192.in-addr.arpa /etc/bind/zone/168.192.in-addr.arpa
        ;;

    "BR-SRV")
	echo ">>> Настройка BR-SRV..."
        hostnamectl set-hostname BR-SRV.au-team.irpo
        timedatectl set-timezone Europe/Moscow

        mkdir -p /etc/net/ifaces/enp7s1
        # Настройка параметров интерфейса
        echo -e 'TYPE=eth\nONBOOT=yes' > /etc/net/ifaces/enp7s1/options
        
        # IP адрес (маска /28 или /26 — проверь задание, обычно /28 для серверов)
        echo '192.168.3.2/28' > /etc/net/ifaces/enp7s1/ipv4address
        
        # ШЛЮЗ — должен быть адресом BR-RTR в этой сети
        echo 'default via 192.168.3.1' > /etc/net/ifaces/enp7s1/ipv4route
        
        # DNS — HQ-SRV
        echo -e 'search au-team.irpo\nnameserver 192.168.100.2' > /etc/net/ifaces/enp7s1/resolv.conf
        
        systemctl restart network

        # Пользователь и SSH
        useradd -u 2026 sshuser || true
        echo "sshuser:P@ssw0rd" | chpasswd
        usermod -aG wheel sshuser
        echo "WHEEL_USERS ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

        echo "Authorized access only" > /etc/openssh/banner
        # Очистка и запись конфига SSH
        sed -i '/Port /d; /AllowUsers /d; /Banner /d' /etc/openssh/sshd_config
        echo -e "Port 2026\nMaxAuthTries 2\nAllowUsers sshuser\nBanner /etc/openssh/banner" >> /etc/openssh/sshd_config
        
        systemctl restart sshd
        echo ">>> SSH запущен на порту:"
        ss -ltnp | grep sshd
        
        echo ">>> Проверка связи до шлюза:"
        ping -c 3 192.168.3.1
        ;;

    *)
        echo "Неверная роль!"
        exit 1
        ;;
esac

systemctl restart network
echo "Сеть перезагружена. Проверка адресов:"
ip -br a

CONF
chmod +x deploy.sh
