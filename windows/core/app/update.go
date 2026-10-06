package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"tether/core/session"
)

const Repo = "ahmedalbazzaz1987/tether"

type UpdateInfo struct {
	Version  string
	Notes    string
	AssetURL string
	Size     int64
}

func versionParts(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	var out []int
	for _, p := range strings.SplitN(v, ".", 3) {
		n, _ := strconv.Atoi(strings.TrimFunc(p, func(r rune) bool { return r < '0' || r > '9' }))
		out = append(out, n)
	}
	for len(out) < 3 {
		out = append(out, 0)
	}
	return out
}

func Newer(a, b string) bool {
	x, y := versionParts(a), versionParts(b)
	for i := 0; i < 3; i++ {
		if x[i] != y[i] {
			return x[i] > y[i]
		}
	}
	return false
}

func FetchLatest(assetName string) (*UpdateInfo, error) {
	req, _ := http.NewRequest("GET", "https://api.github.com/repos/"+Repo+"/releases/latest", nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "Tether/"+session.AppVersion)
	cl := &http.Client{Timeout: 15 * time.Second}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 404 {
		return nil, errors.New("no releases published yet")
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("GitHub returned %d", resp.StatusCode)
	}
	var r struct {
		Tag    string `json:"tag_name"`
		Body   string `json:"body"`
		Assets []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
			Size int64  `json:"size"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	u := &UpdateInfo{Version: strings.TrimPrefix(r.Tag, "v"), Notes: r.Body}
	for _, a := range r.Assets {
		if strings.EqualFold(a.Name, assetName) {
			u.AssetURL, u.Size = a.URL, a.Size
		}
	}
	return u, nil
}

// Download fetches url into path.
func Download(url, path string) error {
	cl := &http.Client{Timeout: 10 * time.Minute}
	resp, err := cl.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download failed (%d)", resp.StatusCode)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(path)
		return err
	}
	return f.Close()
}

func (a *App) checkUpdate(manual bool) {
	a.mu.Lock()
	a.updMsg = "Checking…"
	a.mu.Unlock()
	a.push()
	u, err := FetchLatest(a.Hooks.UpdateAsset)
	a.mu.Lock()
	switch {
	case err != nil:
		a.updMsg = "Update check failed: " + err.Error()
	case Newer(u.Version, session.AppVersion) && u.AssetURL != "":
		a.update = u
		a.updMsg = "Version " + u.Version + " is available"
	default:
		a.update = nil
		a.updMsg = "Tether is up to date"
	}
	a.mu.Unlock()
	if !manual && err != nil {
		a.mu.Lock()
		a.updMsg = ""
		a.mu.Unlock()
	}
	a.push()
}

func (a *App) applyUpdate() {
	a.mu.Lock()
	u := a.update
	if u == nil || a.updBusy || a.Hooks.ApplyUpdate == nil {
		a.mu.Unlock()
		return
	}
	a.updBusy = true
	a.updMsg = "Downloading " + u.Version + "…"
	a.mu.Unlock()
	a.push()
	err := a.Hooks.ApplyUpdate(u)
	a.mu.Lock()
	a.updBusy = false
	if err != nil {
		a.updMsg = "Update failed: " + err.Error()
	}
	a.mu.Unlock()
	a.push()
}
