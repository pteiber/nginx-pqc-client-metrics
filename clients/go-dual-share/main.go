package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"
)

type logLine struct {
	Client    string  `json:"client"`
	Ts        string  `json:"ts"`
	Curve     string  `json:"curve"`
	HRR       bool    `json:"hrr"`
	LatencyMs float64 `json:"latency_ms"`
	Error     *string `json:"error"`
}

func attempt(client *http.Client, host string) {
	url := fmt.Sprintf("https://%s/handshake-info", host)
	start := time.Now()

	var errStr *string
	curve := "unknown"

	resp, err := client.Get(url) //nolint:noctx
	elapsed := time.Since(start).Seconds() * 1000

	if err != nil {
		s := err.Error()
		errStr = &s
	} else {
		defer resp.Body.Close()
		// NGINX returns {"ssl_protocol":…,"ssl_cipher":…,"ssl_curve":…}
		// ssl_curve is the authoritative source since Go stdlib does not expose
		// the negotiated group in tls.ConnectionState.
		var info map[string]string
		if json.NewDecoder(resp.Body).Decode(&info) == nil {
			if c := info["ssl_curve"]; c != "" {
				curve = c
			}
		}
	}

	line := logLine{
		Client:    "go-dual-share",
		Ts:        time.Now().UTC().Format(time.RFC3339),
		Curve:     curve,
		HRR:       false, // Go stdlib does not expose HRR via ConnectionState
		LatencyMs: elapsed,
		Error:     errStr,
	}
	b, _ := json.Marshal(line)
	fmt.Println(string(b))
}

func main() {
	host := getenv("SERVER_HOST", "nginx")
	minInterval := getDuration("MIN_INTERVAL_SECONDS", 5)
	maxInterval := getDuration("MAX_INTERVAL_SECONDS", 15)

	// Nil CurvePreferences → Go 1.24 default: send X25519MLKEM768 + X25519 key shares
	transport := &http.Transport{
		DisableKeepAlives: true,
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, //nolint:gosec // demo: self-signed cert
		},
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}

	// The global math/rand source is auto-seeded from OS entropy at process
	// start (Go 1.20+), so replica pods starting simultaneously still get
	// independent sequences, no manual per-pod seeding needed, unlike the
	// shell-script clients where BusyBox awk's time-only srand() collides.
	for {
		attempt(client, host)
		time.Sleep(randomInterval(minInterval, maxInterval))
	}
}

func randomInterval(min, max time.Duration) time.Duration {
	if max <= min {
		return min
	}
	return min + time.Duration(rand.Int63n(int64(max-min+time.Second)))
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getDuration(key string, defSec int) time.Duration {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return time.Duration(n) * time.Second
		}
	}
	return time.Duration(defSec) * time.Second
}
