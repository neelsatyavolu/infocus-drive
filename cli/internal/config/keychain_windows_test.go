//go:build windows

package config

import (
	"errors"
	"testing"
)

func TestCredentialManagerRoundTrip(t *testing.T) {
	const host = "infocus-test.example.com"
	var k Keychain
	k.Delete(host)
	if _, err := k.Get(host); !errors.Is(err, ErrNoToken) {
		t.Fatalf("empty Get: %v", err)
	}
	if err := k.Set(host, "ifd_test_token-1"); err != nil {
		t.Fatal(err)
	}
	if got, err := k.Get(host); err != nil || got != "ifd_test_token-1" {
		t.Fatalf("Get = %q, %v", got, err)
	}
	if err := k.Set(host, "ifd_replaced"); err != nil {
		t.Fatal(err)
	}
	if got, _ := k.Get(host); got != "ifd_replaced" {
		t.Fatalf("after replace Get = %q", got)
	}
	if err := k.Delete(host); err != nil {
		t.Fatal(err)
	}
	if _, err := k.Get(host); !errors.Is(err, ErrNoToken) {
		t.Fatalf("Get after Delete: %v", err)
	}
	if err := k.Delete(host); err != nil {
		t.Fatalf("second Delete: %v", err)
	}
}
