package main

import (
	"strings"
	"testing"
)

func tunDeviceLine(t *testing.T, config string) string {
	t.Helper()
	for _, line := range strings.Split(config, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "dev:") {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "dev:"))
		}
	}
	t.Fatalf("nebula config has no tun dev line:\n%s", config)
	return ""
}

// nebula -test skips tun creation, so only an assertion on the rendered config can
// catch an over-long tun.dev before the kernel refuses it at TUNSETIFF.
func TestRenderedTunDeviceNamesFitKernelLimit(t *testing.T) {
	clientConfig, err := renderClientConfig(ClientState{
		PrivateKeyPath: "host.key", CertificatePath: "host.crt", CACertificatePath: "ca.crt",
		Pairing: &PairResponse{Address: "10.77.0.2/24", LighthouseAddress: "10.77.0.1/24", LighthouseEndpoint: "203.0.113.10:4242", RelayAddress: "10.77.0.1/24"},
	})
	if err != nil {
		t.Fatal(err)
	}
	configs := map[string]string{
		"client":     clientConfig,
		"lighthouse": renderLighthouseConfig("ca.crt", "host.crt", "host.key", 4242, nil),
		"node":       renderNodeLighthouseConfig(MeshNodeAgentState{CACertificatePath: "ca.crt", CertificatePath: "node.crt", PrivateKeyPath: "node.key", NebulaPort: 4242}),
	}
	for role, config := range configs {
		if !strings.Contains(config, "tun:\n  disabled: false") {
			t.Fatalf("%s config is not tun-enabled:\n%s", role, config)
		}
		name := tunDeviceLine(t, config)
		if name == "" || len(name) > maxTunDeviceNameLength {
			t.Fatalf("%s tun dev %q is %d bytes, kernel accepts at most %d:\n%s", role, name, len(name), maxTunDeviceNameLength, config)
		}
	}
}

func TestTunDeviceNameClampsToKernelLimit(t *testing.T) {
	for _, name := range []string{"MeshLAN", "MeshLAN-Node", "MeshLAN-Lighthouse", "MeshLAN-Lighthouse-Extra"} {
		clamped := tunDeviceName(name)
		if len(clamped) > maxTunDeviceNameLength {
			t.Fatalf("tunDeviceName(%q) = %q, %d bytes", name, clamped, len(clamped))
		}
		if len(name) <= maxTunDeviceNameLength && clamped != name {
			t.Fatalf("tunDeviceName rewrote a legal name %q to %q", name, clamped)
		}
		if clamped != name[:min(len(name), maxTunDeviceNameLength)] {
			t.Fatalf("tunDeviceName(%q) = %q, want the leading bytes", name, clamped)
		}
	}
}

// The name that shipped before this fix: 18 bytes, rejected by the kernel at TUNSETIFF.
func TestRenderedLighthouseTunDeviceNameIsShort(t *testing.T) {
	if len(lighthouseTunDeviceName) > maxTunDeviceNameLength {
		t.Fatalf("lighthouseTunDeviceName %q is %d bytes", lighthouseTunDeviceName, len(lighthouseTunDeviceName))
	}
	// Pinning the current value keeps a future edit visible in review.
	if lighthouseTunDeviceName != "meshlan-lh" {
		t.Fatalf("lighthouseTunDeviceName = %q, want meshlan-lh", lighthouseTunDeviceName)
	}
	if name := tunDeviceLine(t, renderLighthouseConfig("ca.crt", "host.crt", "host.key", 4242, nil)); name != lighthouseTunDeviceName {
		t.Fatalf("lighthouse config renders tun dev %q, want %q", name, lighthouseTunDeviceName)
	}
	// The regression this ticket exists for: the old 18-byte name must not survive the clamp.
	if len("MeshLAN-Lighthouse") <= maxTunDeviceNameLength {
		t.Fatalf("the pre-fix name is no longer a regression case")
	}
}
