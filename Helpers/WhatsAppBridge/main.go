// Harnais linked-device service; clients share one session over a user-only Unix socket.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

type object = map[string]any

func main() {
	if len(os.Args) != 3 {
		fail(errors.New("Usage: harnais-whatsapp <status|mcp|logout|stop|daemon> <directory>"))
	}
	mode, directory := os.Args[1], os.Args[2]
	if !filepath.IsAbs(directory) || len(filepath.Join(directory, "bridge.sock")) > 100 {
		fail(errors.New("WhatsApp storage path must be absolute and shorter than 89 characters"))
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		fail(err)
	}
	if info, err := os.Lstat(directory); err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		fail(errors.New("Invalid WhatsApp storage directory"))
	}
	if err := os.Chmod(directory, 0700); err != nil {
		fail(err)
	}
	syscall.Umask(0077)
	var err error
	switch mode {
	case "daemon":
		err = serve(directory)
	case "mcp":
		err = mcp(directory, os.Stdin, os.Stdout)
	case "status", "logout", "stop":
		var result object
		if mode != "stop" {
			err = ensure(directory)
		}
		if err == nil {
			result, err = call(directory, "/"+mode, object{})
		}
		if err == nil && (mode == "stop" || mode == "logout") {
			for i := 0; i < 60; i++ {
				if _, stopped := call(directory, "/status", object{}); stopped != nil {
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
		}
		if err == nil {
			err = json.NewEncoder(os.Stdout).Encode(result)
		}
	default:
		err = errors.New("Unknown WhatsApp command")
	}
	if err != nil {
		fail(err)
	}
}

func fail(err error) { fmt.Fprintln(os.Stderr, err); os.Exit(1) }

func transport(directory string) *http.Client {
	return &http.Client{Timeout: 70 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "unix", filepath.Join(directory, "bridge.sock"))
		}, DisableKeepAlives: true,
	}}
}

func call(directory, path string, input object) (object, error) {
	data, _ := json.Marshal(input)
	resp, err := transport(directory).Post("http://localhost"+path, "application/json", bytes.NewReader(data))
	if err != nil {
		return nil, errors.New("WhatsApp service is not running. Open its connection in Harnais")
	}
	defer resp.Body.Close()
	var result object
	if err = json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&result); err != nil {
		return nil, errors.New("Invalid WhatsApp service response")
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%s", result["error"])
	}
	return result, nil
}

func ensure(directory string) error {
	if _, err := call(directory, "/status", object{}); err == nil {
		return nil
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(executable, "daemon", directory)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	// Never write chat content, QR codes, or session keys to a log.
	if err = cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	for i := 0; i < 60; i++ {
		time.Sleep(100 * time.Millisecond)
		if _, err = call(directory, "/status", object{}); err == nil {
			return nil
		}
	}
	return errors.New("WhatsApp service did not start. Check the Harnais installation")
}
