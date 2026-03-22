// echo-agent is a minimal HTTP service that acts as the "agent" in the
// user→agent→tool flow. A user calls /call-tool with a token (aud=echo-agent).
// The agent forwards the token to echo-tool. The waypoint's ext_authz
// intercepts the request, validates the JWT, and exchanges it for a
// tool-scoped token (aud=echo-tool) before the request reaches echo-tool.
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
func handleCallTool(w http.ResponseWriter, r *http.Request) {
	token := r.Header.Get("Authorization")
	if token == "" {
		http.Error(w, `{"error":"no token provided: set Authorization header"}`, http.StatusBadRequest)
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
