// SPDX-License-Identifier: MIT

//go:build darwin

package main

// The tun and the routing table on macOS. utun needs no entitlement, only
// root: wireguard-go's tun package opens the kernel control socket and the
// kernel hands out the next free utunN. ifconfig/route do the rest, as on the
// FreeBSD stand — with the two differences that matter here: utun is
// point-to-point, so the address takes a destination and the subnet needs
// an explicit interface route; and BSD route on macOS wants -n so it does
// not stall on reverse lookups.

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"golang.zx2c4.com/wireguard/tun"
)

// openTUN creates the interface. On macOS the requested name must be "utun"
// (next free number) or "utunN"; anything else is rejected by wireguard-go.
func openTUN(name string, mtu int) (tun.Device, string, error) {
	if !strings.HasPrefix(name, "utun") {
		name = "utun"
	}
	dev, err := tun.CreateTUN(name, mtu)
	if err != nil {
		return nil, "", fmt.Errorf("create tun: %w", err)
	}
	real, err := dev.Name()
	if err != nil {
		real = name
	}
	return dev, real, nil
}

// configureTUN: address + peer (the first host of the network, which is the
// server side of the WireGuard subnet), MTU, up, and the subnet route through
// the interface so the rest of the /24 is reachable too.
func configureTUN(name, cidr string, mtu int) error {
	ip, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return fmt.Errorf("address %q: %w", cidr, err)
	}
	gw := firstHost(ipnet)
	if err := execCmd("ifconfig", name, "inet", ip.String(), gw.String(), "netmask", net.IP(ipnet.Mask).String(), "mtu", fmt.Sprint(mtu), "up"); err != nil {
		return err
	}
	// A leftover from an earlier run answers "File exists"; change it then.
	if err := execCmd("route", "-q", "-n", "add", "-net", ipnet.String(), "-interface", name); err != nil {
		if err2 := execCmd("route", "-q", "-n", "change", "-net", ipnet.String(), "-interface", name); err2 != nil {
			return err
		}
	}
	return nil
}

func firstHost(n *net.IPNet) net.IP {
	ip := make(net.IP, len(n.IP))
	copy(ip, n.IP)
	ip[len(ip)-1]++
	return ip
}

func addHostRoute(host, gw string) error { return execCmd("route", "-q", "-n", "add", "-host", host, gw) }
func deleteHostRoute(host string) error  { return execCmd("route", "-q", "-n", "delete", "-host", host) }

// defaultGateway reads the current IPv4 default gateway. On a Mac whose
// default route already points at another VPN's utun there is no gateway
// address, only an interface; that is reported, and -default-route refuses
// to stack one tunnel on another.
func defaultGateway() (string, error) {
	out, err := exec.Command("route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("route get default: %v: %s", err, strings.TrimSpace(string(out)))
	}
	var iface string
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		switch f[0] {
		case "gateway:":
			if net.ParseIP(f[1]) != nil {
				return f[1], nil
			}
		case "interface:":
			iface = f[1]
		}
	}
	return "", fmt.Errorf("route get default: no gateway address (default route is on %s — another VPN?)", iface)
}

func setDefaultGateway(gw string) error { return execCmd("route", "-q", "-n", "change", "default", gw) }

func changeHostRoute(host, gw string) error {
	return execCmd("route", "-q", "-n", "change", "-host", host, gw)
}

func execCmd(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// relayHostsFromOS lists the remote hosts THIS process holds TURN sockets to,
// read from lsof (no sockstat on macOS). TCP transport shows them as
// connected sockets; an unconnected UDP socket shows no peer.
func relayHostsFromOS() []string {
	out, err := exec.Command("lsof", "-nP", "-a", "-i4", "-p", strconv.Itoa(os.Getpid())).CombinedOutput()
	if err != nil {
		return nil
	}
	set := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 9 {
			continue
		}
		// NAME is "local->remote" for a connected socket.
		i := strings.Index(f[8], "->")
		if i < 0 {
			continue
		}
		host, port, err := net.SplitHostPort(f[8][i+2:])
		if err != nil {
			continue
		}
		if port == "19302" || port == "3478" {
			set[host] = true
		}
	}
	var hosts []string
	for h := range set {
		hosts = append(hosts, h)
	}
	return hosts
}
