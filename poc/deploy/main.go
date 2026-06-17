package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: deploy upload <local> <remote>")
		fmt.Fprintln(os.Stderr, "       deploy run <command>")
		os.Exit(1)
	}

	host := os.Getenv("CL_HOST")
	user := os.Getenv("CL_USER")
	pass := os.Getenv("CL_PASS")

	if host == "" {
		host = "45.197.144.16:22"
	}
	if user == "" {
		user = "root"
	}
	if pass == "" {
		fmt.Fprintln(os.Stderr, "CL_PASS not set")
		os.Exit(1)
	}

	// Load known_hosts if available, otherwise accept the host key once.
	hostKeyCb, err := knownhosts.New(os.ExpandEnv("$HOME/.ssh/known_hosts"))
	if err != nil {
		// No known_hosts file — trust on first use
		hostKeyCb = func(hostname string, remote net.Addr, key ssh.PublicKey) error {
			fmt.Printf("Trusting new host key for %s (%s)\n", hostname, key.Type())
			return nil
		}
	}

	config := &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{ssh.Password(pass)},
		HostKeyCallback: hostKeyCb,
		Timeout:         10 * time.Second,
	}

	client, err := ssh.Dial("tcp", host, config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "SSH: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	switch os.Args[1] {
	case "upload":
		upload(client, os.Args[2], os.Args[3])
	case "run":
		run(client, os.Args[2])
	}
}

func upload(client *ssh.Client, local, remote string) {
	session, err := client.NewSession()
	if err != nil {
		fmt.Fprintf(os.Stderr, "session: %v\n", err)
		os.Exit(1)
	}
	defer session.Close()

	session.Stdout = os.Stdout
	session.Stderr = os.Stderr

	w, err := session.StdinPipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "stdin pipe: %v\n", err)
		os.Exit(1)
	}

	cmd := fmt.Sprintf("cat > %s && chmod +x %s", remote, remote)
	if err := session.Start(cmd); err != nil {
		fmt.Fprintf(os.Stderr, "start: %v\n", err)
		os.Exit(1)
	}

	f, err := os.Open(local)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open: %v\n", err)
		os.Exit(1)
	}
	io.Copy(w, f)
	f.Close()
	w.Close() // Signal EOF to remote cat

	if err := session.Wait(); err != nil {
		fmt.Fprintf(os.Stderr, "wait: %v\n", err)
		os.Exit(1)
	}

	fi, _ := os.Stat(local)
	fmt.Printf("Uploaded %s (%d bytes) → %s\n", local, fi.Size(), remote)
}

func run(client *ssh.Client, command string) {
	session, err := client.NewSession()
	if err != nil {
		fmt.Fprintf(os.Stderr, "session: %v\n", err)
		os.Exit(1)
	}
	defer session.Close()

	session.Stdout = os.Stdout
	session.Stderr = os.Stderr

	if err := session.Run(command); err != nil {
		fmt.Fprintf(os.Stderr, "run: %v\n", err)
		os.Exit(1)
	}
}
