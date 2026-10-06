module tether

go 1.24.0

toolchain go1.24.7

require (
	github.com/coder/websocket v1.8.15
	github.com/jchv/go-webview2 v0.0.0-20260205173254-56598839c808
	golang.org/x/crypto v0.42.0
	golang.org/x/sys v0.36.0
)

require github.com/jchv/go-winloader v0.0.0-20250406163304-c1995be93bd1 // indirect

replace golang.org/x/sys => github.com/golang/sys v0.36.0

replace golang.org/x/crypto => github.com/golang/crypto v0.42.0
