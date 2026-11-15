#!/bin/sh
# LAB PROTOTYPE: the jumps to the reject chain parker_src (see mp-node.sh).
# A fw3 reload removes them. fw3 runs this file after each reload (include
# with reload 1), and mp-node.sh runs it in each cycle.
if ip6tables -w -N parker_src 2>/dev/null; then
	# A new, empty chain: mp-node.sh must write the rules again.
	rm -f /tmp/multipop/chain
fi
for c in FORWARD OUTPUT; do
	ip6tables -w -C "$c" -o wg_c+ -j parker_src 2>/dev/null ||
		ip6tables -w -I "$c" 1 -o wg_c+ -j parker_src
done
