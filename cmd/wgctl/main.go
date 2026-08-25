package main

import (
	"bufio"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func keyPair() (string, string, error) {
	private := make([]byte, 32)
	if _, err := rand.Read(private); err != nil {
		return "", "", err
	}
	// WireGuard private keys use clamped X25519 scalar bytes.
	private[0] &= 248
	private[31] &= 127
	private[31] |= 64
	curve := ecdh.X25519()
	priv, err := curve.NewPrivateKey(private)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(private), base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes()), nil
}

func decodeKey(encoded string) (string, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil || len(b) != 32 {
		return "", fmt.Errorf("invalid WireGuard key")
	}
	return hex.EncodeToString(b), nil
}

func transact(socket, payload string) (string, error) {
	conn, err := net.Dial("unix", socket)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(payload)); err != nil {
		return "", err
	}
	var lines []string
	s := bufio.NewScanner(conn)
	for s.Scan() {
		line := s.Text()
		lines = append(lines, line)
		if strings.HasPrefix(line, "errno=") {
			break
		}
	}
	if err := s.Err(); err != nil {
		return "", err
	}
	response := strings.Join(lines, "\n")
	if !strings.Contains(response, "errno=0") {
		return response, fmt.Errorf("UAPI rejected request: %s", response)
	}
	return response, nil
}

func configure(args []string) {
	fs := flag.NewFlagSet("configure", flag.ExitOnError)
	socket := fs.String("socket", "", "WireGuard UAPI socket")
	privateFile := fs.String("private-file", "", "server private key file")
	port := fs.Int("port", 51820, "UDP port")
	peersFile := fs.String("peers-file", "", "peer file: name|public_key|address")
	fs.Parse(args)
	if *socket == "" || *privateFile == "" {
		die("--socket and --private-file are required")
	}
	private, err := os.ReadFile(*privateFile)
	if err != nil {
		die("read private key: %v", err)
	}
	privateHex, err := decodeKey(string(private))
	if err != nil {
		die("server private key: %v", err)
	}
	var b strings.Builder
	b.WriteString("set=1\nprivate_key=" + privateHex + "\nlisten_port=" + strconv.Itoa(*port) + "\nreplace_peers=true\n")
	if *peersFile != "" {
		contents, err := os.ReadFile(*peersFile)
		if err != nil && !os.IsNotExist(err) {
			die("read peers: %v", err)
		}
		for _, line := range strings.Split(strings.TrimSpace(string(contents)), "\n") {
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.Split(line, "|")
			if len(parts) != 3 {
				die("invalid peer line")
			}
			publicHex, err := decodeKey(parts[1])
			if err != nil {
				die("peer key: %v", err)
			}
			b.WriteString("public_key=" + publicHex + "\nallowed_ip=" + strings.TrimSpace(parts[2]) + "\n")
		}
	}
	b.WriteString("\n")
	if _, err := transact(*socket, b.String()); err != nil {
		die("configure: %v", err)
	}
}

func nativeConfig(args []string) {
	fs := flag.NewFlagSet("native-config", flag.ExitOnError)
	device := fs.String("device", "wg0", "WireGuard device")
	privateFile := fs.String("private-file", "", "server private key file")
	port := fs.Int("port", 51820, "UDP port")
	peersFile := fs.String("peers-file", "", "peer file: name|public_key|address")
	peerEndpoint := fs.String("peer-endpoint", "", "optional endpoint to apply to configured peers")
	fs.Parse(args)
	if *privateFile == "" {
		die("--private-file is required")
	}
	private, err := os.ReadFile(*privateFile)
	if err != nil {
		die("read private key: %v", err)
	}
	privateKey, err := wgtypes.ParseKey(strings.TrimSpace(string(private)))
	if err != nil {
		die("server private key: %v", err)
	}
	cfg := wgtypes.Config{PrivateKey: &privateKey, ListenPort: port, ReplacePeers: true}
	var endpoint *net.UDPAddr
	if *peerEndpoint != "" {
		endpoint, err = net.ResolveUDPAddr("udp", *peerEndpoint)
		if err != nil {
			die("peer endpoint: %v", err)
		}
	}
	if *peersFile != "" {
		contents, err := os.ReadFile(*peersFile)
		if err != nil && !os.IsNotExist(err) {
			die("read peers: %v", err)
		}
		for _, line := range strings.Split(strings.TrimSpace(string(contents)), "\n") {
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.Split(line, "|")
			if len(parts) != 3 {
				die("invalid peer line")
			}
			key, err := wgtypes.ParseKey(strings.TrimSpace(parts[1]))
			if err != nil {
				die("peer key: %v", err)
			}
			_, network, err := net.ParseCIDR(strings.TrimSpace(parts[2]))
			if err != nil {
				die("peer allowed IP: %v", err)
			}
			cfg.Peers = append(cfg.Peers, wgtypes.PeerConfig{PublicKey: key, Endpoint: endpoint, ReplaceAllowedIPs: true, AllowedIPs: []net.IPNet{*network}})
		}
	}
	c, err := wgctrl.New()
	if err != nil {
		die("open native WireGuard control: %v", err)
	}
	defer c.Close()
	if err := c.ConfigureDevice(*device, cfg); err != nil {
		die("configure native WireGuard: %v", err)
	}
}

func nativeStatus(args []string) {
	fs := flag.NewFlagSet("native-status", flag.ExitOnError)
	device := fs.String("device", "wg0", "WireGuard device")
	fs.Parse(args)
	c, err := wgctrl.New()
	if err != nil {
		die("open native WireGuard control: %v", err)
	}
	defer c.Close()
	d, err := c.Device(*device)
	if err != nil {
		die("read native WireGuard: %v", err)
	}
	fmt.Printf("interface=%s\nlisten_port=%d\n", d.Name, d.ListenPort)
	for _, p := range d.Peers {
		fmt.Printf("public_key=%x\nlast_handshake_time_sec=%d\nrx_bytes=%d\ntx_bytes=%d\n", p.PublicKey[:], p.LastHandshakeTime.Unix(), p.ReceiveBytes, p.TransmitBytes)
	}
	fmt.Println("errno=0")
}

func status(args []string) {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	socket := fs.String("socket", "", "WireGuard UAPI socket")
	fs.Parse(args)
	if *socket == "" {
		die("--socket is required")
	}
	response, err := transact(*socket, "get=1\n\n")
	if err != nil {
		die("status: %v", err)
	}
	// Never expose the server private key through a status command or WebUI.
	for _, line := range strings.Split(response, "\n") {
		if strings.HasPrefix(line, "private_key=") {
			fmt.Println("private_key=(redacted)")
			continue
		}
		fmt.Println(line)
	}
}

func main() {
	if len(os.Args) < 2 {
		die("usage: wgctl keygen|configure|native-config|native-status|status")
	}
	switch os.Args[1] {
	case "keygen":
		private, public, err := keyPair()
		if err != nil {
			die("key generation: %v", err)
		}
		fmt.Printf("private=%s\npublic=%s\n", private, public)
	case "configure":
		configure(os.Args[2:])
	case "native-config":
		nativeConfig(os.Args[2:])
	case "native-status":
		nativeStatus(os.Args[2:])
	case "status":
		status(os.Args[2:])
	default:
		die("unknown command %q", os.Args[1])
	}
}
