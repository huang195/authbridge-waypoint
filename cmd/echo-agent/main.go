// echo-agent is a minimal HTTP service that acts as the "agent" in the
// agent→tool flow. It calls echo-tool with an Authorization header and
// returns the tool's response. The token it sends is the agent's own JWT;
// the waypoint's ext_authz should exchange it before it reaches the tool.
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
	toolURL    string
	httpClient = &http.Client{Timeout: 10 * time.Second}
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

	http.HandleFunc("/call-tool", handleCallTool)
	http.HandleFunc("/healthz", handleHealthz)

	log.Printf("echo-agent listening on :%s, tool URL: %s", port, toolURL)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

// handleCallTool calls the tool service with a JWT and returns the tool's response.
// The JWT can be passed via the Authorization header or the AGENT_TOKEN env var.
func handleCallTool(w http.ResponseWriter, r *http.Request) {
	// Get the agent token: prefer header, fall back to env var
	token := r.Header.Get("Authorization")
	if token == "" {
		envToken := os.Getenv("AGENT_TOKEN")
		if envToken != "" {
			token = "Bearer " + envToken
		}
	}

	if token == "" {
		http.Error(w, `{"error":"no token provided: set Authorization header or AGENT_TOKEN env"}`, http.StatusBadRequest)
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, toolURL, nil)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"creating request: %v"}`, err), http.StatusInternalServerError)
		return
	}
	req.Header.Set("Authorization", token)

	resp, err := httpClient.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"calling tool: %v"}`, err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"reading tool response: %v"}`, err), http.StatusInternalServerError)
		return
	}

	result := map[string]any{
		"agent_action":       "called echo-tool",
		"tool_url":           toolURL,
		"tool_status":        resp.StatusCode,
		"tool_response_raw":  json.RawMessage(body),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
