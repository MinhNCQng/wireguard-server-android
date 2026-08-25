package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

type app struct{ moddir string }
type status struct {
	Running     bool   `json:"running"`
	WireGuard   string `json:"wireguard"`
	DuckDNS     string `json:"duckdns"`
	LANEndpoint string `json:"lanEndpoint"`
	Endpoint    string `json:"endpoint"`
	DuckEnabled bool   `json:"duckEnabled"`
	LastRun     string `json:"lastRun"`
	PublicIP    string `json:"publicIP"`
	ActivePeers int    `json:"activePeers"`
}

func (a app) run(args ...string) (string, error) {
	c := exec.Command("/system/bin/sh", append([]string{filepath.Join(a.moddir, "scripts/server.sh")}, args...)...)
	b, err := c.CombinedOutput()
	return string(b), err
}
func (a app) data(parts ...string) string {
	return filepath.Join(append([]string{a.moddir, "data"}, parts...)...)
}
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
func errorJSON(w http.ResponseWriter, code int, err error) { http.Error(w, err.Error(), code) }
func (a app) status(w http.ResponseWriter, r *http.Request) {
	out, err := a.run("status")
	port := "51820"
	endpoint := ""
	for _, line := range strings.Split(readTrim(a.data("config", "server.env")), "\n") {
		if strings.HasPrefix(line, "WG_PORT=") {
			port = strings.TrimPrefix(line, "WG_PORT=")
		}
		if strings.HasPrefix(line, "ENDPOINT=") {
			endpoint = strings.TrimPrefix(line, "ENDPOINT=")
		}
	}
	duck := readTrim(a.data("runtime", "duckdns.status"))
	lines := strings.Split(duck, "\n")
	last, publicIP := "", ""
	if len(lines) > 0 {
		last = lines[0]
	}
	if len(lines) > 1 {
		publicIP = lines[1]
	}
	active := 0
	cutoff := time.Now().Add(-3 * time.Minute).Unix()
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "last_handshake_time_sec=") {
			if n, e := strconv.ParseInt(strings.TrimPrefix(line, "last_handshake_time_sec="), 10, 64); e == nil && n >= cutoff {
				active++
			}
		}
	}
	_, duckErr := os.Stat(a.data("config", "duckdns.env"))
	writeJSON(w, status{Running: err == nil && !strings.Contains(out, "status=stopped"), WireGuard: out, DuckDNS: duck, LANEndpoint: localIPv4() + ":" + port, Endpoint: endpoint, DuckEnabled: duckErr == nil, LastRun: last, PublicIP: publicIP, ActivePeers: active})
}

func localIPv4() string {
	c, err := net.Dial("udp4", "1.1.1.1:53")
	if err != nil {
		return ""
	}
	defer c.Close()
	host, _, err := net.SplitHostPort(c.LocalAddr().String())
	if err != nil {
		return ""
	}
	return host
}
func readTrim(path string) string { b, _ := os.ReadFile(path); return strings.TrimSpace(string(b)) }
func (a app) peers(w http.ResponseWriter, r *http.Request) {
	type peer struct {
		Name          string `json:"name"`
		PublicKey     string `json:"publicKey"`
		Address       string `json:"address"`
		Active        bool   `json:"active"`
		LastHandshake int64  `json:"lastHandshake"`
	}
	statusOut, _ := a.run("status")
	handshakes := map[string]int64{}
	currentKey := ""
	for _, line := range strings.Split(statusOut, "\n") {
		if strings.HasPrefix(line, "public_key=") {
			currentKey = strings.TrimPrefix(line, "public_key=")
		}
		if strings.HasPrefix(line, "last_handshake_time_sec=") && currentKey != "" {
			if ts, err := strconv.ParseInt(strings.TrimPrefix(line, "last_handshake_time_sec="), 10, 64); err == nil {
				handshakes[currentKey] = ts
			}
		}
	}
	var result []peer
	for _, l := range strings.Split(readTrim(a.data("config", "peers.txt")), "\n") {
		p := strings.Split(l, "|")
		if len(p) == 3 {
			keyBytes, _ := base64.StdEncoding.DecodeString(p[1])
			keyHex := hex.EncodeToString(keyBytes)
			last := handshakes[keyHex]
			result = append(result, peer{Name: p[0], PublicKey: p[1], Address: p[2], Active: last >= time.Now().Add(-3*time.Minute).Unix(), LastHandshake: last})
		}
	}
	writeJSON(w, result)
}
func (a app) addPeer(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name string `json:"name"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil {
		errorJSON(w, 400, fmt.Errorf("invalid JSON"))
		return
	}
	out, err := a.run("add-peer", body.Name)
	if err != nil {
		errorJSON(w, 400, fmt.Errorf("%s", out))
		return
	}
	writeJSON(w, map[string]string{"config": strings.TrimSpace(out)})
}
func (a app) revoke(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/api/peers/")
	name = strings.TrimSuffix(name, "/revoke")
	out, err := a.run("revoke-peer", name)
	if err != nil {
		errorJSON(w, 400, fmt.Errorf("%s", out))
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
func (a app) config(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/config/"), ".conf")
	b, err := os.ReadFile(a.data("peers", name+".conf"))
	if err != nil {
		errorJSON(w, 404, err)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Disposition", "attachment; filename="+name+".conf")
	w.Write(b)
}
func (a app) qr(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/qr/"), ".png")
	b, err := os.ReadFile(a.data("peers", name+".conf"))
	if err != nil {
		errorJSON(w, 404, err)
		return
	}
	png, err := qrcode.Encode(string(b), qrcode.Medium, 512)
	if err != nil {
		errorJSON(w, 500, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Write(png)
}
func (a app) logs(w http.ResponseWriter, r *http.Request) {
	b, _ := os.ReadFile(a.data("logs", "server.log"))
	if len(b) > 65536 {
		b = b[len(b)-65536:]
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Write(b)
}
func (a app) duckDNS(w http.ResponseWriter, r *http.Request) {
	if r.Method == "DELETE" {
		os.Remove(a.data("config", "duckdns.env"))
		os.Remove(a.data("runtime", "duckdns.status"))
		writeJSON(w, map[string]bool{"ok": true})
		return
	}
	var body struct {
		Domain string `json:"domain"`
		Token  string `json:"token"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil {
		errorJSON(w, 400, fmt.Errorf("invalid JSON"))
		return
	}
	if !validDomain(body.Domain) || len(body.Token) < 10 {
		errorJSON(w, 400, fmt.Errorf("invalid DuckDNS settings"))
		return
	}
	os.MkdirAll(a.data("config"), 0700)
	os.WriteFile(a.data("config", "duckdns.env"), []byte("DOMAIN="+body.Domain+"\nTOKEN="+body.Token+"\n"), 0600)
	a.updateDuckDNS()
	writeJSON(w, map[string]string{"status": readTrim(a.data("runtime", "duckdns.status"))})
}

