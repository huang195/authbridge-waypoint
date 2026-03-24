// time-tool is a minimal HTTP server that returns the current server time
// along with the JWT claims it received. It acts as a second "tool" in the
// multi-tool demo, proving the waypoint token exchange works for N tools
// with one shared ext_authz service.
package main

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/time", handleTime)
	http.HandleFunc("/healthz", handleHealthz)

	log.Printf("time-tool listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func handleTime(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"message": "time-tool received request",
		"time":    time.Now().UTC().Format(time.RFC3339),
	}

	// Extract and display JWT claims from the Authorization header.
	// No validation here — that's the waypoint's job.
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		token := strings.TrimPrefix(auth, "Bearer ")
		if claims, err := parseJWTClaims(token); err == nil {
			resp["token_aud"] = claims["aud"]
			resp["token_sub"] = claims["sub"]
			resp["token_azp"] = claims["azp"]
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// parseJWTClaims extracts the payload from a JWT without validating it.
func parseJWTClaims(token string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, nil
	}

	// Decode base64url payload
	payload := parts[1]
	// Add padding if needed
	switch len(payload) % 4 {
	case 2:
		payload += "=="
	case 3:
		payload += "="
	}

	decoded, err := base64.URLEncoding.DecodeString(payload)
	if err != nil {
		return nil, err
	}

	var claims map[string]any
	if err := json.Unmarshal(decoded, &claims); err != nil {
		return nil, err
	}
	return claims, nil
}
