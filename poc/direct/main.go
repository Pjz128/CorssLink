// Direct: simplest possible WebRTC test without signaling.
// Creates two peer connections in the same process and connects them.
package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/pion/webrtc/v4"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Println("=== CrossLink POC: Direct (no signaling) ===")

	// Create offer peer (client)
	offerPC, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
		},
	})
	if err != nil {
		log.Fatal(err)
	}

	// Create answer peer (agent)
	answerPC, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{
			{URLs: []string{"stun:stun.l.google.com:19302"}},
		},
	})
	if err != nil {
		log.Fatal(err)
	}

	// Channel to signal when connected
	connected := make(chan struct{})
	messages := make(chan string, 10)

	// Answer side: handle incoming data channel
	answerPC.OnDataChannel(func(dc *webrtc.DataChannel) {
		log.Printf("[answer] got data channel: %s", dc.Label())
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			s := string(msg.Data)
			log.Printf("[answer] <- data: %s", s)
			messages <- s
		})
		dc.OnOpen(func() {
			log.Printf("[answer] data channel opened")
			connected <- struct{}{}
		})
	})

	// Offer side: create data channel
	dc, err := offerPC.CreateDataChannel("test", nil)
	if err != nil {
		log.Fatal(err)
	}
	dc.OnOpen(func() {
		log.Printf("[offer] data channel opened")
	})
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		s := string(msg.Data)
		log.Printf("[offer] <- data: %s", s)
		messages <- s
	})

	// Exchange ICE candidates between the two PCs
	offerPC.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			log.Printf("[offer] ICE gathering complete")
			return
		}
		log.Printf("[offer] ICE candidate: %s", candidateSummary(c))
		answerPC.AddICECandidate(c.ToJSON())
	})
	answerPC.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			log.Printf("[answer] ICE gathering complete")
			return
		}
		log.Printf("[answer] ICE candidate: %s", candidateSummary(c))
		offerPC.AddICECandidate(c.ToJSON())
	})

	// Track ICE connection state
	offerPC.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("[offer] ICE state: %s", state)
	})
	answerPC.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("[answer] ICE state: %s", state)
		if state == webrtc.ICEConnectionStateConnected {
			select {
			case connected <- struct{}{}:
			default:
			}
		}
	})

	// Create offer
	offer, err := offerPC.CreateOffer(nil)
	if err != nil {
		log.Fatal(err)
	}
	if err := offerPC.SetLocalDescription(offer); err != nil {
		log.Fatal(err)
	}

	log.Printf("[offer] local description set, waiting for ICE gathering...")

	// Wait a bit for ICE gathering to complete
	time.Sleep(2 * time.Second)

	// Now set the offer on the answer side
	if err := answerPC.SetRemoteDescription(offer); err != nil {
		log.Fatal(err)
	}
	log.Printf("[answer] remote description set")

	// Create answer
	answer, err := answerPC.CreateAnswer(nil)
	if err != nil {
		log.Fatal(err)
	}
	if err := answerPC.SetLocalDescription(answer); err != nil {
		log.Fatal(err)
	}

	log.Printf("[answer] local description set")

	// Set answer on offer side
	if err := offerPC.SetRemoteDescription(answer); err != nil {
		log.Fatal(err)
	}
	log.Printf("[offer] remote description set")

	// Wait for connection
	log.Printf("Waiting for ICE connection...")
	select {
	case <-connected:
		log.Printf("=== CONNECTED! ===")
	case <-time.After(15 * time.Second):
		log.Fatal("=== TIMEOUT: ICE connection failed ===")
	}

	// Run ping-pong test
	log.Println("Running ping-pong test...")
	for i := 0; i < 5; i++ {
		msg := fmt.Sprintf("ping %d at %s", i, time.Now().Format(time.RFC3339Nano))
		sent := time.Now()
		dc.SendText(msg)
		log.Printf("[offer] -> data: %s", msg)

		select {
		case reply := <-messages:
			rtt := time.Since(sent)
			log.Printf("  RTT %d: %v (reply: %s)", i, rtt, reply)
		case <-time.After(3 * time.Second):
			log.Printf("  timeout waiting for pong %d", i)
		}
		time.Sleep(200 * time.Millisecond)
	}

	log.Println("=== POC SUCCESS ===")
	log.Println("Press Enter to exit...")
	bufio.NewReader(os.Stdin).ReadString('\n')

	dc.Close()
	offerPC.Close()
	answerPC.Close()
}

func candidateSummary(c *webrtc.ICECandidate) string {
	proto := strings.ToLower(c.Protocol.String())
	typ := strings.ToLower(c.Typ.String())
	return fmt.Sprintf("%s %s:%d (%s)", typ, c.Address, c.Port, proto)
}