func (a app) endpoint(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Endpoint string `json:"endpoint"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil {
		errorJSON(w, 400, fmt.Errorf("invalid JSON"))
		return
	}
	if !strings.Contains(body.Endpoint, ":") || strings.ContainsAny(body.Endpoint, " /\\") {
		errorJSON(w, 400, fmt.Errorf("invalid endpoint"))
		return
	}
	out, err := a.run("set-endpoint", body.Endpoint)
	if err != nil {
		errorJSON(w, 400, fmt.Errorf("%s", out))
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
func validDomain(s string) bool {
	if len(s) < 1 || len(s) > 63 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}
func (a app) updateDuckDNS() {
	b, err := os.ReadFile(a.data("config", "duckdns.env"))
	if err != nil {
		return
	}
	vals := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		p := strings.SplitN(l, "=", 2)
		if len(p) == 2 {
			vals[p[0]] = p[1]
		}
	}
	url := "https://www.duckdns.org/update?domains=" + vals["DOMAIN"] + "&token=" + vals["TOKEN"] + "&verbose=true"
	dns := strings.TrimSpace(string(must(exec.Command("/system/bin/getprop", "net.dns1").Output())))
	if dns == "" {
		dns = "1.1.1.1"
	}
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "udp", net.JoinHostPort(dns, "53"))
	}}
	ips, lookupErr := resolver.LookupHost(context.Background(), "www.duckdns.org")
	msg := "ERROR DNS lookup failed"
	if lookupErr == nil && len(ips) > 0 {
		transport := &http.Transport{TLSClientConfig: &tls.Config{ServerName: "www.duckdns.org"}, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort(ips[0], "443"))
		}}
		c := http.Client{Timeout: 20 * time.Second, Transport: transport}
		res, err := c.Get(url)
		msg = "ERROR request failed"
		if err == nil {
			defer res.Body.Close()
			x, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
			msg = strings.TrimSpace(string(x))
			if !strings.HasPrefix(msg, "OK") {
				msg = "ERROR " + msg
			}
		}
	}
	os.MkdirAll(a.data("runtime"), 0700)
	os.WriteFile(a.data("runtime", "duckdns.status"), []byte(time.Now().Format(time.RFC3339)+" "+msg), 0600)
}

func must[T any](v T, _ error) T { return v }

const page = `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>WG Server</title><style>body{font-family:system-ui,sans-serif;margin:20px;background:#f6f8fb;color:#152033}h1{margin-bottom:8px}.card{background:white;border:1px solid #dce3ec;border-radius:12px;padding:16px;margin:14px 0;box-shadow:0 1px 2px #0001}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}.label{font-size:12px;color:#64748b}.value{font-weight:600;overflow-wrap:anywhere}button,input{padding:9px;margin:4px;border:1px solid #b8c4d2;border-radius:7px}button{background:#1267d6;color:white;border:0;cursor:pointer}button.secondary{background:#64748b}pre{background:#0f172a;color:#dbeafe;padding:12px;white-space:pre-wrap;border-radius:8px;max-height:280px;overflow:auto}.peer{padding:8px;border-top:1px solid #e6ebf1}.badge{padding:3px 7px;border-radius:99px;font-size:12px;font-weight:600}.on{background:#dcfce7;color:#166534}.off{background:#e2e8f0;color:#475569}</style><h1>WireGuard Server</h1><div class=card><div class=grid><div><div class=label>Server</div><div class=value id=state>Loading…</div></div><div><div class=label>Configured endpoint</div><div class=value id=currentEndpoint>—</div></div><div><div class=label>Current LAN endpoint</div><div class=value id=lan>—</div></div><div><div class=label>Active clients</div><div class=value id=active>—</div></div><div><div class=label>DuckDNS</div><div class=value id=duckState>—</div></div><div><div class=label>Last run / public IP</div><div class=value id=duckRun>—</div></div></div></div><div class=card><h2>Endpoint</h2><input id=e placeholder="Enter endpoint, e.g. minhmap.duckdns.org:51820" size=36><button onclick="endpoint()">Use endpoint</button><button class=secondary onclick="useLan()">Use current LAN endpoint</button></div><div class=card><h2>Peers</h2><input id=n placeholder="Peer name"><button onclick="add()">Create</button><div id=p></div></div><div class=card><h2>DuckDNS</h2><input id=d placeholder="Subdomain"><input id=t placeholder="Token"><button onclick="duck()">Save / update</button><button class=secondary onclick="disableDuck()">Disable DuckDNS</button></div><div class=card><h2>Log</h2><pre id=l></pre></div><script>let lanEndpoint='';async function j(u,o){let r=await fetch(u,o);if(!r.ok)throw Error(await r.text());return r.json()}async function load(){let x=await j('/api/status');lanEndpoint=x.lanEndpoint;state.textContent=x.running?'Running':'Stopped';currentEndpoint.textContent=x.endpoint||'—';lan.textContent=x.lanEndpoint||'—';active.textContent=x.activePeers;duckState.textContent=x.duckEnabled?'Enabled':'Disabled';duckRun.textContent=x.lastRun?(x.lastRun+' / '+(x.publicIP||'—')):'—';let p=await j('/api/peers');document.querySelector('#p').innerHTML=p.map(x=>'<div class=peer><b>'+x.name+'</b> · '+x.address+' <span class="badge '+(x.active?'on':'off')+'">'+(x.active?'Active':'Inactive')+'</span> <a href="/api/config/'+x.name+'">config</a> <a href="/api/qr/'+x.name+'.png">QR</a> <button onclick="rev(\''+x.name+'\')">revoke</button></div>').join('')||'No peers';l.textContent=await (await fetch('/api/logs')).text()}async function add(){try{await j('/api/peers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n.value})});n.value='';load()}catch(x){alert(x)}}async function rev(n){await j('/api/peers/'+n+'/revoke',{method:'POST'});load()}async function duck(){try{await j('/api/duckdns',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({domain:d.value,token:t.value})});t.value='';load()}catch(x){alert(x)}}async function disableDuck(){await j('/api/duckdns',{method:'DELETE'});load()}function useLan(){e.value=lanEndpoint}async function endpoint(){try{await j('/api/endpoint',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({endpoint:e.value})});load()}catch(x){alert(x)}}load()</script>`

func main() {
	if len(os.Args) != 2 {
		panic("usage: wgpanel MODDIR")
	}
	a := app{os.Args[1]}
	go func() {
		for {
			a.updateDuckDNS()
			time.Sleep(10 * time.Minute)
		}
	}()
	m := http.NewServeMux()
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		io.Copy(w, bytes.NewBufferString(page))
	})
	m.HandleFunc("/api/status", a.status)
	m.HandleFunc("/api/peers", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			a.peers(w, r)
		} else if r.Method == "POST" {
			a.addPeer(w, r)
		} else {
			http.Error(w, "method", 405)
		}
	})
	m.HandleFunc("/api/peers/", a.revoke)
	m.HandleFunc("/api/config/", a.config)
	m.HandleFunc("/api/qr/", a.qr)
	m.HandleFunc("/api/logs", a.logs)
	m.HandleFunc("/api/duckdns", a.duckDNS)
	m.HandleFunc("/api/endpoint", a.endpoint)
	if err := http.ListenAndServe("0.0.0.0:8080", m); err != nil {
		panic(err)
	}
}
