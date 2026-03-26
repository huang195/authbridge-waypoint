// token-exchange-service implements Envoy's ext_authz gRPC v3 protocol.
// It uses the token's aud claim to decide: if aud includes the destination
// service name, pass through (already authorized); if not, exchange the token
// for a scoped one via Keycloak RFC 8693. Deployed as a shared service.
package main

import (
	"context"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	core "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	auth "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	envoy_type "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	rpc_status "google.golang.org/genproto/googleapis/rpc/status"
)

// Config holds service configuration, loaded from environment variables.
type Config struct {
	// Keycloak
	KeycloakURL  string // Internal URL for API calls, e.g. http://keycloak-service.keycloak.svc:8080
	IssuerURL    string // External issuer URL in tokens, e.g. http://keycloak.localtest.me:8080 (defaults to KeycloakURL)
	Realm        string // e.g. kagenti
	ClientID     string // token-exchange-service's own client ID
	ClientSecret string // token-exchange-service's own client secret

	// gRPC listen address
	ListenAddr string
}

// tokenCache caches exchanged tokens to avoid hitting Keycloak on every request.
type tokenCache struct {
	mu    sync.RWMutex
	items map[string]cachedToken
}

type cachedToken struct {
	accessToken string
	expiresAt   time.Time
}

// jwksCache caches JWKS keys with background refresh.
type jwksCache struct {
	mu         sync.RWMutex
	keys       map[string]*rsa.PublicKey
	jwksURL    string
	httpClient *http.Client
}

// defaultBypassPaths are paths that skip JWT validation when no Authorization
// header is present. Matches AuthBridge's default bypass list.
// Override via BYPASS_INBOUND_PATHS env var (comma-separated).
var defaultBypassPaths = []string{"/.well-known/*", "/healthz", "/readyz", "/livez"}

var (
	cfg              Config
	cache            *tokenCache
	jwks             *jwksCache
	client           = &http.Client{Timeout: 10 * time.Second}
	bypassPaths      = defaultBypassPaths
)

func main() {
	cfg = loadConfig()

	// Initialize bypass paths (override defaults via env var)
	if envPaths, ok := os.LookupEnv("BYPASS_INBOUND_PATHS"); ok {
		bypassPaths = nil
		for _, p := range strings.Split(envPaths, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				bypassPaths = append(bypassPaths, p)
			}
		}
	}
	log.Printf("bypass paths: %v", bypassPaths)

	cache = &tokenCache{items: make(map[string]cachedToken)}

	// Background cache eviction every 60 seconds
	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			cache.evictExpired()
		}
	}()

	jwksURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/certs", cfg.KeycloakURL, cfg.Realm)
	jwks = &jwksCache{
		keys:       make(map[string]*rsa.PublicKey),
		jwksURL:    jwksURL,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}

	// Initial JWKS fetch
	if err := jwks.refresh(); err != nil {
		log.Printf("WARNING: initial JWKS fetch failed (will retry): %v", err)
	}

	// Background JWKS refresh every 15 minutes
	go func() {
		ticker := time.NewTicker(15 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			if err := jwks.refresh(); err != nil {
				log.Printf("JWKS refresh failed: %v", err)
			}
		}
	}()

	lis, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", cfg.ListenAddr, err)
	}

	srv := grpc.NewServer()
	auth.RegisterAuthorizationServer(srv, &authServer{})

	// Register gRPC health check
	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(srv, healthSrv)
	healthSrv.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)

	log.Printf("token-exchange-service listening on %s", cfg.ListenAddr)
	log.Printf("  keycloak: %s/realms/%s", cfg.KeycloakURL, cfg.Realm)
	log.Printf("  mode: audience-based (aud includes destination → pass, else → exchange)")
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("gRPC serve failed: %v", err)
	}
}

