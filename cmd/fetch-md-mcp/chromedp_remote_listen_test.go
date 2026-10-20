package main

import "net"

// netListen listens on every interface, so a browser in a container can reach the test page.
func netListen() (net.Listener, error) { return net.Listen("tcp", "0.0.0.0:0") }
