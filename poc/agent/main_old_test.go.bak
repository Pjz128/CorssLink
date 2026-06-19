// Agent: home PC side of the POC.
// Starts up, connects to signaling, waits for a client to connect,
// then responds to ping with pong and measures latency.
package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"time"

	"crosslink-poc/peer"
)

const (
	signalAddr = "ws://localhost:18080"
	peerID     = "agent-home-pc"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== CrossLink POC: Agent (Home PC) ===")

	received := make(chan string, 100)

	p, err := peer.New(peer.Config{
		PeerID:     peerID,
		SignalAddr: signalAddr,
		OnMessage: func(msg string) {
			log.Printf("[agent] <- client: %s", msg)
			received <- msg
		},
	})
	if err != nil {
		log.Fatalf("failed to create agent peer: %v", err)
	}
	defer p.Close()

	log.Printf("[agent] waiting for client to connect...")

	// Wait for connection
	p.SetOnConnect(func() {
		log.Printf("[agent] client connected! DataChannel established.")
	})

	// Wait for first message (ping)
	go func() {
		for msg := range received {
			if msg == "ping" {
				// Respond with pong
				now := time.Now().Format(time.RFC3339Nano)
				reply := fmt.Sprintf("pong %s", now)
				if err := p.Send(reply); err != nil {
					log.Printf("[agent] send pong error: %v", err)
				} else {
					log.Printf("[agent] -> client: %s", reply)
				}
			}
		}
	}()

	// Keep running until Ctrl+C
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sig:
			log.Printf("[agent] shutting down...")
			return
		case <-ticker.C:
			if p.IsConnected() {
				log.Printf("[agent] connection alive, waiting for ping...")
			} else {
				log.Printf("[agent] waiting for client connection...")
			}
		}
	}
}
