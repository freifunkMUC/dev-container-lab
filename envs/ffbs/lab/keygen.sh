#!/bin/bash
# Makes the lab keys of the ffbs environment: the WireGuard key pairs, the
# signify pair that signs the node configuration, and the etcd CA with its
# certificates. These keys are for this lab only. They are not secret.
#
# The signify pair and the etcd files go into files/. They are not in git.
# The build makes them when they are missing ("keygen.sh signify" needs
# signify-openbsd, "keygen.sh etcd" needs openssl). The script prints the
# WireGuard keys: put them into host_vars/ and internet/ by hand.
#
# Needs wg, signify-openbsd and openssl. To run it in a container:
#   docker run --rm -v "$PWD":/w -w /w debian:bookworm-slim sh -c \
#     'apt-get update -q && apt-get install -qy wireguard-tools signify-openbsd openssl >/dev/null && envs/ffbs/lab/keygen.sh'

set -eu
cd "$(dirname "$0")"

mode="${1:-all}"

if [ "$mode" = all ]; then
	for h in concentrator1 concentrator2 concentrator3 exit1 internet; do
		key=$(wg genkey)
		echo "$h: private $key public $(echo "$key" | wg pubkey)"
	done
fi

if [ "$mode" = all ] || [ "$mode" = signify ]; then
	mkdir -p files
	rm -f files/node-config.sec files/node-config.pub
	signify-openbsd -G -n -c "ffbs lab node config" -s files/node-config.sec -p files/node-config.pub
	echo "CONFIGPUBKEY: $(sed -n 2p files/node-config.pub)"
fi

[ "$mode" = all ] || [ "$mode" = etcd ] || exit 0

ca=$(mktemp -d)
trap 'rm -rf "$ca"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/O=ffbs lab/CN=etcd CA" \
	-keyout "$ca/ca.key" -out files/etcd-ca.pem 2>/dev/null

# cert HOST KIND IP, KIND is server or client
cert() {
	local ext="$ca/$1-$2.ext"
	printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:%s,IP:127.0.0.1\n' "$3" > "$ext"
	mkdir -p "files/$1"
	openssl req -newkey rsa:2048 -nodes -subj "/O=ffbs lab/CN=$1" \
		-keyout "files/$1/etcd-$2.key.pem" -out "$ca/$1-$2.csr" 2>/dev/null
	openssl x509 -req -in "$ca/$1-$2.csr" -CA files/etcd-ca.pem -CAkey "$ca/ca.key" \
		-CAcreateserial -CAserial "$ca/ca.srl" -days 36500 -extfile "$ext" -out "files/$1/etcd-$2.cert.pem" 2>/dev/null
}

for n in 1 2 3; do
	cert "concentrator$n" server "172.16.1.$n"
	cert "concentrator$n" client "172.16.1.$n"
done
