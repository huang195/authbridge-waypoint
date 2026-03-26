FROM ghcr.io/kagenti/agent-examples/weather_service:latest
# Overlay patched files that forward the inbound Authorization header
# to outbound MCP tool calls, enabling waypoint token exchange.
COPY agent.py /app/src/weather_service/agent.py
COPY graph.py /app/src/weather_service/graph.py
