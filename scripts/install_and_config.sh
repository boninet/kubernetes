source ./variables.lst

if [ -z $IPAddress ]
then
	exit -1
fi

echo -e "\nStarte allgemeine Vorbereitungsarbeiten...\n"
#########################
#Allgemeine Vorbereitung
#########################
echo "apt update"
sudo apt-get -qq update
sudo apt-get -qq upgrade -y
echo "apt upgrade"
sudo apt-get -qq install mc net-tools apt-transport-https ca-certificates curl -y
echo "installiere ein paar Tools"
sudo apt-get -qq autoremove -y
echo "apt autoremove"
echo "Allgemeine Vorbereitungsarbeiten...OKAY"


########################
#Ggf. IP-Adresse setzen
########################
if [ $SkipSetIp = false ]
then
echo -e "\nSetze IP-Adresse"
cat <<EOF | sudo tee /etc/netplan/00-installer-config.yaml
network:
  ethernets:
    enp0s3:
      addresses: [$IPAddress/24]
      gateway4: $IPAddressGateway
      nameservers:
        addresses: [$IPAddressDNS]
  version: 2
EOF
sudo netplan apply > /dev/null
echo "IP gesetzt"
fi

##################
#Hostnamen setzen
##################
echo -e "\nSetze Hostnamen auf "$Hostname
sudo hostnamectl set-hostname $Hostname
echo "Hostname gesetzt"

####################################
#Firewall starten und konfigurieren
####################################
echo -e "\nStarte und konfiguriere UFW Firewall"
sudo ufw allow "OpenSSH"
sudo ufw enable
if [ $IsControlPlane = true ]
then
	sudo ufw allow 6443/tcp
	sudo ufw allow 2379:2380/tcp
	sudo ufw allow 10250/tcp
	sudo ufw allow 10259/tcp
	sudo ufw allow 10257/tcp
else
	sudo ufw allow 10250/tcp
	sudo ufw allow 30000:32767/tcp
fi
sudo ufw status > /dev/null
echo "Firewall aktiviert"

###########################################
#Notwendige Module laden und konfigurieren
###########################################
echo -e "\nLade und konfiguriere die Module overlay und br_netfilter"
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system > /dev/null
echo "Module geladen und konfiguriert"


###################
#SWAP deaktivieren
###################
echo -e "\nDeaktiviere das SWAP Laufwerk"
sudo sed -i 's/\/swap/#\/swap/g' /etc/fstab
sudo swapoff -a
echo "SWAP deaktiviert"

###################################
#Containerd laden und installieren
###################################
echo -e "\nLade und konfiguriere containerd"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get -qq update
sudo apt-get -qq install -y containerd.io

##########################
#Containerd konfigurieren
##########################
sudo systemctl stop containerd
sudo chmod 777 /etc/containerd/
sudo mv /etc/containerd/config.toml /etc/containerd/config.toml.orig
sudo containerd config default > /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl start containerd
#sudo systemctl is-enabled containerd
echo "containerd bereit"


###################################
#Kubernetes laden und installieren
###################################
echo -e "\nLade und installiere Kubernetes"
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get -qq update
sudo apt-get -qq install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
echo "Kubernetes installiert"

##########################
#Kubernetes konfigurieren
##########################
echo -e "\nKonfiguriere Kubernetes"
if [ $IsControlPlane = true ]
then
	echo "Konfiguration für Control-Plane"
	sudo kubeadm config images pull
	#Flannel laden und vor-konfigurieren
	echo -e "\nLade Flannel"
	sudo mkdir -p /opt/bin/
	sudo curl -fsSLo /opt/bin/flanneld https://github.com/flannel-io/flannel/releases/download/v0.19.0/flanneld-amd64
	sudo chmod +x /opt/bin/flanneld
	echo "Flannel geladen"
	sudo kubeadm init --pod-network-cidr=$PodNetwork --apiserver-advertise-address=$IPAddress --cri-socket=unix:///run/containerd/containerd.sock
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
	kubeadm token generate > $CommonFolder/token
	kubeadm token create `cat $CommonFolder/token` --print-join-command > $CommonFolder/join.sh
	#Flannel konfigurieren
	echo -e "\nKonfiguriere Flannel"
	kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
	echo "Flannel konfiguriert"
else
	echo "Konfiguration für Worker"
	if test -f $CommonFolder/join.sh; then
		sudo chmod +x $CommonFolder/join.sh
		sudo $CommonFolder/join.sh
	fi
fi
echo "Kubernetes konfiguriert"