func loadConfig() Config {
	c := Config{
		KeycloakURL:  envOrDefault("KEYCLOAK_URL", "http://keycloak-service.keycloak.svc.cluster.local:8080"),
		IssuerURL:    os.Getenv("ISSUER_URL"), // If empty, derived from KeycloakURL
		Realm:        envOrDefault("REALM", "kagenti"),
		ClientID:     envOrDefault("CLIENT_ID", "token-exchange-service"),
		ClientSecret: os.Getenv("CLIENT_SECRET"),
		ListenAddr:   envOrDefault("LISTEN_ADDR", ":9090"),
	}
	if c.IssuerURL == "" {
		c.IssuerURL = c.KeycloakURL
	}

	if c.ClientSecret == "" {
		log.Fatal("CLIENT_SECRET environment variable is required")
	}

	return c
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// serviceNameFromHost extracts the service name (first segment) from a FQDN.
// e.g. "echo-tool.tool-ns.svc.cluster.local" → "echo-tool"
func serviceNameFromHost(host string) string {
	return strings.SplitN(host, ".", 2)[0]
}

// ---------- Bypass path matching ----------

// matchBypassPath checks if the request path matches any configured bypass pattern.
// Uses Go's path.Match syntax (e.g., "/.well-known/*" matches "/.well-known/agent.json").
func matchBypassPath(requestPath string) bool {
	if idx := strings.IndexByte(requestPath, '?'); idx >= 0 {
		requestPath = requestPath[:idx]
	}
	requestPath = path.Clean(requestPath)
	for _, pattern := range bypassPaths {
		if matched, err := path.Match(pattern, requestPath); err == nil && matched {
			return true
		}
	}
	return false
}

// ---------- ext_authz gRPC implementation ----------

type authServer struct{}

func (s *authServer) Check(ctx context.Context, req *auth.CheckRequest) (*auth.CheckResponse, error) {
	httpReq := req.GetAttributes().GetRequest().GetHttp()
	if httpReq == nil {
		return denied(codes.InvalidArgument, http.StatusBadRequest, "missing HTTP request attributes"), nil
	}

	headers := httpReq.GetHeaders()

	// 1. Extract Authorization header
	authHeader := headers["authorization"]
	if authHeader == "" {
		// Only allow unauthenticated requests to bypass paths (health checks, agent card discovery).
		// All other paths require a Bearer token.
		if matchBypassPath(httpReq.GetPath()) {
			log.Printf("no Authorization header, bypass path (path=%s)", httpReq.GetPath())
			return allowed(), nil
		}
		return denied(codes.Unauthenticated, http.StatusUnauthorized, "missing Authorization header"), nil
	}

	tokenStr := strings.TrimPrefix(authHeader, "Bearer ")
	if tokenStr == authHeader {
		return denied(codes.Unauthenticated, http.StatusUnauthorized, "Authorization header must be Bearer token"), nil
	}

	// 2. Validate the JWT
	claims, err := validateJWT(tokenStr)
	if err != nil {
		log.Printf("JWT validation failed: %v", err)
		return denied(codes.Unauthenticated, http.StatusUnauthorized, fmt.Sprintf("invalid token: %v", err)), nil
	}

	log.Printf("validated JWT for subject=%s, client_id=%s", claims.Subject, claims.ClientID)

	// 3. Extract destination host
	host := headers[":authority"]
	if host == "" {
		host = headers["host"]
	}
	// Strip port if present
	if idx := strings.LastIndex(host, ":"); idx > 0 {
		host = host[:idx]
	}

	// 4. Audience-based routing: does the token already have access to the destination?
	//
	// Derive the destination audience from the hostname (convention: service name = first
	// segment of FQDN, e.g. "echo-tool.tool-ns.svc.cluster.local" → "echo-tool").
	//
	// If the token's aud INCLUDES the destination → pass through (already authorized).
	// If the token's aud DOES NOT include it → exchange for a scoped token via RFC 8693.
	//
	// This naturally handles both inbound and outbound:
	//   Inbound (user→agent): token aud includes "demo-agent" → pass through
	//   Outbound (agent→tool): token aud missing "echo-tool" → exchange
	audience := serviceNameFromHost(host)

	if claims.hasAudience(audience) {
		log.Printf("token already authorized for %s (aud includes it), passing through", audience)
		return allowed(), nil
	}

	log.Printf("token missing audience %s, attempting exchange (token_aud=%v)", audience, claims.Audience)

	// 5. Check cache
	cacheKey := hashCacheKey(tokenStr, audience)
	if cached, ok := cache.get(cacheKey); ok {
		log.Printf("cache hit for audience=%s", audience)
		return allowedWithToken(cached), nil
	}

	// 6. Perform RFC 8693 token exchange
	exchangedToken, expiresIn, err := exchangeToken(ctx, tokenStr, audience)
	if err != nil {
		log.Printf("token exchange failed: %v", err)
		return denied(codes.PermissionDenied, http.StatusForbidden, fmt.Sprintf("token exchange failed: %v", err)), nil
	}

	// 7. Cache the exchanged token
	ttl := time.Duration(expiresIn)*time.Second - 30*time.Second
	if ttl > 0 {
		cache.set(cacheKey, exchangedToken, ttl)
	}

	log.Printf("token exchange succeeded for audience=%s", audience)
	return allowedWithToken(exchangedToken), nil
}

// ---------- JWT validation ----------

type customClaims struct {
	jwt.RegisteredClaims
	ClientID string `json:"azp"`
}

// hasAudience checks if the token's aud claim contains the given audience.
func (c *customClaims) hasAudience(aud string) bool {
	for _, a := range c.Audience {
		if a == aud {
			return true
		}
	}
	return false
}

func validateJWT(tokenStr string) (*customClaims, error) {
	claims := &customClaims{}
	_, err := jwt.ParseWithClaims(tokenStr, claims, func(token *jwt.Token) (any, error) {
		if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		kid, ok := token.Header["kid"].(string)
		if !ok {
			return nil, fmt.Errorf("missing kid in token header")
		}
		key, err := jwks.getKey(kid)
		if err != nil {
			return nil, err
		}
		return key, nil
	},
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
	)
	if err != nil {
		return nil, err
	}

	// Verify issuer matches Keycloak (use IssuerURL which may differ from KeycloakURL)
	expectedIssuer := fmt.Sprintf("%s/realms/%s", cfg.IssuerURL, cfg.Realm)
	if claims.Issuer != expectedIssuer {
		return nil, fmt.Errorf("invalid issuer: got %s, want %s", claims.Issuer, expectedIssuer)
	}

	return claims, nil
}

// ---------- JWKS cache ----------

type jwksResponse struct {
	Keys []jwkKey `json:"keys"`
}

type jwkKey struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func (j *jwksCache) refresh() error {
	resp, err := j.httpClient.Get(j.jwksURL)
	if err != nil {
		return fmt.Errorf("fetching JWKS: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("JWKS endpoint returned %d: %s", resp.StatusCode, string(body))
	}

	var jwksResp jwksResponse
	if err := json.NewDecoder(resp.Body).Decode(&jwksResp); err != nil {
		return fmt.Errorf("decoding JWKS: %w", err)
	}

	newKeys := make(map[string]*rsa.PublicKey)
	for _, k := range jwksResp.Keys {
		if k.Kty != "RSA" || k.Use != "sig" {
			continue
		}
		pubKey, err := parseRSAPublicKey(k.N, k.E)
		if err != nil {
			log.Printf("failed to parse key kid=%s: %v", k.Kid, err)
			continue
		}
		newKeys[k.Kid] = pubKey
	}

	j.mu.Lock()
	j.keys = newKeys
	j.mu.Unlock()

	log.Printf("JWKS refreshed: %d signing keys loaded", len(newKeys))
	return nil
}

func (j *jwksCache) getKey(kid string) (*rsa.PublicKey, error) {
	j.mu.RLock()
	key, ok := j.keys[kid]
	j.mu.RUnlock()
	if ok {
		return key, nil
	}

	// Key not found — try refreshing once
	if err := j.refresh(); err != nil {
		return nil, fmt.Errorf("JWKS refresh failed: %w", err)
	}

	j.mu.RLock()
	defer j.mu.RUnlock()
	key, ok = j.keys[kid]
	if !ok {
		return nil, fmt.Errorf("key kid=%s not found in JWKS", kid)
	}
	return key, nil
}

func parseRSAPublicKey(nStr, eStr string) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(nStr)
	if err != nil {
		return nil, fmt.Errorf("decoding modulus: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(eStr)
	if err != nil {
		return nil, fmt.Errorf("decoding exponent: %w", err)
	}

	n := new(big.Int).SetBytes(nBytes)
	e := new(big.Int).SetBytes(eBytes)

	return &rsa.PublicKey{
		N: n,
		E: int(e.Int64()),
	}, nil
}

// ---------- RFC 8693 token exchange ----------

func exchangeToken(ctx context.Context, subjectToken, audience string) (string, int, error) {
	tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token", cfg.KeycloakURL, cfg.Realm)

	data := url.Values{
		"grant_type":         {"urn:ietf:params:oauth:grant-type:token-exchange"},
		"subject_token":      {subjectToken},
		"subject_token_type": {"urn:ietf:params:oauth:token-type:access_token"},
		"audience":           {audience},
		"client_id":          {cfg.ClientID},
		"client_secret":      {cfg.ClientSecret},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(data.Encode()))
	if err != nil {
		return "", 0, fmt.Errorf("creating exchange request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := client.Do(req)
	if err != nil {
		return "", 0, fmt.Errorf("calling token endpoint: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", 0, fmt.Errorf("reading exchange response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("token exchange returned %d: %s", resp.StatusCode, string(body))
	}

	var tokenResp struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		TokenType   string `json:"token_type"`
	}
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return "", 0, fmt.Errorf("decoding exchange response: %w", err)
	}

	if tokenResp.AccessToken == "" {
		return "", 0, fmt.Errorf("empty access_token in exchange response")
	}

	return tokenResp.AccessToken, tokenResp.ExpiresIn, nil
}

// ---------- Token cache ----------

func (c *tokenCache) get(key string) (string, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	item, ok := c.items[key]
	if !ok || time.Now().After(item.expiresAt) {
		return "", false
	}
	return item.accessToken, true
}

func (c *tokenCache) set(key, token string, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.items[key] = cachedToken{
		accessToken: token,
		expiresAt:   time.Now().Add(ttl),
	}
}

func (c *tokenCache) evictExpired() {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	evicted := 0
	for k, v := range c.items {
		if now.After(v.expiresAt) {
			delete(c.items, k)
			evicted++
		}
	}
	if evicted > 0 {
		log.Printf("cache eviction: removed %d expired entries, %d remaining", evicted, len(c.items))
	}
}

func hashCacheKey(token, audience string) string {
	h := sha256.Sum256([]byte(token + ":" + audience))
	return hex.EncodeToString(h[:])
}

// ---------- ext_authz response helpers ----------

func denied(code codes.Code, httpStatus int, msg string) *auth.CheckResponse {
	body, _ := json.Marshal(map[string]string{"error": msg})
	return &auth.CheckResponse{
		Status: &rpc_status.Status{
			Code:    int32(code),
			Message: msg,
		},
		HttpResponse: &auth.CheckResponse_DeniedResponse{
			DeniedResponse: &auth.DeniedHttpResponse{
				Status: &envoy_type.HttpStatus{
					Code: envoy_type.StatusCode(httpStatus),
				},
				Body: string(body),
				Headers: []*core.HeaderValueOption{
					{
						Header: &core.HeaderValue{
							Key:   "Content-Type",
							Value: "application/json",
						},
					},
				},
			},
		},
	}
}

func allowed() *auth.CheckResponse {
	return &auth.CheckResponse{
		Status: &rpc_status.Status{Code: int32(codes.OK)},
		HttpResponse: &auth.CheckResponse_OkResponse{
			OkResponse: &auth.OkHttpResponse{},
		},
	}
}

func allowedWithToken(token string) *auth.CheckResponse {
	return &auth.CheckResponse{
		Status: &rpc_status.Status{Code: int32(codes.OK)},
		HttpResponse: &auth.CheckResponse_OkResponse{
			OkResponse: &auth.OkHttpResponse{
				Headers: []*core.HeaderValueOption{
					{
						Header: &core.HeaderValue{
							Key:   "authorization",
							Value: "Bearer " + token,
						},
					},
				},
			},
		},
	}
}
