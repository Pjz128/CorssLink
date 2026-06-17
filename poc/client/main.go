// Client: mobile app side of the POC.
// Connects to signaling, sends offer to the agent, and then
// sends ping messages and measures RTT.
package main

import (
	"log"
	"os"
	"os/signal"
	"strings"
	"time"

	"crosslink-poc/peer"
)

const (
	signalAddr = "ws://localhost:18080"
	peerID     = "client-mobile"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== CrossLink POC: Client (Mobile App) ===")

	pongs := make(chan string, 100)

	p, err := peer.New(peer.Config{
		PeerID:     peerID,
		SignalAddr: signalAddr,
		OnMessage: func(msg string) {
			log.Printf("[client] <- agent: %s", msg)
			if strings.HasPrefix(msg, "pong") {
				pongs <- msg
			}
		},
	})
	if err != nil {
		log.Fatalf("failed to create client peer: %v", err)
	}
	defer p.Close()

	// Wait a moment for agent to register, then send offer
	time.Sleep(1 * time.Second)

	log.Printf("[client] sending offer to agent...")
	if err := p.CreateOffer("agent-home-pc"); err != nil {
		log.Fatalf("create offer: %v", err)
	}

	// Wait for DataChannel connection
	connected := make(chan struct{})
	p.SetOnConnect(func() {
		close(connected)
	})

	select {
	case <-connected:
		log.Printf("[client] data channel connected! Starting ping-pong test...")
	case <-time.After(30 * time.Second):
		log.Fatalf("[client] timed out waiting for connection")
	}

	// Run ping-pong tests
	runPingTest(p, pongs)

	// Keep alive
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	<-sig
	log.Printf("[client] shutting down...")
}

func runPingTest(p *peer.Peer, pongs <-chan string) {
	var latencies []time.Duration
	const numPings = 10

	for i := 0; i < numPings; i++ {
		sent := time.Now()
		if err := p.Send("ping"); err != nil {
			log.Printf("[client] ping %d error: %v", i+1, err)
			continue
		}

		select {
		case <-pongs:
			rtt := time.Since(sent)
			latencies = append(latencies, rtt)
			log.Printf("[client] ping %d RTT: %v", i+1, rtt)
		case <-time.After(5 * time.Second):
			log.Printf("[client] ping %d timeout", i+1)
		}
		time.Sleep(500 * time.Millisecond)
	}

	if len(latencies) > 0 {
		var total time.Duration
		for _, l := range latencies {
			total += l
		}
		avg := total / time.Duration(len(latencies))
		log.Printf("=== SUMMARY ===")
		log.Printf("Pings: %d/%d successful", len(latencies), numPings)
		log.Printf("Avg RTT: %v", avg)
		log.Printf("Min RTT: %v", minDur(latencies))
		log.Printf("Max RTT: %v", maxDur(latencies))
	} else {
		log.Printf("=== SUMMARY: No successful pings ===")
	}
}

func minDur(ds []time.Duration) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	m := ds[0]
	for _, d := range ds[1:] {
		if d < m {
			m = d
		}
	}
	return m
}

func maxDur(ds []time.Duration) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	m := ds[0]
	for _, d := range ds[1:] {
		if d > m {
			m = d
		}
	}
	return m
}
