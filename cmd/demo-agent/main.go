// demo-agent is a minimal HTTP service that acts as the "agent" in the
// user→agent→tool flow. It receives a user token and forwards it to
// downstream tools. The waypoint's ext_authz intercepts each request,
// validates the JWT, and exchanges it for a tool-scoped token before
// the request reaches the tool.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

var (
	toolURL     string
	timeToolURL string
	httpClient  = &http.Client{Timeout: 10 * time.Second}
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	toolURL = os.Getenv("TOOL_URL")
	if toolURL == "" {
		toolURL = "http://echo-tool.tool-ns.svc.cluster.local:8080/echo"
	}

	timeToolURL = os.Getenv("TIME_TOOL_URL")
	if timeToolURL == "" {
		timeToolURL = "http://time-tool.tool-ns.svc.cluster.local:8080/time"
	}

	http.HandleFunc("/call-tool", handleCallTool)
	http.HandleFunc("/call-time", handleCallTime)
	http.HandleFunc("/healthz", handleHealthz)

	log.Printf("demo-agent listening on :%s, tool URL: %s, time-tool URL: %s", port, toolURL, timeToolURL)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// handleCallTool calls the echo-tool service with the user's JWT.
func handleCallTool(w http.ResponseWriter, r *http.Request) {
	callTool(w, r, "echo-tool", toolURL)
}

// handleCallTime calls the time-tool service with the user's JWT.
func handleCallTime(w http.ResponseWriter, r *http.Request) {
	callTool(w, r, "time-tool", timeToolURL)
}

func callTool(w http.ResponseWriter, r *http.Request, name, url string) {
	token := r.Header.Get("Authorization")
	if token == "" {
		http.Error(w, `{"error":"no token provided: set Authorization header"}`, http.StatusBadRequest)
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, url, nil)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"creating request: %v"}`, err), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Authorization", token)

	resp, err := httpClient.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"calling %s: %v"}`, name, err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"reading %s response: %v"}`, name, err), http.StatusInternalServerError)
		return
	}

	result := map[string]any{
		"agent_action":      "called " + name,
		"tool_url":          url,
		"tool_status":       resp.StatusCode,
		"tool_response_raw": json.RawMessage(body),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
