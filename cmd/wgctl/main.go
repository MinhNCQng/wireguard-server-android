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
		die("usage: wgctl keygen|configure|status")
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
	case "status":
		status(os.Args[2:])
	default:
		die("unknown command %q", os.Args[1])
	}
}
