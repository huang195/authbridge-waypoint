// echo-tool is a minimal HTTP server that echoes request headers as JSON.
// It acts as the "tool" in the agent→tool flow. The PoC succeeds when this
// service receives a token with aud=echo-tool (exchanged by the waypoint),
// not the agent's original token.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sort"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/echo", handleEcho)
	http.HandleFunc("/healthz", handleHealthz)

	log.Printf("echo-tool listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleEcho(w http.ResponseWriter, r *http.Request) {
	headers := make(map[string]string)
	// Collect all headers, sorted for deterministic output
	keys := make([]string, 0, len(r.Header))
	for k := range r.Header {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		headers[k] = r.Header.Get(k)
	}

	resp := map[string]any{
		"message": "echo-tool received request",
		"method":  r.Method,
		"path":    r.URL.Path,
		"headers": headers,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
