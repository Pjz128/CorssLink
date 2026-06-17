package main

import (
	"encoding/base64"
	"fmt"
	"image/png"
	"os"

	qrcode "github.com/skip2/go-qrcode"
)

func main() {
	uri := "crosslink://pair?%7B%22v%22%3A1%2C%22pk%22%3A%22qC4X7tOkCJ4dM6DYMOQU6EzpYDDaj_yLIrSM3eXbYQY%3D%22%2C%22srv%22%3A%22ws%3A%2F%2F45.197.144.16%3A18080%22%2C%22pid%22%3A%22agent-ollama-pc%22%7D"

	qr, err := qrcode.New(uri, qrcode.Medium)
	if err != nil {
		fmt.Fprintf(os.Stderr, "QR gen error: %v\n", err)
		os.Exit(1)
	}

	f, err := os.Create("pairing-qr.png")
	if err != nil {
		fmt.Fprintf(os.Stderr, "File create error: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	png.Encode(f, qr.Image(256))

	// Print ASCII version to terminal
	art := qr.ToSmallString(false)
	fmt.Println(art)
	fmt.Println("")
	fmt.Println("QR code saved to: pairing-qr.png")
	fmt.Println("Scan with CrossLink App!")

	data, _ := base64.URLEncoding.DecodeString("JEU6kXU_dsz2jlMOPZX1YjfU2LxSTCRMd6MEmJ9-0jA=")
	fmt.Printf("Agent public key: %x\n", data)
}
