package core

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

// Optional JVM-forwarded records exercise the exact payload handed to QuickSetup.
// No listener, TUN, network request or service is started by this test.
func TestV093LegacySetupOptions(t *testing.T) {
	previousURL, previousDefault, previousSkip := testURL.Load(), constant.DefaultTestURL, skipCertVerify.Load()
	t.Cleanup(func() {
		testURL.Store(previousURL)
		constant.DefaultTestURL = previousDefault
		skipCertVerify.Store(previousSkip)
	})
	type record struct {
		Name string `json:"name"`
		URL string `json:"url"`
		Skip bool `json:"skip"`
		Forwarded string `json:"forwarded"`
	}
	var records []record
	path := os.Getenv("XB_SHARED_STATE_RECORDS")
	if path == "" { t.Skip("JVM state-machine forwarding records required") }
	data, err := os.ReadFile(path)
	if err != nil { t.Fatal(err) }
	if err := json.Unmarshal(data, &records); err != nil { t.Fatal(err) }
	if len(records) != 4 { t.Fatalf("want four JVM records, got %d", len(records)) }
	for _, item := range records {
		t.Run(item.Name, func(t *testing.T) {
			setTestURL("https://initial.invalid/204")
			skipCertVerify.Store(false)
			var params SetupParams
			if err := json.Unmarshal([]byte(item.Forwarded), &params); err != nil { t.Fatal(err) }
			applyOptions(params.Options)
			t.Logf("forwarded=%s effectiveURL=%s skip=%v", item.Forwarded, currentTestURL(), skipCertVerify.Load())
			if currentTestURL() != item.URL { t.Errorf("test-url lost: got %q want %q", currentTestURL(), item.URL) }
			if skipCertVerify.Load() != item.Skip { t.Errorf("skip-cert-verify lost: got %v want %v", skipCertVerify.Load(), item.Skip) }
		})
	}
}

func TestV093SetupFieldPrecedence(t *testing.T) {
	cases := []struct {
		name string
		payload string
		url string
		skip bool
		wantError bool
	}{
		{"legacy", `{"test-url":"old","skip-cert-verify":true}`, "old", true, false},
		{"modern-false-wins", `{"test-url":"old","skip-cert-verify":true,"options":{"test-url":"new","skip-cert-verify":false}}`, "new", false, false},
		{"partial-options", `{"test-url":"old","skip-cert-verify":true,"options":{"test-url":"new"}}`, "new", true, false},
		{"partial-options-false", `{"test-url":"old","skip-cert-verify":true,"options":{"skip-cert-verify":false}}`, "old", false, false},
		{"empty-explicit-url", `{"test-url":"old","options":{"test-url":""}}`, "", false, false},
		{"empty-options", `{"test-url":"old","skip-cert-verify":true,"options":{}}`, "old", true, false},
		{"null-options", `{"test-url":"old","skip-cert-verify":true,"options":null}`, "old", true, false},
		{"explicit-null-fields", `{"test-url":"old","skip-cert-verify":true,"options":{"test-url":null,"skip-cert-verify":null}}`, "", false, false},
		{"ignore-invalid-shadowed-legacy", `{"test-url":23,"skip-cert-verify":"bad","options":{"test-url":"new","skip-cert-verify":false}}`, "new", false, false},
		{"reject-invalid-legacy", `{"test-url":23}`, "", false, true},
		{"reject-invalid-legacy-bool", `{"skip-cert-verify":"bad"}`, "", false, true},
		{"reject-invalid-modern", `{"test-url":"old","options":{"test-url":23}}`, "", false, true},
		{"reject-invalid-options", `{"options":[]}`, "", false, true},
		{"defaults", `{}`, "", false, false},
		{"case-insensitive-new-presence", `{"test-url":"old","skip-cert-verify":true,"OPTIONS":{"TEST-URL":"new","SKIP-CERT-VERIFY":false}}`, "new", false, false},
		{"duplicate-null-does-not-erase-new-fields", `{"test-url":"old","skip-cert-verify":true,"options":{"test-url":"new","skip-cert-verify":false},"options":null}`, "new", false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var p SetupParams
			err := json.Unmarshal([]byte(tc.payload), &p)
			if tc.wantError {
				if err == nil { t.Fatal("invalid input accepted") }
				return
			}
			if err != nil { t.Fatal(err) }
			if p.Options.TestURL != tc.url || p.Options.SkipCertVerify != tc.skip {
				t.Fatalf("got options %+v want url=%q skip=%v", p.Options, tc.url, tc.skip)
			}
			encoded, err := json.Marshal(p)
			if err != nil { t.Fatal(err) }
			var wire map[string]json.RawMessage
			if err := json.Unmarshal(encoded, &wire); err != nil { t.Fatal(err) }
			if _, exists := wire["skip-cert-verify"]; exists { t.Fatal("wrote old top-level key") }
			if _, exists := wire["options"]; !exists { t.Fatal("missing modern options") }
		})
	}
	t.Run("null-does-not-reset-existing-value", func(t *testing.T) {
		p := SetupParams{Options: CoreOptions{TestURL: "kept", SkipCertVerify: true}}
		if err := json.Unmarshal([]byte(" null "), &p); err != nil { t.Fatal(err) }
		if p.Options.TestURL != "kept" || !p.Options.SkipCertVerify { t.Fatal("null reset object") }
	})
	t.Run("other-setup-and-options-fields-survive", func(t *testing.T) {
		var p SetupParams
		data := []byte(`{"base":{"path":"profile.yaml","overlay":"rules"},"selected-map":{"G":"node"},"test-url":"old","options":{"delay-test-timeout":8123,"mitm-capture":true}}`)
		if err := json.Unmarshal(data, &p); err != nil { t.Fatal(err) }
		if p.Base == nil || p.Base.Path != "profile.yaml" || p.Base.Overlay != "rules" || p.SelectedMap["G"] != "node" {
			t.Fatalf("lost setup fields: %+v", p)
		}
		if p.Options.TestURL != "old" || p.Options.DelayTestTimeout != 8123 || !p.Options.MITMCapture {
			t.Fatalf("lost option fields: %+v", p.Options)
		}
	})
}
